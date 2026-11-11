//! Where the sessions come from: a background thread running the core scanner,
//! or fixed demo data (for screenshots and UI work).

use claude_session_core::{Location, Paths, Progress, Scanner, Session, Step, StepStatus, now_ms};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;

/// Knobs the UI can change while the scanner runs.
#[derive(Clone)]
pub struct FeedControl {
    pub include_terminal: Arc<AtomicBool>,
    pub refresh_sec: Arc<AtomicU32>,
}

/// Starts the scanner thread. Each scan result is sent on the channel and `wake` is
/// called so the UI repaints; nothing else wakes the UI.
pub fn start(control: FeedControl, wake: impl Fn() + Send + 'static) -> Receiver<Vec<Session>> {
    let (tx, rx): (Sender<Vec<Session>>, _) = channel();
    std::thread::Builder::new()
        .name("scanner".into())
        .spawn(move || {
            let mut scanner = Scanner::new(Paths::detect());
            let mut last: Option<Vec<Session>> = None;
            loop {
                let sessions = scanner.scan(control.include_terminal.load(Ordering::Relaxed));
                // Only wake the UI when something it shows has changed.
                if last.as_ref() != Some(&sessions) {
                    if tx.send(sessions.clone()).is_err() {
                        return;
                    }
                    wake();
                    last = Some(sessions);
                }
                let secs = control.refresh_sec.load(Ordering::Relaxed).max(1);
                std::thread::sleep(Duration::from_secs(secs as u64));
            }
        })
        .expect("scanner thread");
    rx
}

/// Three made-up sessions, plus the name of one that already finished.
pub fn demo() -> (Vec<Session>, Vec<(String, f64)>) {
    use StepStatus::*;
    let now = now_ms();
    let step = |t: &str, s| Step {
        text: t.to_string(),
        status: s,
    };
    let sessions = vec![
        Session {
            id: "demo-1".into(),
            name: "Refactor auth module".into(),
            cwd: r"C:\work\acme-web".into(),
            location: Location::Local,
            since_ms: now - 7.0 * 60_000.0,
            progress: Progress {
                steps: vec![
                    step("Read the current auth flow", Completed),
                    step("Extract token helpers", Completed),
                    step("Update login handler", Completed),
                    step("Run the test suite", InProgress),
                    step("Summarize the changes", Pending),
                ],
                activity: "Bash · Run unit tests".into(),
            },
        },
        Session {
            id: "demo-2".into(),
            name: "Write API docs".into(),
            cwd: "/home/dev/acme-api".into(),
            location: Location::Wsl("Ubuntu".into()),
            since_ms: now - 3.0 * 60_000.0,
            progress: Progress {
                steps: vec![
                    step("Collect endpoints", Completed),
                    step("Draft reference pages", InProgress),
                    step("Add examples", Pending),
                    step("Review", Pending),
                ],
                activity: "Read · src/routes/users.ts".into(),
            },
        },
        Session {
            id: "demo-3".into(),
            name: "Fix flaky CI job".into(),
            cwd: r"C:\work\acme-ci".into(),
            location: Location::Terminal,
            since_ms: now - 48_000.0,
            progress: Progress {
                steps: vec![],
                activity: "Grep · retry".into(),
            },
        },
    ];
    (
        sessions,
        vec![("Update dependencies".into(), now - 4.0 * 60_000.0)],
    )
}
