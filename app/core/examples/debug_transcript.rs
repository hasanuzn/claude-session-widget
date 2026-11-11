//! Compares the incremental reader with a full replay of one transcript.
//!   cargo run -p claude-session-core --example debug_transcript -- <file.jsonl>
use claude_session_core::{TranscriptReader, plan::PlanState};
fn main() {
    let path = std::env::args().nth(1).expect("path");
    let mut r = TranscriptReader::new(&path);
    r.refresh().unwrap();
    let p = r.progress();
    println!(
        "reader : {}/{} current={:?} activity={:?}",
        p.done(),
        p.total(),
        p.current(),
        p.activity
    );
    let text = std::fs::read_to_string(&path).unwrap();
    let mut full = PlanState::default();
    let mut resets = 0;
    for l in text.lines() {
        if PlanState::is_reset_line(l) {
            resets += 1;
        }
        full.apply_line(l);
    }
    let f = &full.progress;
    println!(
        "full   : {}/{} current={:?} activity={:?} resets={resets}",
        f.done(),
        f.total(),
        f.current(),
        f.activity
    );
}
