//! Puts the sources together: which sessions are working now, and their progress.

use crate::desktop::{DesktopRecord, find_record_files};
use crate::model::{Location, Progress, Session};
use crate::now_ms;
use crate::paths::Paths;
use crate::status::{StatusRecord, read_live_records};
use crate::text::leaf_name;
use crate::transcript::TranscriptReader;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Sessions with no activity for this long are not "running" (fallback signal only).
pub const STALE_MS: f64 = 2.0 * 60.0 * 60.0 * 1000.0;

/// Keeps caches between scans: parsed desktop records (by file mtime) and one
/// incremental reader per local transcript.
#[derive(Debug)]
pub struct Scanner {
    paths: Paths,
    records: HashMap<PathBuf, (SystemTime, DesktopRecord)>,
    readers: HashMap<PathBuf, TranscriptReader>,
    /// WSL progress by (record file, last activity), so it is re-read only after a change.
    remote_progress: HashMap<PathBuf, (u64, Progress)>,
}

impl Scanner {
    pub fn new(paths: Paths) -> Self {
        Self {
            paths,
            records: HashMap::new(),
            readers: HashMap::new(),
            remote_progress: HashMap::new(),
        }
    }

    pub fn paths(&self) -> &Paths {
        &self.paths
    }

    /// The sessions working right now, oldest first. `include_terminal` also lists
    /// sessions started with the `claude` CLI (not opened from the desktop app).
    pub fn scan(&mut self, include_terminal: bool) -> Vec<Session> {
        let now = now_ms();
        let local = read_live_records(&self.paths.sessions_dir());
        #[cfg(windows)]
        let mut wsl_tables: HashMap<String, HashMap<String, StatusRecord>> = HashMap::new();
        let mut seen_cli: HashSet<String> = HashSet::new();
        let mut used_readers: HashSet<PathBuf> = HashSet::new();
        let mut out = Vec::new();

        // --- Desktop-app sessions (local, WSL, SSH)
        for (file, mtime) in find_record_files(&self.paths.desktop_roots) {
            let rec = match self.records.get(&file) {
                Some((t, r)) if *t == mtime => r.clone(),
                _ => {
                    let Some(r) = std::fs::read_to_string(&file)
                        .ok()
                        .and_then(|t| DesktopRecord::parse(&t))
                    else {
                        continue;
                    };
                    self.records.insert(file.clone(), (mtime, r.clone()));
                    r
                }
            };
            if rec.is_archived == Some(true) {
                continue;
            }
            let cli = rec.cli_session_id.clone().unwrap_or_default();
            let distro = rec.wsl_distro().map(str::to_string);
            let remote = rec.remote_transcript().map(str::to_string);

            // Preferred signal: the live claude process says busy / idle.
            let live: Option<StatusRecord> = if cli.is_empty() {
                None
            } else if let Some(d) = &distro {
                #[cfg(windows)]
                {
                    wsl_tables
                        .entry(d.clone())
                        .or_insert_with(|| crate::wsl::live_records(d))
                        .get(&cli)
                        .cloned()
                }
                #[cfg(not(windows))]
                {
                    let _ = d;
                    None
                }
            } else if remote.is_none() {
                local.get(&cli).cloned()
            } else {
                None
            };
            let since = match &live {
                Some(r) if !r.busy => continue,
                Some(r) => r.since_ms,
                None => {
                    if !rec.looks_running(now, STALE_MS) {
                        continue;
                    }
                    rec.latest_user_frame_at.unwrap_or(now)
                }
            };
            if !cli.is_empty() {
                seen_cli.insert(cli.clone());
            }

            let cwd = rec.cwd.clone().unwrap_or_default();
            let (location, progress) = match (&distro, &remote) {
                (Some(d), Some(path)) => (
                    Location::Wsl(d.clone()),
                    self.wsl_progress(&file, &rec, d, path),
                ),
                (Some(d), None) => (Location::Wsl(d.clone()), Progress::default()),
                (None, Some(_)) => (Location::Ssh, Progress::default()),
                (None, None) => {
                    let progress = self
                        .paths
                        .find_transcript(&cli, &cwd)
                        .map(|p| {
                            used_readers.insert(p.clone());
                            self.local_progress(&p)
                        })
                        .unwrap_or_default();
                    (Location::Local, progress)
                }
            };
            out.push(Session {
                id: rec
                    .session_id
                    .clone()
                    .filter(|s| !s.is_empty())
                    .unwrap_or(cli),
                name: rec
                    .title
                    .clone()
                    .filter(|t| !t.is_empty())
                    .unwrap_or_else(|| leaf_name(&cwd).to_string()),
                cwd,
                location,
                since_ms: since,
                progress,
            });
        }

        // --- Sessions started from a terminal (claude CLI)
        if include_terminal {
            for (sid, r) in &local {
                if !r.busy || r.entrypoint == "claude-desktop" || seen_cli.contains(sid) {
                    continue;
                }
                let mut progress = Progress::default();
                if let Some(p) = self.paths.find_transcript(sid, &r.cwd) {
                    if is_stale(&p, now) {
                        continue;
                    }
                    used_readers.insert(p.clone());
                    progress = self.local_progress(&p);
                }
                out.push(Session {
                    id: sid.clone(),
                    name: if r.name.is_empty() {
                        leaf_name(&r.cwd).to_string()
                    } else {
                        r.name.clone()
                    },
                    cwd: r.cwd.clone(),
                    location: Location::Terminal,
                    since_ms: r.since_ms,
                    progress,
                });
            }
        }

        // Forget readers of sessions that are no longer running.
        self.readers.retain(|p, _| used_readers.contains(p));
        out.sort_by(|a, b| a.since_ms.total_cmp(&b.since_ms));
        out
    }

    fn local_progress(&mut self, path: &Path) -> Progress {
        let reader = self
            .readers
            .entry(path.to_path_buf())
            .or_insert_with(|| TranscriptReader::new(path));
        let _ = reader.refresh();
        reader.progress().clone()
    }

    #[cfg_attr(not(windows), allow(unused_variables))]
    fn wsl_progress(
        &mut self,
        file: &Path,
        rec: &DesktopRecord,
        distro: &str,
        path: &str,
    ) -> Progress {
        let stamp = rec.last_activity_at.unwrap_or(0.0) as u64;
        if let Some((s, p)) = self.remote_progress.get(file)
            && *s == stamp
        {
            return p.clone();
        }
        #[cfg(windows)]
        let progress = {
            let lines = crate::wsl::transcript_lines(distro, path);
            crate::plan::replay_lines(lines.iter().map(String::as_str))
        };
        #[cfg(not(windows))]
        let progress = Progress::default();
        self.remote_progress
            .insert(file.to_path_buf(), (stamp, progress.clone()));
        progress
    }
}

fn is_stale(path: &Path, now: f64) -> bool {
    let modified = std::fs::metadata(path).and_then(|m| m.modified()).ok();
    let ms = modified
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as f64)
        .unwrap_or(now);
    now - ms > STALE_MS
}
