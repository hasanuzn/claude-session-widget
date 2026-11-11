//! Helpers shared by the integration tests.
#![allow(dead_code)]

use serde_json::{Value, json};
use std::path::PathBuf;

/// The transcript fixtures shared with the 1.x Pester tests (`tests/fixtures`).
pub fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

pub fn fixture_lines(name: &str) -> Vec<String> {
    let text = std::fs::read_to_string(fixture_path(name)).expect("fixture");
    text.trim_start_matches('\u{feff}')
        .lines()
        .map(str::to_string)
        .collect()
}

/// One assistant transcript line holding a single tool_use block.
pub fn tool_line(name: &str, input: Value) -> String {
    json!({
        "type": "assistant",
        "uuid": format!("u-{name}-{}", rand_id()),
        "message": { "role": "assistant", "content": [ { "type": "tool_use", "id": "toolu_x", "name": name, "input": input } ] }
    })
    .to_string()
}

fn rand_id() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    N.fetch_add(1, Ordering::Relaxed)
}

/// A fresh, empty folder under the system temp dir (removed on drop).
pub struct Sandbox(pub PathBuf);

impl Sandbox {
    pub fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "csw-test-{tag}-{}-{}",
            std::process::id(),
            rand_id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn statuses(p: &claude_session_core::Progress) -> String {
    p.steps
        .iter()
        .map(|s| s.status.as_str())
        .collect::<Vec<_>>()
        .join(",")
}
