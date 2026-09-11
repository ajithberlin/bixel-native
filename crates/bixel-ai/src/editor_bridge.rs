//! Synchronous Rust → host (Swift) bridge for live editor commands.
//!
//! Agent tools execute on goose's runtime thread, but the live document lives in
//! Swift (`EditorModel` / `TileMapModel`). Rather than mutate the Rust document
//! handle behind Swift's back — which would desync its layer cache, undo stack
//! and rendering — the agent asks the host to run a command through the same
//! editor methods the UI uses.
//!
//! The host installs one C callback at startup ([`set`]). Each tool call
//! serializes a JSON envelope, hands it to the callback with a caller-owned
//! response buffer, and parses the JSON reply. The callback runs synchronously
//! on the calling thread; the host hops to its main thread internally and
//! returns within a bounded timeout.

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::Mutex;

use serde_json::Value;

use crate::error::AiError;

/// Host callback: write a NUL-terminated JSON response into `response_buf`
/// (capacity `response_cap`) and return `true`, or return `false` on
/// timeout / error / overflow.
pub type EditorBridgeFn =
    extern "C" fn(*const c_char, *mut c_char, usize, *mut c_void) -> bool;

struct Bridge {
    callback: EditorBridgeFn,
    context: *mut c_void,
}

// The callback pointer is only ever invoked synchronously; the host owns the
// context for the process lifetime. Same contract as the FFI chat callback.
unsafe impl Send for Bridge {}
unsafe impl Sync for Bridge {}

static BRIDGE: Mutex<Option<Bridge>> = Mutex::new(None);

/// Upper bound on a single response envelope. State JSON plus a downscaled
/// preview PNG fits comfortably; an oversized reply is rejected as an error.
const RESPONSE_CAP: usize = 16 * 1024 * 1024;

/// Install (or replace) the host editor bridge.
pub fn set(callback: EditorBridgeFn, context: *mut c_void) {
    *BRIDGE.lock().unwrap() = Some(Bridge { callback, context });
}

/// Remove the host editor bridge (e.g. when the project closes).
pub fn clear() {
    *BRIDGE.lock().unwrap() = None;
}

/// True when a host has installed the bridge.
pub fn is_installed() -> bool {
    BRIDGE.lock().unwrap().is_some()
}

/// Send one command envelope to the host and return its JSON response.
///
/// The envelope is `{ "command": "read" | "apply", ... }`; the response is
/// `{ "ok": true, "data": ... }` or `{ "ok": false, "error": ..., "code": ... }`.
pub fn request(command: &Value) -> Result<Value, AiError> {
    let (callback, context) = {
        let guard = BRIDGE.lock().unwrap();
        let bridge = guard.as_ref().ok_or_else(|| {
            AiError::Config(
                "The editor bridge is unavailable. Open a project and the AI panel first."
                    .into(),
            )
        })?;
        (bridge.callback, bridge.context)
    };

    let json = serde_json::to_string(command).map_err(|e| AiError::Config(e.to_string()))?;
    let request = CString::new(json).map_err(|e| AiError::Config(e.to_string()))?;
    let mut buffer = vec![0u8; RESPONSE_CAP];
    let ok = callback(
        request.as_ptr(),
        buffer.as_mut_ptr() as *mut c_char,
        buffer.len(),
        context,
    );
    if !ok {
        return Err(AiError::Config(
            "The editor did not respond (command timed out or the response was too large).".into(),
        ));
    }

    let response = unsafe { CStr::from_ptr(buffer.as_ptr() as *const c_char) }
        .to_string_lossy()
        .into_owned();
    serde_json::from_str(&response)
        .map_err(|e| AiError::Config(format!("Invalid editor response: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static CALLS: AtomicUsize = AtomicUsize::new(0);

    extern "C" fn echo(
        request: *const c_char,
        response: *mut c_char,
        capacity: usize,
        _context: *mut c_void,
    ) -> bool {
        CALLS.fetch_add(1, Ordering::SeqCst);
        let request = unsafe { CStr::from_ptr(request) }.to_string_lossy().into_owned();
        let reply = format!(r#"{{"ok":true,"data":{{"echo":{request}}}}}"#);
        let reply = reply.as_bytes();
        if reply.len() + 1 > capacity {
            return false;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(reply.as_ptr(), response as *mut u8, reply.len());
            *response.add(reply.len()) = 0;
        }
        true
    }

    #[test]
    fn request_round_trips_through_the_bridge() {
        set(echo, std::ptr::null_mut());
        assert!(is_installed());
        let response = request(&serde_json::json!({"command": "read"})).unwrap();
        assert_eq!(response["ok"], serde_json::json!(true));
        assert_eq!(response["data"]["echo"]["command"], serde_json::json!("read"));
        assert_eq!(CALLS.load(Ordering::SeqCst), 1);
        clear();
        assert!(!is_installed());
        assert!(request(&serde_json::json!({"command": "read"})).is_err());
    }
}
