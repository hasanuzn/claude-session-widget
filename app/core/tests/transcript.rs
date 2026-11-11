//! The incremental transcript reader (new in 2.0).

mod common;

use claude_session_core::TranscriptReader;
use common::{Sandbox, fixture_lines, statuses, tool_line};
use serde_json::json;
use std::io::Write;

fn append(path: &std::path::Path, text: &str) {
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    f.write_all(text.as_bytes()).unwrap();
}

#[test]
fn reads_a_whole_small_file_then_only_what_is_appended() {
    let sb = Sandbox::new("incr");
    let path = sb.0.join("t.jsonl");
    for l in fixture_lines("plan-advance.jsonl").iter().take(1) {
        append(&path, &format!("{l}\n"));
    }
    let mut r = TranscriptReader::new(&path);
    assert!(r.refresh().unwrap());
    assert_eq!(statuses(r.progress()), "in_progress,pending,pending");

    // Nothing new: no change.
    assert!(!r.refresh().unwrap());

    append(
        &path,
        &format!(
            "{}\n",
            tool_line("mcp__ccd_turn__update_plan", json!({ "advance": true }))
        ),
    );
    assert!(r.refresh().unwrap());
    assert_eq!(statuses(r.progress()), "completed,in_progress,pending");
}

#[test]
fn waits_for_a_line_to_be_complete() {
    let sb = Sandbox::new("partial");
    let path = sb.0.join("t.jsonl");
    let line = tool_line("Bash", json!({ "description": "Build" }));
    let (a, b) = line.split_at(line.len() / 2);
    append(&path, a);
    let mut r = TranscriptReader::new(&path);
    r.refresh().unwrap();
    assert_eq!(r.progress().activity, "");
    append(&path, &format!("{b}\n"));
    r.refresh().unwrap();
    assert_eq!(r.progress().activity, "Bash · Build");
}

#[test]
fn starts_over_when_the_file_is_rewritten_shorter() {
    let sb = Sandbox::new("shrink");
    let path = sb.0.join("t.jsonl");
    let long: String = fixture_lines("plan-items.jsonl")
        .iter()
        .map(|l| format!("{l}\n"))
        .collect();
    append(&path, &long);
    let mut r = TranscriptReader::new(&path);
    r.refresh().unwrap();
    assert_eq!(r.progress().total(), 4);

    std::fs::write(
        &path,
        format!("{}\n", tool_line("Bash", json!({ "command": "ls" }))),
    )
    .unwrap();
    r.refresh().unwrap();
    assert_eq!(r.progress().total(), 0);
    assert_eq!(r.progress().activity, "Bash · ls");
}

#[test]
fn large_file_starts_from_the_last_task_list_reset() {
    let sb = Sandbox::new("large");
    let path = sb.0.join("t.jsonl");
    let filler = format!(
        "{}\n",
        json!({ "type": "user", "message": { "content": "x".repeat(4000) } })
    );
    let mut text = String::new();
    // An old plan that must be ignored, ~6 MB of filler, then the current plan and a tool call.
    text.push_str(&format!(
        "{}\n",
        tool_line(
            "mcp__ccd_turn__update_plan",
            json!({ "items": [ { "content": "Old", "status": "in_progress" } ] })
        )
    ));
    while text.len() < 6 * 1024 * 1024 {
        text.push_str(&filler);
    }
    text.push_str(&format!(
        "{}\n",
        tool_line("mcp__ccd_turn__update_plan", json!({ "items": [ { "content": "New A", "status": "completed" }, { "content": "New B", "status": "in_progress" } ] }))
    ));
    for _ in 0..200 {
        text.push_str(&filler); // more than the tail window after the reset
    }
    text.push_str(&format!(
        "{}\n",
        tool_line("Grep", json!({ "pattern": "retry" }))
    ));
    std::fs::write(&path, text).unwrap();

    let mut r = TranscriptReader::new(&path);
    r.refresh().unwrap();
    assert_eq!(statuses(r.progress()), "completed,in_progress");
    assert_eq!(r.progress().current(), "New B");
    assert_eq!(r.progress().activity, "Grep · retry");
}

#[test]
fn copies_of_old_task_lists_inside_other_records_are_not_used_as_a_start() {
    // Claude Code also writes "api-request-blob" lines that embed earlier messages,
    // old task lists included. Only the assistant's own records count.
    let sb = Sandbox::new("blob");
    let path = sb.0.join("t.jsonl");
    let filler = format!(
        "{}\n",
        json!({ "type": "user", "message": { "content": "x".repeat(4000) } })
    );
    let real = tool_line(
        "mcp__ccd_turn__update_plan",
        json!({ "items": [ { "content": "Real", "status": "in_progress" } ] }),
    );
    let old_copy = tool_line(
        "mcp__ccd_turn__update_plan",
        json!({ "items": [ { "content": "Stale copy", "status": "in_progress" } ] }),
    );
    let blob = json!({ "type": "api-request-blob", "message": { "content": [ serde_json::from_str::<serde_json::Value>(&old_copy).unwrap()["message"]["content"][0].clone() ] }, "raw": old_copy }).to_string();
    let mut text = String::new();
    while text.len() < 5 * 1024 * 1024 {
        text.push_str(&filler);
    }
    text.push_str(&format!("{real}\n"));
    for _ in 0..200 {
        text.push_str(&filler);
    }
    text.push_str(&format!("{blob}\n"));
    std::fs::write(&path, text).unwrap();

    let mut r = TranscriptReader::new(&path);
    r.refresh().unwrap();
    assert_eq!(r.progress().current(), "Real");
}
