//! Port of the 1.x Pester tests for ConvertFrom-TranscriptLines (tests/Scanner.Tests.ps1).

mod common;

use claude_session_core::model::FINISHING;
use claude_session_core::{Progress, replay_lines};
use common::{fixture_lines, statuses, tool_line};
use serde_json::json;

fn replay(lines: &[String]) -> Progress {
    replay_lines(lines.iter().map(String::as_str))
}

fn fixture(name: &str) -> Progress {
    replay(&fixture_lines(name))
}

// --- update_plan items

#[test]
fn items_replace_the_whole_list() {
    let r = fixture("plan-items.jsonl");
    assert_eq!(r.total(), 4);
    assert_eq!(r.done(), 1);
    assert_eq!(r.current(), "Write Pester tests");
    assert_eq!(r.steps[0].text, "Look at the repo");
    assert_eq!(r.steps[3].text, "Package a release");
}

#[test]
fn missing_status_defaults_to_pending() {
    let r = fixture("plan-items.jsonl");
    assert_eq!(statuses(&r), "completed,in_progress,pending,pending");
}

#[test]
fn tool_results_from_the_user_do_not_affect_the_plan() {
    let lines = fixture_lines("plan-items.jsonl");
    let r = replay(&lines[0..3]);
    assert_eq!(r.total(), 3);
    assert_eq!(r.current(), "Look at the repo");
}

// --- update_plan advance

#[test]
fn advance_completes_current_and_starts_next_once_per_call() {
    let r = fixture("plan-advance.jsonl");
    assert_eq!(statuses(&r), "completed,completed,in_progress");
    assert_eq!(r.done(), 2);
    assert_eq!(r.total(), 3);
    assert_eq!(r.current(), "Write tests");
}

#[test]
fn advance_completes_the_last_step_when_nothing_is_pending() {
    let mut lines = fixture_lines("plan-advance.jsonl");
    lines.push(tool_line(
        "mcp__ccd_turn__update_plan",
        json!({ "advance": true }),
    ));
    let r = replay(&lines);
    assert_eq!(statuses(&r), "completed,completed,completed");
    assert_eq!(r.done(), 3);
    assert_eq!(r.current(), "");
}

#[test]
fn advance_starts_the_first_pending_step_when_nothing_is_in_progress() {
    let lines = vec![
        tool_line(
            "mcp__ccd_turn__update_plan",
            json!({ "items": [ { "content": "A", "status": "pending" }, { "content": "B", "status": "pending" } ] }),
        ),
        tool_line("mcp__ccd_turn__update_plan", json!({ "advance": true })),
    ];
    let r = replay(&lines);
    assert_eq!(statuses(&r), "in_progress,pending");
    assert_eq!(r.current(), "A");
}

// --- update_plan done / start

#[test]
fn done_and_start_use_one_based_indexes() {
    let r = fixture("plan-done-start.jsonl");
    assert_eq!(statuses(&r), "completed,completed,in_progress,pending");
    assert_eq!(r.done(), 2);
    assert_eq!(r.total(), 4);
    assert_eq!(r.current(), "Fix it");
}

#[test]
fn out_of_range_done_and_start_are_ignored() {
    let lines = vec![
        tool_line(
            "mcp__ccd_turn__update_plan",
            json!({ "items": [ { "content": "A", "status": "pending" } ] }),
        ),
        tool_line(
            "mcp__ccd_turn__update_plan",
            json!({ "done": [0, 2, 7], "start": 5 }),
        ),
    ];
    let r = replay(&lines);
    assert_eq!(statuses(&r), "pending");
    assert_eq!(r.done(), 0);
}

// --- TodoWrite

#[test]
fn todowrite_replaces_the_list_and_shows_active_form() {
    let r = fixture("todowrite.jsonl");
    assert_eq!(r.total(), 3);
    assert_eq!(r.done(), 1);
    assert_eq!(r.current(), "Fixing type errors");
    assert_eq!(r.steps[0].text, "Run the linter");
    assert_eq!(r.steps[1].text, "Fixing type errors");
    assert_eq!(r.steps[2].text, "Write changelog");
    assert_eq!(statuses(&r), "completed,in_progress,pending");
}

// --- wrap_up

#[test]
fn wrap_up_completes_everything_and_sets_finishing() {
    let r = fixture("wrap-up.jsonl");
    assert_eq!(r.done(), 3);
    assert_eq!(r.total(), 3);
    assert_eq!(statuses(&r), "completed,completed,completed");
    assert_eq!(r.current(), "");
    assert_eq!(r.activity, FINISHING);
}

// --- Activity label

#[test]
fn activity_prefers_description_over_command() {
    let r = fixture("activity.jsonl");
    assert_eq!(r.activity, "Bash · Run Pester tests");
    assert_eq!(r.total(), 0);
}

#[test]
fn activity_falls_back_to_command() {
    let r = replay(&[tool_line("Bash", json!({ "command": "git status" }))]);
    assert_eq!(r.activity, "Bash · git status");
}

#[test]
fn activity_uses_the_part_after_the_last_double_underscore_for_mcp_tools() {
    let r = replay(&[tool_line(
        "mcp__claude-in-chrome__navigate",
        json!({ "url": "https://example.com/docs" }),
    )]);
    assert_eq!(r.activity, "navigate · https://example.com/docs");
}

#[test]
fn activity_uses_file_path_for_read() {
    let r = replay(&[tool_line(
        "Read",
        json!({ "file_path": r"C:\repo\README.md" }),
    )]);
    assert_eq!(r.activity, r"Read · C:\repo\README.md");
}

#[test]
fn activity_shows_only_the_label_without_a_known_key() {
    let r = replay(&[tool_line(
        "mcp__sqlcl__sql_run",
        json!({ "sql": "select 1 from dual" }),
    )]);
    assert_eq!(r.activity, "sql_run");
}

#[test]
fn activity_collapses_whitespace_and_cuts_to_70_chars() {
    let long = format!("echo   one\n{}", "x".repeat(100));
    let r = replay(&[tool_line("Bash", json!({ "command": long }))]);
    let detail = r.activity.strip_prefix("Bash · ").expect("prefix");
    assert_eq!(detail.chars().count(), 70);
    assert!(detail.starts_with("echo one x"));
    assert!(detail.ends_with('…'));
}

#[test]
fn ordinary_tools_do_not_change_the_plan() {
    let mut lines = fixture_lines("plan-items.jsonl");
    lines.push(tool_line("Bash", json!({ "command": "dir" })));
    let r = replay(&lines);
    assert_eq!(r.total(), 4);
    assert_eq!(r.current(), "Write Pester tests");
    assert_eq!(r.activity, "Bash · dir");
}

// --- Duplicate lines

#[test]
fn identical_lines_apply_once() {
    let r = fixture("duplicates.jsonl");
    assert_eq!(statuses(&r), "completed,in_progress,pending");
    assert_eq!(r.done(), 1);
    assert_eq!(r.current(), "Second");
}

#[test]
fn lines_differing_only_by_a_trailing_cr_are_duplicates() {
    let lines = fixture_lines("duplicates.jsonl");
    let r = replay(&[
        lines[0].clone(),
        lines[1].clone(),
        format!("{}\r", lines[1]),
    ]);
    assert_eq!(r.done(), 1);
}

// --- Malformed and empty input

#[test]
fn malformed_json_and_non_assistant_records_are_skipped() {
    let r = fixture("malformed.jsonl");
    assert_eq!(statuses(&r), "completed,in_progress");
    assert_eq!(r.current(), "Report");
    assert_eq!(r.activity, "");
}

#[test]
fn empty_input_gives_an_empty_result() {
    let r = replay(&[]);
    assert_eq!(
        (r.done(), r.total(), r.current(), r.activity.as_str()),
        (0, 0, "", "")
    );
}

#[test]
fn blank_lines_give_an_empty_result() {
    let r = replay(&["".into(), "   ".into(), "\r".into()]);
    assert_eq!(r.total(), 0);
    assert_eq!(r.activity, "");
}

// --- wrap_up question (sessions waiting for an answer)

fn person(text: &str) -> String {
    json!({ "type": "user", "message": { "role": "user", "content": text } }).to_string()
}

#[test]
fn wrap_up_keeps_its_question_until_the_person_replies() {
    let ask = tool_line(
        "mcp__ccd_turn__wrap_up",
        json!({ "recap": "Done.", "ask": "  Push the branch?  " }),
    );
    // The tool result for wrap_up is a user record too, but not a reply.
    let result = json!({ "type": "user", "message": { "role": "user", "content": [
        { "type": "tool_result", "tool_use_id": "toolu_x", "content": "ok" } ] } })
    .to_string();
    // Something the app added on its own does not count either.
    let meta =
        json!({ "type": "user", "isMeta": true, "message": { "role": "user", "content": "note" } })
            .to_string();

    let p = replay(&[ask.clone(), result.clone(), meta]);
    assert_eq!(p.question, "Push the branch?");
    assert_eq!(p.activity, FINISHING);

    let p = replay(&[ask.clone(), result.clone(), person("Yes")]);
    assert_eq!(p.question, "", "a reply answers the question");

    let blocks = json!({ "type": "user", "message": { "role": "user", "content": [
        { "type": "text", "text": "Yes, push it" } ] } })
    .to_string();
    assert_eq!(replay(&[ask.clone(), blocks]).question, "");
}

#[test]
fn any_later_tool_call_clears_the_question() {
    let ask = tool_line(
        "mcp__ccd_turn__wrap_up",
        json!({ "recap": "r", "ask": "Ship it?" }),
    );
    let next = tool_line("Bash", json!({ "command": "ls", "description": "List" }));
    assert_eq!(replay(&[ask, next]).question, "");
}

#[test]
fn wrap_up_without_a_question_waits_for_nothing() {
    let plain = tool_line("mcp__ccd_turn__wrap_up", json!({ "recap": "All done." }));
    assert_eq!(replay(&[plain]).question, "");
}
