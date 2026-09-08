//! Audits: persisted, dated validation reports for project assets (port of
//! `core/audits.py`). A report run on demand captures the same validator rules
//! the live editors use, plus a pass/warn/fail verdict, into `.studio/audits/`.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::map_validate;
use crate::paths::{safe_resolve, to_rel};
use crate::project::{self, Project};
use crate::sources;

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn audits_dir(project: &Project) -> PathBuf {
    let _ = project::ensure_local_state(project);
    let folder = project.path().join(".studio").join("audits");
    let _ = std::fs::create_dir_all(&folder);
    folder
}

fn normalize_findings(findings: &[map_validate::Finding]) -> Vec<Value> {
    findings
        .iter()
        .map(|f| {
            json!({
                "level": f.level,
                "code": f.code,
                "message": f.message,
                "layer": f.layer,
                "object": f.object,
            })
        })
        .collect()
}

fn verdict(findings: &[Value]) -> &'static str {
    for level in ["error", "warn"] {
        if findings.iter().any(|f| f.get("level").and_then(|v| v.as_str()) == Some(level)) {
            return if level == "error" { "fail" } else { "warn" };
        }
    }
    "ok"
}

fn read_json(path: &Path) -> Result<Value, String> {
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| format!("not readable JSON: {e}"))
}

/// Run every auditor that understands `rel` and return a report.
pub fn audit_path(project: &Project, rel: &str, persist: bool) -> Result<Value, String> {
    let source = sources::active(project);
    let root = sources::workspace_root_for(source.as_ref(), project);
    let path = safe_resolve(rel, &root).map_err(|e| e.to_string())?;
    if !path.is_file() {
        return Err(rel.to_string());
    }
    let suffix = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    let mut findings: Vec<Value> = Vec::new();
    let mut summary = json!({});
    let mut auditor = "none";

    if suffix == "json" || suffix == "tmj" {
        let data = match read_json(&path) {
            Ok(d) => d,
            Err(e) => return Err(e),
        };
        if data.get("layers").is_some() {
            auditor = "map";
            let rel_path = to_rel(&path, &root).unwrap_or_else(|_| rel.to_string());
            let raw = map_validate::validate(&data, &rel_path, &root);
            findings = normalize_findings(&raw);
            summary = map_validate::summarize(&data);
        } else if data.get("actions").is_some() {
            auditor = "atlas";
            let image = data.get("image").and_then(|v| v.as_str()).unwrap_or("");
            let image_size = if !image.is_empty() {
                let image_path = path.parent().map(|p| p.join(image)).unwrap_or_else(|| path.clone());
                crate::atlas::png_dimensions(&image_path).ok()
            } else {
                None
            };
            match crate::atlas::validate(&data, image_size) {
                Ok(()) => findings.push(json!({
                    "level": "info", "code": "atlas_ok",
                    "message": "atlas geometry validates against its image"
                })),
                Err(e) => findings.push(json!({
                    "level": "error", "code": "atlas_invalid",
                    "message": e.to_string()
                })),
            }
        }
    } else if matches!(suffix.as_str(), "png" | "jpg" | "jpeg" | "webp" | "gif" | "bmp") {
        auditor = "image";
        if suffix == "png" {
            match crate::atlas::png_dimensions(&path) {
                Ok((w, h)) => findings.push(json!({
                    "level": "info", "code": "image_readable",
                    "message": format!("{w}×{h} image decodes cleanly")
                })),
                Err(_) => findings.push(json!({
                    "level": "error", "code": "image_unreadable",
                    "message": "image does not decode"
                })),
            }
        } else {
            findings.push(json!({
                "level": "info", "code": "image_ok",
                "message": "image present"
            }));
        }
    } else {
        findings.push(json!({
            "level": "info", "code": "no_auditor",
            "message": "no auditor covers this file type"
        }));
    }

    let mut report = json!({
        "id": "",
        "path": to_rel(&path, &root).unwrap_or_else(|_| rel.to_string()),
        "auditor": auditor,
        "run_at": now(),
        "status": verdict(&findings),
        "findings": findings,
        "summary": summary,
    });
    if persist {
        let id = persist_report(project, &report);
        report["id"] = json!(id);
    }
    Ok(report)
}

fn persist_report(project: &Project, report: &Value) -> String {
    let stamp = time_stamp();
    let folder = audits_dir(project);
    let count = std::fs::read_dir(&folder)
        .map(|d| d.filter(|e| e.as_ref().map(|e| e.path().extension().map(|x| x == "json").unwrap_or(false)).unwrap_or(false)).count())
        .unwrap_or(0);
    let report_id = format!("{stamp}-{}", count + 1);
    let path = folder.join(format!("audit-{report_id}.json"));
    let mut text = serde_json::to_string_pretty(report).unwrap_or_else(|_| "{}".into());
    text.push('\n');
    let _ = std::fs::write(path, text);
    report_id
}

fn time_stamp() -> String {
    use std::time::SystemTime;
    // Format as YYYYMMDD-HHMMSS without pulling in a chrono dependency.
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86400;
    let (year, month, day) = civil_from_days(days as i64);
    let rem = secs % 86400;
    let hh = rem / 3600;
    let mm = (rem % 3600) / 60;
    let ss = rem % 60;
    format!("{year:04}{month:02}{day:02}-{hh:02}{mm:02}{ss:02}")
}

/// Convert days-since-epoch to (year, month, day). Howard Hinnant's algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub fn list_audits(project: &Project, limit: usize) -> Vec<Value> {
    let folder = audits_dir(project);
    let mut reports: Vec<Value> = Vec::new();
    let Ok(entries) = std::fs::read_dir(&folder) else {
        return reports;
    };
    let mut paths: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    paths.sort_by(|a, b| b.cmp(a));
    for path in paths {
        if path.extension().map(|e| e != "json").unwrap_or(true) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(data) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        let mut entry = json!({
            "id": data.get("id"),
            "path": data.get("path"),
            "auditor": data.get("auditor"),
            "run_at": data.get("run_at"),
            "status": data.get("status"),
            "summary": data.get("summary"),
        });
        // Normalize nulls to empty for the frontend.
        for k in ["id", "path", "auditor", "run_at", "status", "summary"] {
            if entry.get(k) == Some(&Value::Null) {
                entry[k] = json!("");
            }
        }
        reports.push(entry);
        if reports.len() >= limit {
            break;
        }
    }
    reports
}

pub fn get_audit(project: &Project, report_id: &str) -> Result<Value, String> {
    if report_id.is_empty() || !report_id.chars().all(|c| c.is_ascii_digit() || c == '-') {
        return Err("invalid audit id".into());
    }
    let folder = audits_dir(project);
    let Ok(entries) = std::fs::read_dir(&folder) else {
        return Err(report_id.to_string());
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        if stem == format!("audit-{report_id}") || stem.ends_with(report_id) {
            let text = std::fs::read_to_string(&path).map_err(|_| report_id.to_string())?;
            return serde_json::from_str(&text).map_err(|_| report_id.to_string());
        }
    }
    Err(report_id.to_string())
}

pub fn delete_audit(project: &Project, report_id: &str) -> Result<bool, String> {
    get_audit(project, report_id)?;
    let folder = audits_dir(project);
    let Ok(entries) = std::fs::read_dir(&folder) else {
        return Ok(false);
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        if stem == format!("audit-{report_id}") || stem.ends_with(report_id) {
            let _ = std::fs::remove_file(path);
            return Ok(true);
        }
    }
    Ok(false)
}
