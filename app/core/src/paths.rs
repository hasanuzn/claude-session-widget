//! Where the data lives. Passed in explicitly so tests can point at a sandbox.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Paths {
    /// Claude Code config dir: `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
    pub claude_dir: PathBuf,
    /// Folders that hold the desktop app's `claude-code-sessions` trees.
    pub desktop_roots: Vec<PathBuf>,
}

impl Paths {
    /// The locations on this machine.
    pub fn detect() -> Self {
        let home = home_dir();
        let claude_dir = std::env::var_os("CLAUDE_CONFIG_DIR")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".claude"));
        Self {
            claude_dir,
            desktop_roots: desktop_roots(&home),
        }
    }

    pub fn sessions_dir(&self) -> PathBuf {
        self.claude_dir.join("sessions")
    }

    pub fn projects_dir(&self) -> PathBuf {
        self.claude_dir.join("projects")
    }

    /// `<projects>/<cwd slug>/<id>.jsonl`, else any `<projects>/*/<id>.jsonl`.
    pub fn find_transcript(&self, session_id: &str, cwd: &str) -> Option<PathBuf> {
        let file = format!("{session_id}.jsonl");
        let direct = self.projects_dir().join(cwd_slug(cwd)).join(&file);
        if direct.is_file() {
            return Some(direct);
        }
        std::fs::read_dir(self.projects_dir())
            .ok()?
            .flatten()
            .map(|e| e.path().join(&file))
            .find(|p| p.is_file())
    }
}

/// Folder name Claude Code uses for a working directory: every character that is
/// not an ASCII letter or digit becomes `-`.
pub fn cwd_slug(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

fn home_dir() -> PathBuf {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// `<root>/<account>/claude-code-sessions` for every account folder.
fn desktop_roots(home: &Path) -> Vec<PathBuf> {
    let mut bases = Vec::new();
    if cfg!(windows) {
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            bases.push(PathBuf::from(local).join("Claude-Data"));
        }
    } else if cfg!(target_os = "macos") {
        // TODO(phase 4): verify on a Mac where the desktop app keeps its session records.
        bases.push(home.join("Library/Application Support/Claude-Data"));
    }
    let mut roots = Vec::new();
    for base in bases {
        let Ok(entries) = std::fs::read_dir(&base) else {
            continue;
        };
        for e in entries.flatten() {
            let p = e.path().join("claude-code-sessions");
            if p.is_dir() {
                roots.push(p);
            }
        }
    }
    roots
}

#[cfg(test)]
mod tests {
    #[test]
    fn slug_matches_claude_code() {
        assert_eq!(super::cwd_slug(r"C:\Users\me\repo"), "C--Users-me-repo");
        assert_eq!(
            super::cwd_slug("/home/me/projects/app"),
            "-home-me-projects-app"
        );
    }
}
