//! Prints the Claude sessions working right now, one per line (same format as
//! 1.x `claude-session-widget.ps1 -Test`), then exits. Useful for bug reports.
//!
//!   claude-session-scan [--no-terminal]

use claude_session_core::{Paths, Scanner};

fn main() {
    let include_terminal = !std::env::args().any(|a| a == "--no-terminal");
    let mut scanner = Scanner::new(Paths::detect());
    let sessions = scanner.scan(include_terminal);
    if sessions.is_empty() {
        println!("No sessions running right now.");
    }
    for s in &sessions {
        let p = &s.progress;
        println!(
            "{}  [{}]  {}/{}  ▸ {}  ⎿ {}",
            s.name,
            s.location,
            p.done(),
            p.total(),
            p.current(),
            p.activity
        );
    }
}
