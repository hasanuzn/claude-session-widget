//! Reading inside WSL distros (Windows only). One-shot `wsl.exe` calls, as in 1.x;
//! phase 3 replaces this with one long-lived process per distro.

use crate::status::{StatusRecord, records_from_texts};
use std::collections::HashMap;
use std::io::Write;
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Runs a POSIX shell script inside the distro (`sh -s -- args…`) and returns stdout.
fn run_sh(distro: &str, script: &str, args: &[&str]) -> Option<String> {
    let mut cmd = Command::new("wsl.exe");
    cmd.args(["-d", distro, "-e", "sh", "-s", "--"]).args(args);
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW);
    let mut child = cmd.spawn().ok()?;
    child.stdin.take()?.write_all(script.as_bytes()).ok()?;
    let out = child.wait_with_output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Live status records inside the distro (process alive checked there with `kill -0`).
pub fn live_records(distro: &str) -> HashMap<String, StatusRecord> {
    let script = "for f in \"$HOME\"/.claude/sessions/*.json; do [ -f \"$f\" ] || continue; \
                  p=$(basename \"$f\" .json); kill -0 \"$p\" 2>/dev/null && { tr -d '\\r\\n' < \"$f\"; echo; }; done\n";
    match run_sh(distro, script, &[]) {
        Some(out) => records_from_texts(out.lines()),
        None => HashMap::new(),
    }
}

/// The interesting lines of a transcript inside the distro: the last task-list
/// updates plus the last tool calls (same selection as 1.x).
pub fn transcript_lines(distro: &str, path: &str) -> Vec<String> {
    let script = "grep -E 'update_plan|TodoWrite|wrap_up' \"$1\" | tail -n 60\n\
                  tail -n 300 \"$1\" | grep '\"tool_use\"' | tail -n 20\n";
    run_sh(distro, script, &[path])
        .map(|s| s.lines().map(str::to_string).collect())
        .unwrap_or_default()
}
