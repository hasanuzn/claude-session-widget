//! Small text helpers.

use serde_json::Value;

/// Collapses whitespace runs to one space, trims, and cuts to `max` characters
/// with a trailing `…` (the result is then exactly `max` characters).
pub fn short_text(text: &str, max: usize) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() > max {
        let mut out: String = collapsed.chars().take(max.saturating_sub(1)).collect();
        out.push('…');
        out
    } else {
        collapsed
    }
}

/// Last segment of a Windows or POSIX path ("" for an empty path).
pub fn leaf_name(path: &str) -> &str {
    path.split(['\\', '/'])
        .rfind(|s| !s.is_empty())
        .unwrap_or("")
}

/// Keys tried, in order, for the detail shown after a tool name.
const DETAIL_KEYS: [&str; 7] = [
    "description",
    "file_path",
    "pattern",
    "query",
    "url",
    "command",
    "prompt",
];

/// Short description of a tool call, e.g. "Bash · Run unit tests" or "navigate · https://…".
/// For `mcp__server__tool` names only the part after the last `__` is shown.
pub fn tool_text(name: &str, input: Option<&Value>) -> String {
    let label = if name.starts_with("mcp__") {
        name.rsplit("__").next().unwrap_or(name)
    } else {
        name
    };
    if let Some(Value::Object(map)) = input {
        for key in DETAIL_KEYS {
            let detail = match map.get(key) {
                Some(Value::String(s)) if !s.is_empty() => s.clone(),
                Some(Value::Number(n)) if n.as_f64() != Some(0.0) => n.to_string(),
                Some(Value::Bool(true)) => "True".to_string(),
                _ => continue,
            };
            return format!("{label} · {}", short_text(&detail, 70));
        }
    }
    label.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_text_collapses_and_cuts() {
        assert_eq!(short_text("  a \n\t b  ", 80), "a b");
        let s = short_text(&"x".repeat(100), 70);
        assert_eq!(s.chars().count(), 70);
        assert!(s.ends_with('…'));
    }

    #[test]
    fn leaf_name_handles_both_separators() {
        assert_eq!(leaf_name(r"C:\work\acme-web"), "acme-web");
        assert_eq!(leaf_name("/home/me/acme-api/"), "acme-api");
        assert_eq!(leaf_name(""), "");
    }
}
