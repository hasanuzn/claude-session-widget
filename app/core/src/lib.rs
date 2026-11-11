//! Finds the Claude Code sessions that are working right now and reads their
//! progress (task list and latest tool call). No UI: the widget and the
//! `claude-session-scan` tool build on this crate.
//!
//! Data sources (undocumented internal formats of Claude Code, read-only):
//! - `<claude dir>/sessions/<pid>.json`: one status record per running `claude`
//!   process (`busy` / `idle`). Trusted only while that process is alive.
//! - The Claude desktop app's session records (`…/claude-code-sessions/…/local_*.json`):
//!   titles, WSL distro, transcript location; fallback "running" signal for SSH.
//! - Transcripts, `<claude dir>/projects/<cwd slug>/<session id>.jsonl`: replayed
//!   for the task list (`update_plan`, `TodoWrite`, `wrap_up`) and the latest tool call.

pub mod desktop;
pub mod model;
pub mod paths;
pub mod plan;
pub mod process;
pub mod scan;
pub mod status;
pub mod text;
pub mod transcript;
#[cfg(windows)]
pub mod wsl;

pub use model::{Location, Progress, Session, Step, StepStatus};
pub use paths::Paths;
pub use plan::{PlanState, replay_lines};
pub use scan::Scanner;
pub use transcript::TranscriptReader;

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}
