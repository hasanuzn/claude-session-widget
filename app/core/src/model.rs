//! Plain data types shared by the scanner and the UI.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepStatus {
    Pending,
    InProgress,
    Completed,
}

impl StepStatus {
    /// Parses the status strings used by `update_plan` / `TodoWrite`.
    /// Anything unknown (including an empty string) counts as pending.
    pub fn parse(s: &str) -> Self {
        match s {
            "completed" => Self::Completed,
            "in_progress" => Self::InProgress,
            _ => Self::Pending,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::InProgress => "in_progress",
            Self::Completed => "completed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub text: String,
    pub status: StepStatus,
}

/// Activity value meaning "the session called wrap_up" (the UI translates it).
pub const FINISHING: &str = "@finishing";

/// Task-list progress and the latest tool call of one session.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Progress {
    pub steps: Vec<Step>,
    /// e.g. "Bash · Run unit tests", or [`FINISHING`], or empty.
    pub activity: String,
}

impl Progress {
    pub fn total(&self) -> usize {
        self.steps.len()
    }

    pub fn done(&self) -> usize {
        self.steps
            .iter()
            .filter(|s| s.status == StepStatus::Completed)
            .count()
    }

    /// Text of the first in-progress step, or "".
    pub fn current(&self) -> &str {
        self.steps
            .iter()
            .find(|s| s.status == StepStatus::InProgress)
            .map(|s| s.text.as_str())
            .unwrap_or("")
    }
}

/// Where a session runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Location {
    /// Desktop app, on this machine.
    Local,
    /// Started with the `claude` CLI on this machine.
    Terminal,
    /// Desktop app, on a remote SSH host (progress is not readable).
    Ssh,
    /// Desktop app, inside a WSL distro.
    Wsl(String),
}

impl fmt::Display for Location {
    /// Same codes as 1.x (`local`, `terminal`, `SSH`, `WSL · <distro>`); the UI translates them.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Local => f.write_str("local"),
            Self::Terminal => f.write_str("terminal"),
            Self::Ssh => f.write_str("SSH"),
            Self::Wsl(d) => write!(f, "WSL · {d}"),
        }
    }
}

/// A session that is working right now.
#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub location: Location,
    /// When it became busy (ms since the Unix epoch).
    pub since_ms: f64,
    pub progress: Progress,
}
