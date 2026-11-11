//! Status records written by every running `claude` process:
//! `<claude dir>/sessions/<pid>.json` with `status: "busy" | "idle" | "waiting"`; a waiting
//! record also says why in `waitingFor` (e.g. "permission prompt", "input needed").
//! A record counts only while its process is alive (a crash can leave `busy` behind).

use crate::process::is_alive;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct RawRecord {
    pid: Option<serde_json::Value>,
    session_id: Option<String>,
    status: Option<String>,
    waiting_for: Option<String>,
    status_updated_at: Option<f64>,
    started_at: Option<f64>,
    entrypoint: Option<String>,
    name: Option<String>,
    cwd: Option<String>,
}

/// One live `claude` process.
#[derive(Debug, Clone, PartialEq)]
pub struct StatusRecord {
    pub pid: u32,
    pub session_id: String,
    pub busy: bool,
    /// `Some(reason)` while the session waits for the person (a prompt is open).
    pub waiting_for: Option<String>,
    /// When the status last changed (falls back to the start time), ms since the epoch.
    pub since_ms: f64,
    /// e.g. "cli", "claude-desktop".
    pub entrypoint: String,
    pub name: String,
    pub cwd: String,
}

impl StatusRecord {
    /// Busy, or waiting for the person.
    pub fn active(&self) -> bool {
        self.busy || self.waiting_for.is_some()
    }

    /// Parses one record; `None` if it has no session id or pid.
    pub fn parse(json: &str) -> Option<Self> {
        let r: RawRecord = serde_json::from_str(json).ok()?;
        let pid = match r.pid? {
            serde_json::Value::Number(n) => n.as_u64()? as u32,
            serde_json::Value::String(s) => s.trim().parse().ok()?,
            _ => return None,
        };
        let session_id = r.session_id.filter(|s| !s.is_empty())?;
        Some(Self {
            pid,
            session_id,
            busy: r.status.as_deref() == Some("busy"),
            waiting_for: (r.status.as_deref() == Some("waiting"))
                .then(|| r.waiting_for.unwrap_or_default()),
            since_ms: r
                .status_updated_at
                .filter(|v| *v > 0.0)
                .or(r.started_at)
                .unwrap_or(0.0),
            entrypoint: r.entrypoint.unwrap_or_default(),
            name: r.name.unwrap_or_default(),
            cwd: r.cwd.unwrap_or_default(),
        })
    }
}

/// Reads `<dir>/*.json` and keeps the records whose process is alive, keyed by session id.
pub fn read_live_records(dir: &Path) -> HashMap<String, StatusRecord> {
    let mut out = HashMap::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        if let Some(rec) = StatusRecord::parse(text.trim_start_matches('\u{feff}'))
            && is_alive(rec.pid)
        {
            out.insert(rec.session_id.clone(), rec);
        }
    }
    out
}

/// Builds the table from already-read record texts (used for WSL, where the
/// alive check happens inside the distro).
pub fn records_from_texts<'a>(
    texts: impl IntoIterator<Item = &'a str>,
) -> HashMap<String, StatusRecord> {
    texts
        .into_iter()
        .filter_map(|t| StatusRecord::parse(t.trim()))
        .map(|r| (r.session_id.clone(), r))
        .collect()
}
