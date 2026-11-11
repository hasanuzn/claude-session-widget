//! Port of the 1.x Pester tests for Get-ClaudeSession, plus desktop-app records.

mod common;

use claude_session_core::{Location, Paths, Scanner, now_ms};
use common::{Sandbox, fixture_path};
use serde_json::json;
use std::path::Path;

fn paths(sb: &Sandbox) -> Paths {
    let claude_dir = sb.0.join(".claude");
    std::fs::create_dir_all(claude_dir.join("sessions")).unwrap();
    std::fs::create_dir_all(claude_dir.join("projects")).unwrap();
    Paths {
        claude_dir,
        desktop_roots: vec![sb.0.join("desktop")],
    }
}

fn write_status(
    p: &Paths,
    pid: u32,
    session_id: &str,
    cwd: &str,
    status: &str,
    entrypoint: &str,
    name: &str,
) {
    let now = now_ms();
    let rec = json!({
        "pid": pid, "sessionId": session_id, "cwd": cwd, "name": name, "status": status,
        "entrypoint": entrypoint, "startedAt": now - 60000.0, "statusUpdatedAt": now - 1000.0
    });
    std::fs::write(
        p.sessions_dir().join(format!("{pid}.json")),
        rec.to_string(),
    )
    .unwrap();
}

fn write_transcript(p: &Paths, session_id: &str, cwd: &str, fixture: &str) {
    let dir = p
        .projects_dir()
        .join(claude_session_core::paths::cwd_slug(cwd));
    std::fs::create_dir_all(&dir).unwrap();
    // Write (not copy) so the file is fresh: a copy keeps the fixture's old mtime and
    // the session would count as stale.
    let text = std::fs::read(fixture_path(fixture)).unwrap();
    std::fs::write(dir.join(format!("{session_id}.jsonl")), text).unwrap();
}

fn write_desktop(root: &Path, file: &str, record: serde_json::Value) {
    let dir = root.join("acct").join("org");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(file), record.to_string()).unwrap();
}

const DEAD_PID: u32 = 0x7FFF_FFF0;

#[test]
fn nothing_running_gives_no_sessions() {
    let sb = Sandbox::new("empty");
    let mut s = Scanner::new(paths(&sb));
    assert!(s.scan(true).is_empty());
}

#[test]
fn busy_terminal_session_is_listed_with_its_progress() {
    let sb = Sandbox::new("cli");
    let p = paths(&sb);
    let id = "7b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e";
    let cwd = r"C:\work\demo-project";
    write_status(
        &p,
        std::process::id(),
        id,
        cwd,
        "busy",
        "cli",
        "Demo session",
    );
    write_transcript(&p, id, cwd, "plan-done-start.jsonl");

    let mut s = Scanner::new(p);
    let found = s.scan(true);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].id, id);
    assert_eq!(found[0].name, "Demo session");
    assert_eq!(found[0].location, Location::Terminal);
    assert_eq!(found[0].progress.done(), 2);
    assert_eq!(found[0].progress.total(), 4);
    assert_eq!(found[0].progress.current(), "Fix it");

    // Hidden without include_terminal.
    assert!(s.scan(false).is_empty());
}

#[test]
fn busy_record_of_an_exited_process_is_ignored() {
    let sb = Sandbox::new("dead");
    let p = paths(&sb);
    write_status(
        &p,
        DEAD_PID,
        "0d0d0d0d-1111-4222-8333-944444444444",
        r"C:\work\x",
        "busy",
        "cli",
        "Crashed session",
    );
    let mut s = Scanner::new(p);
    assert!(s.scan(true).is_empty());
}

#[test]
fn idle_session_is_not_listed() {
    let sb = Sandbox::new("idle");
    let p = paths(&sb);
    write_status(
        &p,
        std::process::id(),
        "11111111-2222-4333-8444-555555555555",
        r"C:\work\y",
        "idle",
        "cli",
        "Idle",
    );
    let mut s = Scanner::new(p);
    assert!(s.scan(true).is_empty());
}

#[test]
fn desktop_session_uses_its_title_and_the_live_record() {
    let sb = Sandbox::new("desktop");
    let p = paths(&sb);
    let cli = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    let cwd = r"C:\work\acme-web";
    write_status(
        &p,
        std::process::id(),
        cli,
        cwd,
        "busy",
        "claude-desktop",
        "ignored name",
    );
    write_transcript(&p, cli, cwd, "plan-advance.jsonl");
    write_desktop(
        &p.desktop_roots[0],
        "local_one.json",
        json!({ "sessionId": "local_one", "cliSessionId": cli, "title": "Refactor auth", "cwd": cwd, "isArchived": false }),
    );
    let mut s = Scanner::new(p);
    let found = s.scan(true);
    assert_eq!(
        found.len(),
        1,
        "the desktop session must not also be listed as a terminal session"
    );
    assert_eq!(found[0].id, "local_one");
    assert_eq!(found[0].name, "Refactor auth");
    assert_eq!(found[0].location, Location::Local);
    assert_eq!(found[0].progress.current(), "Write tests");
}

#[test]
fn desktop_session_with_an_idle_live_record_is_not_listed() {
    let sb = Sandbox::new("desktop-idle");
    let p = paths(&sb);
    let cli = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    write_status(
        &p,
        std::process::id(),
        cli,
        r"C:\w",
        "idle",
        "claude-desktop",
        "",
    );
    let now = now_ms();
    // Turn timestamps alone would say "running"; the live record wins.
    write_desktop(
        &p.desktop_roots[0],
        "local_two.json",
        json!({ "sessionId": "local_two", "cliSessionId": cli, "title": "T", "cwd": r"C:\w",
                "latestUserFrameAt": now - 1000.0, "lastTurnEdgeAt": now - 2000.0, "lastActivityAt": now - 500.0 }),
    );
    let mut s = Scanner::new(p);
    assert!(s.scan(true).is_empty());
}

#[test]
fn ssh_session_falls_back_to_turn_timestamps() {
    let sb = Sandbox::new("ssh");
    let p = paths(&sb);
    let now = now_ms();
    write_desktop(
        &p.desktop_roots[0],
        "local_ssh.json",
        json!({ "sessionId": "local_ssh", "cliSessionId": "cccccccc-0000-4000-8000-000000000000", "title": "Remote work",
                "cwd": "/srv/app", "sshRemoteTranscriptPath": "/home/me/.claude/projects/x/y.jsonl",
                "latestUserFrameAt": now - 1000.0, "lastTurnEdgeAt": now - 2000.0, "lastActivityAt": now - 500.0 }),
    );
    write_desktop(
        &p.desktop_roots[0],
        "local_ssh_done.json",
        json!({ "sessionId": "local_ssh_done", "cliSessionId": "dddddddd-0000-4000-8000-000000000000", "title": "Done",
                "cwd": "/srv/app", "sshRemoteTranscriptPath": "/home/me/x.jsonl",
                "latestUserFrameAt": now - 3000.0, "lastTurnEdgeAt": now - 1000.0 }),
    );
    write_desktop(
        &p.desktop_roots[0],
        "local_archived.json",
        json!({ "sessionId": "a", "isArchived": true, "latestUserFrameAt": now }),
    );
    let mut s = Scanner::new(p);
    let found = s.scan(true);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].name, "Remote work");
    assert_eq!(found[0].location, Location::Ssh);
}
