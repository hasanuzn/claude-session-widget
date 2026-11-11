//! Replays task-list tool calls from transcript lines.
//!
//! Rules (same as 1.x):
//! - `…update_plan` with non-empty `items`: replaces the list (missing status = pending).
//! - `…update_plan` with `advance: true`: completes the in-progress step and starts the next
//!   pending one after it (or the first pending one when nothing is in progress).
//! - `…update_plan` with `done: [n…]` (1-based) / `start: n`: completes / starts those steps.
//! - `TodoWrite` with non-empty `todos`: replaces the list; the in-progress item shows `activeForm`.
//! - `…wrap_up`: every step completed, activity = [`FINISHING`]; its `ask` (a question
//!   for the person) is kept in `question`.
//! - Any other tool: activity = [`tool_text`].
//! - `question` is cleared by any later tool call or by a message from the person.

use crate::model::{FINISHING, Progress, Step, StepStatus};
use crate::text::tool_text;
use serde_json::Value;
use std::collections::HashSet;

/// Progress built up by feeding transcript lines in order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PlanState {
    pub progress: Progress,
}

impl PlanState {
    /// Applies one transcript line. Returns true if it changed the progress.
    pub fn apply_line(&mut self, line: &str) -> bool {
        let line = line.trim_end_matches('\r');
        // Cheap filter before parsing JSON.
        if !line.contains("\"tool_use\"") {
            // A reply from the person answers the open question.
            if !self.progress.question.is_empty() && is_person_message(line) {
                self.progress.question.clear();
                return true;
            }
            return false;
        }
        let Ok(record) = serde_json::from_str::<Value>(line) else {
            return false;
        };
        if record.get("type").and_then(Value::as_str) != Some("assistant") {
            return false;
        }
        let Some(blocks) = record.pointer("/message/content").and_then(Value::as_array) else {
            return false;
        };
        let before = self.progress.clone();
        for block in blocks {
            if block.get("type").and_then(Value::as_str) != Some("tool_use") {
                continue;
            }
            let name = block.get("name").and_then(Value::as_str).unwrap_or("");
            self.apply_tool(name, block.get("input"));
        }
        self.progress != before
    }

    /// Applies one tool call.
    pub fn apply_tool(&mut self, name: &str, input: Option<&Value>) {
        // Any call after the question means the session went on without waiting.
        self.progress.question.clear();
        let steps = &mut self.progress.steps;
        if name.ends_with("update_plan") {
            let Some(input) = input else { return };
            if let Some(items) = input
                .get("items")
                .and_then(Value::as_array)
                .filter(|a| !a.is_empty())
            {
                *steps = items
                    .iter()
                    .map(|it| Step {
                        text: str_of(it, "content"),
                        status: StepStatus::parse(&str_of(it, "status")),
                    })
                    .collect();
            }
            if truthy(input.get("advance")) {
                let cur = steps
                    .iter()
                    .position(|s| s.status == StepStatus::InProgress);
                if let Some(c) = cur {
                    steps[c].status = StepStatus::Completed;
                }
                let from = cur.map(|c| c + 1).unwrap_or(0);
                if let Some(next) = steps
                    .iter()
                    .skip(from)
                    .position(|s| s.status == StepStatus::Pending)
                {
                    steps[from + next].status = StepStatus::InProgress;
                }
            }
            if let Some(done) = input.get("done").and_then(Value::as_array) {
                for d in done.iter().filter_map(index_of) {
                    if d >= 1 && d <= steps.len() {
                        steps[d - 1].status = StepStatus::Completed;
                    }
                }
            }
            if let Some(s) = input.get("start").and_then(index_of)
                && s >= 1
                && s <= steps.len()
            {
                steps[s - 1].status = StepStatus::InProgress;
            }
        } else if name == "TodoWrite" {
            let Some(todos) = input
                .and_then(|i| i.get("todos"))
                .and_then(Value::as_array)
                .filter(|a| !a.is_empty())
            else {
                return;
            };
            *steps = todos
                .iter()
                .map(|t| {
                    let status = StepStatus::parse(&str_of(t, "status"));
                    let active = str_of(t, "activeForm");
                    let text = if status == StepStatus::InProgress && !active.is_empty() {
                        active
                    } else {
                        str_of(t, "content")
                    };
                    Step { text, status }
                })
                .collect();
        } else if name.ends_with("wrap_up") {
            for s in steps.iter_mut() {
                s.status = StepStatus::Completed;
            }
            self.progress.activity = FINISHING.to_string();
            self.progress.question = input
                .map(|i| str_of(i, "ask").trim().to_string())
                .unwrap_or_default();
        } else {
            self.progress.activity = tool_text(name, input);
        }
    }

    /// True for a line that replaces the whole task list (a safe point to start replaying from).
    pub fn is_reset_line(line: &str) -> bool {
        if !line.contains("\"tool_use\"")
            || !(line.contains("update_plan") || line.contains("TodoWrite"))
        {
            return false;
        }
        let Ok(record) = serde_json::from_str::<Value>(line.trim_end_matches('\r')) else {
            return false;
        };
        // Only the assistant's own records: other lines (e.g. "api-request-blob") embed
        // copies of earlier messages, including old task lists.
        if record.get("type").and_then(Value::as_str) != Some("assistant") {
            return false;
        }
        let Some(blocks) = record.pointer("/message/content").and_then(Value::as_array) else {
            return false;
        };
        blocks.iter().any(|b| {
            let name = b.get("name").and_then(Value::as_str).unwrap_or("");
            let key = if name.ends_with("update_plan") {
                "items"
            } else if name == "TodoWrite" {
                "todos"
            } else {
                return false;
            };
            b.pointer(&format!("/input/{key}"))
                .and_then(Value::as_array)
                .is_some_and(|a| !a.is_empty())
        })
    }
}

/// Replays a batch of lines (1.x `ConvertFrom-TranscriptLines`): identical lines,
/// ignoring a trailing CR, are applied only once.
pub fn replay_lines<'a>(lines: impl IntoIterator<Item = &'a str>) -> Progress {
    let mut state = PlanState::default();
    let mut seen = HashSet::new();
    for line in lines {
        let line = line.trim_end_matches('\r');
        if line.trim().is_empty() || !seen.insert(line.to_string()) {
            continue;
        }
        state.apply_line(line);
    }
    state.progress
}

/// A message the person typed (or a button they clicked): a `user` record with text,
/// not a tool result and not a message the app added on its own (`isMeta`).
fn is_person_message(line: &str) -> bool {
    if !line.contains("\"user\"") {
        return false;
    }
    let Ok(record) = serde_json::from_str::<Value>(line.trim_end_matches('\r')) else {
        return false;
    };
    if record.get("type").and_then(Value::as_str) != Some("user") || truthy(record.get("isMeta")) {
        return false;
    }
    match record.pointer("/message/content") {
        Some(Value::String(s)) => !s.trim().is_empty(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .any(|b| b.get("type").and_then(Value::as_str) == Some("text")),
        _ => false,
    }
}

fn str_of(v: &Value, key: &str) -> String {
    match v.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

fn truthy(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|f| f != 0.0),
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(_)) => true,
        _ => false,
    }
}

/// A 1-based index given as a number or a numeric string.
fn index_of(v: &Value) -> Option<usize> {
    match v {
        Value::Number(n) => n.as_f64().filter(|f| *f >= 0.0).map(|f| f as usize),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}
