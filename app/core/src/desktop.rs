//! Session records of the Claude desktop app (Code tab): one `local_*.json` per
//! session, with its title, working directory, WSL distro / remote transcript path,
//! and turn timestamps.

use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct DesktopRecord {
    pub session_id: Option<String>,
    pub cli_session_id: Option<String>,
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub is_archived: Option<bool>,
    pub last_turn_edge_at: Option<f64>,
    pub latest_user_frame_at: Option<f64>,
    pub last_activity_at: Option<f64>,
    pub wsl_config: Option<WslConfig>,
    pub ssh_remote_transcript_path: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct WslConfig {
    pub distro: Option<String>,
}

impl DesktopRecord {
    pub fn parse(json: &str) -> Option<Self> {
        serde_json::from_str(json.trim_start_matches('\u{feff}')).ok()
    }

    pub fn wsl_distro(&self) -> Option<&str> {
        self.wsl_config
            .as_ref()?
            .distro
            .as_deref()
            .filter(|d| !d.is_empty())
    }

    pub fn remote_transcript(&self) -> Option<&str> {
        self.ssh_remote_transcript_path
            .as_deref()
            .filter(|p| !p.is_empty())
    }

    /// Fallback "running" signal when no live process record exists: the latest user
    /// message came after the last turn boundary, and there was activity recently.
    pub fn looks_running(&self, now_ms: f64, stale_ms: f64) -> bool {
        let user = self.latest_user_frame_at.unwrap_or(0.0);
        let edge = self.last_turn_edge_at.unwrap_or(0.0);
        if user <= 0.0 || user < edge {
            return false;
        }
        let activity = self.last_activity_at.filter(|v| *v > 0.0).unwrap_or(user);
        now_ms - activity <= stale_ms
    }
}

/// All `local_*.json` files under each root, two folder levels down
/// (`<root>/<a>/<b>/local_*.json`), with their modification time.
pub fn find_record_files(roots: &[PathBuf]) -> Vec<(PathBuf, std::time::SystemTime)> {
    let mut out = Vec::new();
    for root in roots {
        for a in subdirs(root) {
            for b in subdirs(&a) {
                let Ok(entries) = std::fs::read_dir(&b) else {
                    continue;
                };
                for e in entries.flatten() {
                    let name = e.file_name();
                    let name = name.to_string_lossy();
                    if name.starts_with("local_")
                        && name.ends_with(".json")
                        && let Ok(meta) = e.metadata()
                    {
                        out.push((e.path(), meta.modified().unwrap_or(std::time::UNIX_EPOCH)));
                    }
                }
            }
        }
    }
    out
}

fn subdirs(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|it| {
            it.flatten()
                .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                .map(|e| e.path())
                .collect()
        })
        .unwrap_or_default()
}
