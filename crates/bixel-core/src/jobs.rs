//! Job queue: every slow thing in the studio is a Job (port of `core/jobs.py`).
//!
//! Running a skill script — and later generating an image — share one lifecycle
//! (`queued -> running -> ok | failed | cancelled`), one log format and one
//! history. Jobs are project-local: each runs with the owning project as its
//! working directory and keeps its log under `.studio/jobs/<id>/`.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub const TERMINAL: [&str; 3] = ["ok", "failed", "cancelled"];

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// ------------------------------------------------------------------ specs

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArgType {
    Path,
    Text,
    Int,
    Bool,
}

#[derive(Debug, Clone)]
pub struct SpecArg {
    pub name: String,
    pub arg_type: ArgType,
    pub required: bool,
    /// Optional `--flag` rendered before the value.
    pub flag: Option<String>,
}

#[derive(Debug, Clone)]
pub struct JobSpec {
    pub id: String,
    pub title: String,
    pub script: String,
    pub args: Vec<SpecArg>,
}

/// Render the command-line arguments from `values`. Raises on missing required
/// args. `--flag value` is emitted when a flag is present, otherwise just the
/// value.
pub fn build_argv(spec: &JobSpec, values: &HashMap<String, String>) -> Result<Vec<String>, String> {
    let mut argv = Vec::new();
    for arg in &spec.args {
        let value = values.get(&arg.name).map(|s| s.clone());
        match value {
            Some(v) if !v.is_empty() => {
                if let Some(flag) = &arg.flag {
                    argv.push(flag.clone());
                }
                if arg.arg_type != ArgType::Bool {
                    argv.push(v);
                }
            }
            _ => {
                if arg.required {
                    return Err(format!("missing required argument: {}", arg.name));
                }
            }
        }
    }
    Ok(argv)
}

// ------------------------------------------------------------------- job

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    pub id: String,
    pub spec_id: String,
    pub title: String,
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub values: HashMap<String, String>,
    pub project_dir: String,
    pub script: String,
    pub cwd: String,
    pub app_home: String,
    #[serde(default = "default_status")]
    pub status: String,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub error: String,
    #[serde(default)]
    pub created: f64,
    #[serde(default)]
    pub started: Option<f64>,
    #[serde(default)]
    pub ended: Option<f64>,
    #[serde(default)]
    pub outputs: Vec<String>,
}

fn default_status() -> String {
    "queued".into()
}

pub fn job_dir(job: &Job) -> PathBuf {
    Path::new(&job.project_dir).join(".studio").join("jobs").join(&job.id)
}

pub fn project_jobs_dir(project_root: &Path) -> PathBuf {
    project_root.join(".studio").join("jobs")
}

#[derive(Default)]
struct Shared {
    jobs: HashMap<String, Job>,
    /// PIDs of running subprocesses, keyed by job id (for cancellation).
    pids: HashMap<String, i32>,
}

/// A small fixed worker pool running scripts as subprocesses.
pub struct JobManager {
    tx: Sender<String>,
    shared: Arc<Mutex<Shared>>,
}

impl JobManager {
    pub fn new(workers: usize) -> Self {
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        let shared = Arc::new(Mutex::new(Shared::default()));
        let rx = Arc::new(Mutex::new(rx));
        for _ in 0..workers.max(1) {
            let shared = Arc::clone(&shared);
            let rx = Arc::clone(&rx);
            std::thread::spawn(move || worker_loop(shared, rx));
        }
        JobManager { tx, shared }
    }

    pub fn submit(
        &self,
        project_root: &Path,
        app_home: &Path,
        spec: &JobSpec,
        values: HashMap<String, String>,
    ) -> Result<Job, String> {
        let argv = build_argv(spec, &values)?;
        let project_dir = project_root.to_string_lossy().into_owned();
        let id = uuid_hex();
        let job = Job {
            id: id.clone(),
            spec_id: spec.id.clone(),
            title: spec.title.clone(),
            argv: argv.clone(),
            values,
            project_dir: project_dir.clone(),
            script: spec.script.clone(),
            cwd: project_dir,
            app_home: app_home.to_string_lossy().into_owned(),
            status: "queued".into(),
            exit_code: None,
            error: String::new(),
            created: now(),
            started: None,
            ended: None,
            outputs: Vec::new(),
        };

        let dir = job_dir(&job);
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let _ = std::fs::write(dir.join("command.json"), json_command(&job));
        let _ = std::fs::write(dir.join("log.txt"), b"");

        {
            let mut s = self.shared.lock().unwrap();
            s.jobs.insert(id.clone(), job.clone());
        }
        persist(&job);
        self.tx.send(id).map_err(|e| e.to_string())?;
        Ok(job)
    }

    pub fn get(&self, job_id: &str) -> Option<Job> {
        self.shared.lock().unwrap().jobs.get(job_id).cloned()
    }

    pub fn list(&self, limit: usize) -> Vec<Job> {
        let s = self.shared.lock().unwrap();
        let mut jobs: Vec<Job> = s.jobs.values().cloned().collect();
        jobs.sort_by(|a, b| {
            b.created
                .partial_cmp(&a.created)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        jobs.truncate(limit);
        jobs
    }

    pub fn cancel(&self, job_id: &str) -> bool {
        let (mut job, pid) = {
            let mut s = self.shared.lock().unwrap();
            let Some(j) = s.jobs.get(job_id) else {
                return false;
            };
            if TERMINAL.contains(&j.status.as_str()) {
                return false;
            }
            (j.clone(), s.pids.remove(job_id))
        };
        if let Some(pid) = pid {
            #[cfg(unix)]
            unsafe {
                // Negative pid == kill the whole process group (setpgid(0,0) at
                // spawn made the child its own group leader).
                libc::kill(-pid, libc::SIGTERM);
            }
            return true;
        }
        // Still queued: mark cancelled so the worker skips it.
        job.status = "cancelled".into();
        job.ended = Some(now());
        persist(&job);
        if let Some(j) = self.shared.lock().unwrap().jobs.get_mut(job_id) {
            j.status = "cancelled".into();
            j.ended = job.ended;
        }
        true
    }

    pub fn read_log(&self, job_id: &str, offset: u64, limit: u64) -> (u64, String, bool) {
        let path = match self.get(job_id) {
            Some(job) => job_dir(&job).join("log.txt"),
            None => PathBuf::from(job_id),
        };
        let Ok(meta) = std::fs::metadata(&path) else {
            return (0, String::new(), true);
        };
        let size = meta.len();
        let offset = if offset > size { 0 } else { offset };
        let mut buf = vec![0u8; (limit as usize).min((size - offset) as usize)];
        let read = std::fs::File::open(&path)
            .and_then(|mut f| {
                use std::io::{Read, Seek, SeekFrom};
                f.seek(SeekFrom::Start(offset))?;
                f.read(&mut buf)
            })
            .unwrap_or(0);
        buf.truncate(read);
        let text = String::from_utf8_lossy(&buf).into_owned();
        let eof = self
            .get(job_id)
            .map(|j| TERMINAL.contains(&j.status.as_str()))
            .unwrap_or(true);
        (offset + read as u64, text, eof)
    }
}

fn worker_loop(shared: Arc<Mutex<Shared>>, rx: Arc<Mutex<Receiver<String>>>) {
    loop {
        let job_id = {
            let rx = rx.lock().unwrap();
            match rx.recv() {
                Ok(id) => id,
                Err(_) => break,
            }
        };
        run_job(&shared, &job_id);
    }
}

fn run_job(shared: &Arc<Mutex<Shared>>, job_id: &str) {
    let job = {
        let s = shared.lock().unwrap();
        match s.jobs.get(job_id) {
            Some(j) => j.clone(),
            None => return,
        }
    };
    if job.status == "cancelled" {
        return;
    }

    let dir = job_dir(&job);
    let log_path = dir.join("log.txt");
    let mut command = Command::new(&job.script);
    command.args(&job.argv).current_dir(&job.cwd);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }

    let mut cmdline = format!("$ {}", job.script);
    for a in &job.argv {
        cmdline.push(' ');
        cmdline.push_str(a);
    }

    {
        let mut s = shared.lock().unwrap();
        if let Some(j) = s.jobs.get_mut(job_id) {
            j.status = "running".into();
            j.started = Some(now());
        }
    }
    persist_shared(shared, job_id);

    let mut log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .unwrap();
    let _ = writeln!(log, "{cmdline}\n");

    match command.spawn() {
        Ok(child) => {
            {
                let mut s = shared.lock().unwrap();
                s.pids.insert(job_id.to_string(), child.id() as i32);
            }
            let output = child.wait_with_output();
            {
                let mut s = shared.lock().unwrap();
                s.pids.remove(job_id);
            }
            if let Ok(out) = &output {
                let _ = log.write_all(&out.stdout);
            }
            let exit_code = output.as_ref().map(|o| o.status.code()).unwrap_or(None);
            let _ = writeln!(log, "\n[studio] exited with code {exit_code:?}");
            finish(shared, job_id, exit_code);
        }
        Err(e) => {
            let _ = writeln!(log, "\n[studio] failed to start: {e}");
            let mut s = shared.lock().unwrap();
            if let Some(j) = s.jobs.get_mut(job_id) {
                j.status = "failed".into();
                j.error = e.to_string();
                j.ended = Some(now());
            }
            persist_shared(shared, job_id);
        }
    }
}

fn finish(shared: &Arc<Mutex<Shared>>, job_id: &str, exit_code: Option<i32>) {
    let mut s = shared.lock().unwrap();
    let Some(job) = s.jobs.get_mut(job_id) else {
        return;
    };
    job.exit_code = exit_code;
    job.ended = Some(now());
    job.status = if job.status == "cancelled" {
        "cancelled".into()
    } else if exit_code == Some(0) {
        "ok".into()
    } else {
        "failed".into()
    };
    persist(job);
}

fn persist_shared(shared: &Arc<Mutex<Shared>>, job_id: &str) {
    let s = shared.lock().unwrap();
    if let Some(job) = s.jobs.get(job_id) {
        persist(job);
    }
}

fn persist(job: &Job) {
    let path = job_dir(job).join("job.json");
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let mut text = serde_json::to_string_pretty(job).unwrap_or_else(|_| "{}".into());
    text.push('\n');
    let _ = std::fs::write(path, text);
}

fn json_command(job: &Job) -> String {
    let mut command = vec![job.script.clone()];
    command.extend(job.argv.iter().cloned());
    serde_json::to_string_pretty(&serde_json::json!({
        "spec": job.spec_id,
        "cwd": job.cwd,
        "command": command,
        "env": { "BIXEL_STATE_DIR": job.app_home },
    }))
    .unwrap_or_else(|_| "{}".into())
}

fn uuid_hex() -> String {
    // 12 hex chars, like the Python `uuid.uuid4().hex[:12]`. Uses the OS
    // randomness source via `getrandom`-free LCG seeded by time + pid (a UUID
    // crate can replace this for production).
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut v = nanos ^ (std::process::id() as u128);
    let mut out = String::with_capacity(12);
    for _ in 0..12 {
        out.push(char::from_digit((v % 16) as u32, 16).unwrap());
        v = v.wrapping_mul(6364136223846793005).wrapping_add(1);
    }
    out
}
