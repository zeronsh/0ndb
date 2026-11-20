//! Provider sessions end to end: real git worktree, real mount, scripted
//! providers that write files inside tool calls.

use std::fs;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ondb::git::Forges;
use ondb::{MountOptions, Worktrees};
use ondb_agents::mock::{Mock, Step};
use ondb_agents::{Capabilities, Provider, Role, SessionOptions, Sessions, Status};

fn sh(dir: &Path, script: &str) {
    let ok = Command::new("sh").arg("-c").arg(script).current_dir(dir).status().unwrap().success();
    assert!(ok, "{script}");
}

/// `write <path> <content>` on the prompt's last line writes a file; the
/// reply echoes that line.
fn script(prompt: &str) -> Vec<Step> {
    let last = prompt.lines().last().unwrap_or("").to_string();
    let mut steps = Vec::new();
    let words: Vec<&str> = last.split_whitespace().collect();
    if words.first() == Some(&"write") && words.len() >= 3 {
        // `\n` in the prompt writes a line break, for multi-line files.
        steps.push(Step::Write { path: words[1].into(), content: format!("{}\n", words[2..].join(" ").replace("\\n", "\n")) });
    }
    if words.first() == Some(&"fail") {
        steps.push(Step::Fail("scripted failure".into()));
    }
    steps.push(Step::Text(format!("ok: {last}")));
    steps
}

struct Env {
    _dir: tempfile::TempDir,
    sessions: Sessions,
    worktrees: Worktrees,
    wt: ondb::WorktreeInfo,
    alpha: Mock,
    beta: Mock,
}

fn env(opts: SessionOptions) -> Env {
    let dir = tempfile::tempdir().unwrap();
    let d = dir.path();
    let git = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main";
    sh(d, &format!("{git} init -q app && cd app && echo base > base.txt && {git} add -A && {git} commit -qm init"));
    let worktrees = Worktrees::open(d.join("state"), d.join("checkouts"), MountOptions::default(), Forges::default()).unwrap();
    let wt = worktrees.create(d.join("app"), "agent work", Some("main")).unwrap();
    // alpha: resumable, forkable, persistent (like Claude Code); beta: resume only, one process per turn.
    let alpha = Mock::new("alpha", Capabilities { resume: true, fork_at_message: true, persistent: true }, script);
    let beta = Mock::new("beta", Capabilities { resume: true, fork_at_message: false, persistent: false }, script);
    let providers: Vec<Arc<dyn Provider>> = vec![Arc::new(alpha.clone()), Arc::new(beta.clone())];
    let sessions = Sessions::open(d.join("state/sessions.db"), worktrees.clone(), providers, opts).unwrap();
    Env { _dir: dir, sessions, worktrees, wt, alpha, beta }
}

fn text(ws: &ondb::Workspace, path: &str) -> Option<String> {
    ws.read(|h| h.lookup(path).and_then(|i| h.text(&i))).map(|b| String::from_utf8(b).unwrap())
}

#[test]
fn records_turns_switches_providers_and_edits_with_worktree_restore() {
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let t = s.create_thread(&e.wt.id, "demo").unwrap();
    let (ws, mount) = e.worktrees.workspace(&e.wt.id).unwrap();

    // Turn 1 (alpha): a tool call writes a file.
    let a1 = s.send(&t.id, "write a.txt from alpha", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(a1.status, Status::Done);
    assert_eq!(a1.text, "ok: write a.txt from alpha");
    assert_eq!(fs::read_to_string(e.wt.path.join("a.txt")).unwrap(), "from alpha\n");
    let tools = s.tool_calls(&a1.id).unwrap();
    assert_eq!(tools.len(), 1);
    assert_eq!(tools[0].name, "Write");
    assert_eq!(tools[0].output.as_deref(), Some("wrote a.txt"));
    // The tool call's scope holds exactly the batch that wrote a.txt.
    let scope = ondb::attrib::scopes(&ws).into_iter().find(|sc| Some(sc.id.to_string()) == tools[0].scope).unwrap();
    assert_eq!(scope.batches.len(), 1);
    let a_inode = ws.read(|h| h.lookup("a.txt")).unwrap();
    assert!(ws.summary(&scope.batches[0]).unwrap().touched.contains(&a_inode));
    // Every provider event is on record, verbatim.
    let events = s.events(&a1.id).unwrap();
    let kinds: Vec<&str> = events.iter().map(|ev| ev.kind.as_str()).collect();
    assert_eq!(kinds, ["session_started", "tool_started", "tool_finished", "text", "turn_ended"]);
    assert!(events.iter().all(|ev| ev.raw.as_ref().is_some_and(|r| serde_json::from_slice::<serde_json::Value>(r).is_ok())));
    assert_eq!(s.warm_processes(), 1, "alpha stays warm");

    // Turn 2 (alpha): reuses the warm process, no replayed history.
    let a2 = s.send(&t.id, "write b.txt second", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(e.alpha.spawned(), 1);
    assert!(!e.alpha.calls()[1].prompt.contains("<conversation>"));

    // Turn 3 (beta): switching provider replays the conversation into a fresh session.
    let b3 = s.send(&t.id, "write c.txt from beta", "beta", None).unwrap().wait().unwrap();
    let beta_prompt = &e.beta.calls()[0].prompt;
    assert!(
        beta_prompt.contains("taking over")
            && beta_prompt.contains("write a.txt from alpha")
            && beta_prompt.contains("ok: write b.txt")
    );
    assert_eq!(e.beta.live(), 0, "beta's process ends with its turn");
    assert_eq!(b3.switched_from.as_deref(), Some("alpha"), "the seam is recorded");
    assert_eq!(a2.switched_from, None);

    // Turn 4 (back to alpha): continues alpha's own session, catching up only on beta's turn.
    s.send(&t.id, "say hi", "alpha", None).unwrap().wait().unwrap();
    let back = e.alpha.calls().last().unwrap().clone();
    assert_eq!(back.native_session, e.alpha.calls()[0].native_session, "same native session");
    assert!(back.prompt.contains("While you were away") && back.prompt.contains("ok: write c.txt"));
    assert!(!back.prompt.contains("write a.txt from alpha"), "alpha already saw its own turns");

    // A person edits a file meanwhile.
    fs::write(e.wt.path.join("human.txt"), "mine\n").unwrap();
    mount.fence().unwrap();

    // Edit turn 2's prompt: a sibling branch whose files are exactly as they were when turn 2
    // was sent (the human's later edit included in what's undone); alpha forks its native
    // session at turn 1's last message.
    let u2 = s.message(&a2.parent.clone().unwrap()).unwrap();
    let edited = s.edit(&u2.id, "write d.txt instead", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(edited.status, Status::Done);
    let fork = e.alpha.calls().last().unwrap().clone();
    assert_eq!(fork.forked_at.as_deref(), a1.native.as_deref(), "native fork at the branch point");
    assert!(!fork.prompt.contains("<conversation>"), "the fork already has turn 1");
    for gone in ["b.txt", "c.txt"] {
        assert!(!e.wt.path.join(gone).exists(), "{gone} survived the restore");
    }
    assert_eq!(fs::read_to_string(e.wt.path.join("a.txt")).unwrap(), "from alpha\n", "turn 1 predates the edit");
    assert!(!e.wt.path.join("human.txt").exists(), "one fixed rule: everything since the message is undone");
    assert!(e.wt.path.join("d.txt").exists());
    let sibs = s.siblings(&u2.id).unwrap();
    assert_eq!(sibs.len(), 2, "<1/2>");
    let path: Vec<String> = s.path(&t.id).unwrap().iter().map(|m| m.text.clone()).collect();
    assert_eq!(path, ["write a.txt from alpha", "ok: write a.txt from alpha", "write d.txt instead", "ok: write d.txt instead"]);

    // Switch back to the original branch: its files come back exactly.
    let leaf = s.switch_branch(&u2.id).unwrap();
    assert_eq!(leaf.role, Role::Assistant);
    assert_eq!(leaf.text, "ok: say hi");
    for (f, want) in [("b.txt", "second\n"), ("c.txt", "from beta\n"), ("a.txt", "from alpha\n")] {
        assert_eq!(fs::read_to_string(e.wt.path.join(f)).unwrap(), want);
    }
    assert!(!e.wt.path.join("d.txt").exists());
    assert_eq!(text(&ws, "c.txt").as_deref(), Some("from beta\n"));
    // Native commands go out as-is, never wrapped in replayed history.
    s.send(&t.id, "/compact", "beta", None).unwrap().wait().unwrap();
    assert_eq!(e.beta.calls().last().unwrap().prompt, "/compact");
}

#[test]
fn branch_switches_remember_nested_choices_after_restart() {
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let t = s.create_thread(&e.wt.id, "nested branches").unwrap();
    let root = s.send(&t.id, "write root.txt original", "alpha", None).unwrap().wait().unwrap();
    let middle = s.send(&t.id, "write middle.txt original", "alpha", None).unwrap().wait().unwrap();
    let end = s.send(&t.id, "write end.txt original", "alpha", None).unwrap().wait().unwrap();
    let end_user = end.parent.as_deref().unwrap();
    let middle_user = middle.parent.as_deref().unwrap();
    let root_user = root.parent.as_deref().unwrap();

    // Choose an older reply, continue it, then leave at an earlier fork.
    let end_alt = s.edit(end_user, "write end.txt alternate", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(s.switch_branch(end_user).unwrap().id, end.id);
    let tail = s.send(&t.id, "write tail.txt chosen", "alpha", None).unwrap().wait().unwrap();
    let chosen_path: Vec<_> = s.path(&t.id).unwrap().iter().map(|m| m.id.clone()).collect();
    let middle_alt = s.edit(middle_user, "write middle.txt alternate", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(
        s.switch_branch(middle_user).unwrap().id,
        tail.id,
        "return to the selected older continuation, not the newest edit"
    );

    // The same choice survives leaving at the root and closing the sessions.
    let root_alt = s.edit(root_user, "write root.txt alternate", "alpha", None).unwrap().wait().unwrap();
    s.close_idle();
    let restarted = Sessions::open(
        e._dir.path().join("state/sessions.db"),
        e.worktrees.clone(),
        vec![Arc::new(e.alpha.clone())],
        SessionOptions::default(),
    )
    .unwrap();
    assert_eq!(restarted.switch_branch(root_user).unwrap().id, tail.id);
    assert_eq!(restarted.path(&t.id).unwrap().iter().map(|m| m.id.clone()).collect::<Vec<_>>(), chosen_path);
    for file in ["root.txt", "middle.txt", "end.txt"] {
        assert_eq!(fs::read_to_string(e.wt.path.join(file)).unwrap(), "original\n", "{file}");
    }
    assert_eq!(fs::read_to_string(e.wt.path.join("tail.txt")).unwrap(), "chosen\n");

    // Selecting a different nested alternative updates its ancestors too,
    // without forgetting the choices inside the sibling we just left.
    restarted.switch_branch(middle_alt.parent.as_deref().unwrap()).unwrap();
    restarted.switch_branch(root_alt.parent.as_deref().unwrap()).unwrap();
    assert_eq!(restarted.switch_branch(root_user).unwrap().id, middle_alt.id);
    assert_eq!(restarted.switch_branch(middle_user).unwrap().id, tail.id);
    restarted.switch_branch(end_alt.parent.as_deref().unwrap()).unwrap();
    restarted.switch_branch(root_alt.parent.as_deref().unwrap()).unwrap();
    assert_eq!(restarted.switch_branch(root_user).unwrap().id, end_alt.id);
    assert_eq!(fs::read_to_string(e.wt.path.join("end.txt")).unwrap(), "alternate\n");
    assert!(!e.wt.path.join("tail.txt").exists());
}

#[test]
fn upgrading_branch_choices_preserves_the_current_path() {
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let t = s.create_thread(&e.wt.id, "upgrade").unwrap();
    let root = s.send(&t.id, "write root.txt original", "alpha", None).unwrap().wait().unwrap();
    let end = s.send(&t.id, "write end.txt original", "alpha", None).unwrap().wait().unwrap();
    s.edit(end.parent.as_deref().unwrap(), "write end.txt alternate", "alpha", None).unwrap().wait().unwrap();
    let root_alt = s.edit(root.parent.as_deref().unwrap(), "write root.txt alternate", "alpha", None).unwrap().wait().unwrap();
    s.switch_branch(end.parent.as_deref().unwrap()).unwrap();
    let db = e._dir.path().join("state/sessions.db");
    s.close_idle();

    // Simulate a pre-upgrade database with an older continuation selected.
    // The new table must seed that path, not silently choose newer edits.
    rusqlite::Connection::open(&db).unwrap().execute_batch("DROP TABLE branch_choices").unwrap();
    let restarted = Sessions::open(&db, e.worktrees.clone(), vec![Arc::new(e.alpha.clone())], SessionOptions::default()).unwrap();
    restarted.switch_branch(root_alt.parent.as_deref().unwrap()).unwrap();
    assert_eq!(restarted.switch_branch(root.parent.as_deref().unwrap()).unwrap().id, end.id);
    assert_eq!(fs::read_to_string(e.wt.path.join("end.txt")).unwrap(), "original\n");
}

#[test]
fn reasoning_streams_separately_and_survives_reloads() {
    use ondb_agents::Update;
    let e = env(SessionOptions::default());
    let trace = "Check **the plan** and preserve café 🚀. ".repeat(4);
    let expected = trace.clone();
    let thinker = Mock::new("thinker", Capabilities::default(), move |_| {
        vec![
            Step::Think { text: trace.clone(), chunk: 5, delay: Duration::from_millis(5) },
            Step::Write { path: "checked.txt".into(), content: "checked".into() },
            Step::Think { text: "Verify the result.".into(), chunk: 4, delay: Duration::from_millis(5) },
            Step::Text("The answer.".into()),
        ]
    });
    let db = e._dir.path().join("state/sessions.db");
    let s = Sessions::open(&db, e.worktrees.clone(), vec![Arc::new(thinker.clone())], SessionOptions::default()).unwrap();
    let t = s.create_thread(&e.wt.id, "thinking").unwrap();
    let updates = s.subscribe();
    let turn = s.send(&t.id, "check", "thinker", None).unwrap();
    loop {
        if let Update::ReasoningDelta { message, text, .. } = updates.recv_timeout(Duration::from_secs(5)).unwrap() {
            assert_eq!(message, turn.assistant);
            assert!(!text.is_empty());
            let page = s.page(&t.id, None, 40).unwrap();
            assert_eq!(page.messages.last().unwrap().id, turn.assistant, "a page reload includes the running reply");
            let blocks = s.reasoning(&turn.assistant).unwrap();
            assert_eq!(blocks.len(), 1);
            assert!(expected.starts_with(&blocks[0].text));
            assert_eq!(blocks[0].ended_ms, None);
            break;
        }
    }
    let reply = turn.wait().unwrap();
    assert_eq!(reply.text, "The answer.", "reasoning never becomes answer text");
    let blocks = s.reasoning(&reply.id).unwrap();
    assert_eq!(blocks.len(), 2);
    assert_eq!(blocks[0].text, expected, "the full snapshot replaces streamed text instead of duplicating it");
    assert_eq!(blocks[1].text, "Verify the result.");
    assert!(blocks.iter().all(|b| b.ended_ms.is_some_and(|end| end >= b.started_ms)));
    let restarted = Sessions::open(&db, e.worktrees.clone(), vec![Arc::new(thinker)], SessionOptions::default()).unwrap();
    assert_eq!(restarted.reasoning(&reply.id).unwrap(), blocks);
}

#[test]
fn archived_reasoning_is_decoded_once_and_crashed_thinking_stops_at_last_chunk() {
    use ondb_agents::claude::{Access, ClaudeCode};
    let e = env(SessionOptions::default());
    let t = e.sessions.create_thread(&e.wt.id, "archive").unwrap();
    let mut old = e.sessions.send(&t.id, "hello", "alpha", None).unwrap().wait().unwrap();
    old.id = "archived-thinking".into();
    old.provider = Some("claude-code".into());
    let store = e.sessions.store();
    store.insert_message(&old).unwrap();
    let session = old.session.as_deref().unwrap();
    for (ts, kind, raw) in [
        (
            1000,
            "reasoning_delta",
            serde_json::json!({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Check **"}}}),
        ),
        (
            1200,
            "reasoning_delta",
            serde_json::json!({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"the plan**."}}}),
        ),
        (3000, "text_delta", serde_json::json!({})),
        (
            4000,
            "reasoning",
            serde_json::json!({"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Check **the plan**."},{"type":"text","text":"Answer"}]}}),
        ),
    ] {
        store.record_event(session, Some(&old.id), ts, kind, None, Some(&serde_json::to_vec(&raw).unwrap())).unwrap();
    }
    let db = e._dir.path().join("state/sessions.db");
    let s = Sessions::open(&db, e.worktrees.clone(), vec![Arc::new(ClaudeCode::new(Access::Full))], SessionOptions::default())
        .unwrap();
    let blocks = s.reasoning(&old.id).unwrap();
    assert_eq!(blocks.len(), 1);
    assert_eq!(blocks[0].text, "Check **the plan**.");
    assert_eq!(blocks[0].started_ms, 1000);
    assert_eq!(blocks[0].ended_ms, Some(3000), "late final snapshots don't inflate thinking time");
    assert_eq!(s.reasoning(&old.id).unwrap(), blocks, "the cached trace keeps its identity");

    // No provider is run here: simulate a crash with a partial persisted trace.
    old.id = "crashed-thinking".into();
    old.status = Status::Running;
    store.insert_message(&old).unwrap();
    let id = store.begin_reasoning(&old.id, 1000).unwrap();
    store.write_reasoning(id, "partial", false, 2000).unwrap();
    let restarted = Sessions::open(&db, e.worktrees.clone(), Vec::new(), SessionOptions::default()).unwrap();
    assert_eq!(restarted.reasoning(&old.id).unwrap()[0].ended_ms, Some(2000));
}

#[test]
fn failures_are_recorded_and_processes_are_bounded() {
    let e = env(SessionOptions { warm_limit: 1, warm_idle: Duration::from_millis(300), ..SessionOptions::default() });
    let s = &e.sessions;
    let t1 = s.create_thread(&e.wt.id, "one").unwrap();
    let t2 = s.create_thread(&e.wt.id, "two").unwrap();
    let failed = s.send(&t1.id, "fail please", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(failed.status, Status::Failed);
    assert_eq!(failed.error.as_deref(), Some("scripted failure"));
    assert_eq!(s.warm_processes(), 0, "failed turns don't park");

    s.send(&t1.id, "hello", "alpha", None).unwrap().wait().unwrap();
    s.send(&t2.id, "hello", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(s.warm_processes(), 1, "warm limit");
    assert_eq!(e.alpha.live(), 1);
    let deadline = Instant::now() + Duration::from_secs(5);
    while e.alpha.live() > 0 {
        assert!(Instant::now() < deadline, "idle process never reaped");
        std::thread::sleep(Duration::from_millis(20));
    }
    // A parked-then-reaped session resumes natively.
    s.send(&t1.id, "again", "alpha", None).unwrap().wait().unwrap();
    let last = e.alpha.calls().last().unwrap().clone();
    assert!(last.resumed.is_some());
    assert!(!last.prompt.contains("<conversation>"));
    // One turn per thread at a time.
    let running = s.send(&t2.id, "hello", "beta", None).unwrap();
    let _ = s.send(&t2.id, "again", "beta", None).map(|t| t.wait());
    running.wait().unwrap();
    // CLI output can be attached to a message.
    let m = s.path(&t2.id).unwrap().last().unwrap().clone();
    s.record_output(&m.id, None, "stdout", b"line 1\n").unwrap();
    s.record_output(&m.id, None, "stdout", b"line 2\n").unwrap();
    assert_eq!(s.store().output(&m.id, None, "stdout").unwrap(), b"line 1\nline 2\n");
}

/// `ONDB_LIVE_CLAUDE=1`: real Claude Code (Haiku): a tool call, a resumed
/// turn, then an edit that forks the native session at the branch point.
#[test]
fn live_claude_code() {
    if std::env::var("ONDB_LIVE_CLAUDE").is_err() {
        return;
    }
    use ondb_agents::claude::{Access, ClaudeCode};
    let dir = tempfile::tempdir().unwrap();
    let d = dir.path();
    sh(
        d,
        "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main init -q app && cd app && echo hello > a.txt && git add -A && git -c user.name=t -c user.email=t@t commit -qm init",
    );
    let worktrees = Worktrees::open(d.join("state"), d.join("checkouts"), MountOptions::default(), Forges::default()).unwrap();
    let wt = worktrees.create(d.join("app"), "live", Some("main")).unwrap();
    let claude: Arc<dyn Provider> = Arc::new(ClaudeCode::new(Access::Full));
    let s = Sessions::open(d.join("state/sessions.db"), worktrees.clone(), vec![claude], SessionOptions::default()).unwrap();
    let t = s.create_thread(&wt.id, "live").unwrap();
    let model = Some("haiku");
    let a1 = s
        .send(
            &t.id,
            "Create a file named note.txt containing exactly the word apple. Then reply with just: done",
            "claude-code",
            model,
        )
        .unwrap()
        .wait()
        .unwrap();
    if a1.status != Status::Done {
        for ev in s.events(&a1.id).unwrap() {
            println!(
                "EV {} {}",
                ev.kind,
                String::from_utf8_lossy(&ev.raw.unwrap_or_default()).chars().take(700).collect::<String>()
            );
        }
    }
    assert_eq!(a1.status, Status::Done, "{:?}", a1.error);
    assert_eq!(fs::read_to_string(wt.path.join("note.txt")).unwrap().trim(), "apple");
    let tools = s.tool_calls(&a1.id).unwrap();
    assert!(!tools.is_empty(), "the write was a recorded tool call");
    assert!(tools.iter().all(|tc| tc.scope.is_some() && tc.ended_ms.is_some()));
    assert!(a1.native.is_some());
    let a2 = s
        .send(&t.id, "What word did you write into note.txt? Reply with just the word.", "claude-code", model)
        .unwrap()
        .wait()
        .unwrap();
    assert!(a2.text.to_lowercase().contains("apple"), "resumed session remembers: {}", a2.text);
    assert_eq!(s.warm_processes(), 1);
    // Edit turn 2: forks claude's native session at turn 1's last message.
    let u2 = a2.parent.clone().unwrap();
    let a3 = s
        .edit(
            &u2,
            "Reply with just the number of messages you have received from me so far in this conversation.",
            "claude-code",
            model,
        )
        .unwrap()
        .wait()
        .unwrap();
    assert_eq!(a3.status, Status::Done, "{:?}", a3.error);
    let sessions = s.provider_sessions(&t.id).unwrap();
    assert_eq!(sessions.len(), 2);
    assert!(sessions[1].forked_from.is_some() && sessions[1].native != sessions[0].native, "native fork");
    assert!(a3.text.contains('2'), "the fork saw turn 1 but not the replaced turn 2: {}", a3.text);
    // The first turn's file predates the edited message, so it stays.
    assert!(wt.path.join("note.txt").exists());
    let raw = s.events(&a1.id).unwrap();
    assert!(raw.iter().any(|ev| ev.kind == "session_started") && raw.iter().any(|ev| ev.kind == "tool_finished"));
    println!("turn 1: {} events, {} tool calls; fork reply: {}", raw.len(), tools.len(), a3.text);
    s.close_idle();
}

#[test]
fn streams_pages_and_interrupts() {
    use ondb_agents::Update;
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let streamer = Mock::new("streamer", Capabilities { resume: true, fork_at_message: true, persistent: true }, |p| {
        vec![Step::Stream {
            text: format!("streamed reply to {}", p.lines().last().unwrap_or("")),
            chunk: 4,
            delay: Duration::from_millis(5),
        }]
    });
    let providers: Vec<Arc<dyn Provider>> = vec![Arc::new(streamer)];
    let s2 =
        Sessions::open(e._dir.path().join("state/s2.db"), e.worktrees.clone(), providers, SessionOptions::default()).unwrap();
    let _ = s;
    let t = s2.create_thread(&e.wt.id, "stream").unwrap();
    let updates = s2.subscribe();
    let m = s2.send(&t.id, "hello there", "streamer", None).unwrap().wait().unwrap();
    assert_eq!(m.text, "streamed reply to hello there");
    let deltas: String = updates
        .try_iter()
        .filter_map(|u| match u {
            Update::TextDelta { text, .. } => Some(text),
            _ => None,
        })
        .collect();
    assert_eq!(deltas, m.text, "deltas add up to the reply");
    assert_eq!(s2.live_text(&m.id), None, "live text is dropped once the turn ends");
    // Event pages.
    let first = s2.events_page(&m.id, 0, 3).unwrap();
    assert_eq!(first.len(), 3);
    let rest = s2.events_page(&m.id, first.last().unwrap().seq, 1000).unwrap();
    assert_eq!(first.len() + rest.len(), s2.events(&m.id).unwrap().len());

    for i in 0..3 {
        s2.send(&t.id, &format!("message {i}"), "streamer", None).unwrap().wait().unwrap();
    }
    // 8 messages; page backwards 3 at a time.
    let p1 = s2.page(&t.id, None, 3).unwrap();
    assert!(p1.has_more);
    assert_eq!(p1.messages.last().unwrap().text, "streamed reply to message 2");
    let p2 = s2.page(&t.id, Some(&p1.messages[0].id), 3).unwrap();
    let p3 = s2.page(&t.id, Some(&p2.messages[0].id), 3).unwrap();
    assert!(!p3.has_more);
    assert_eq!(p3.messages.len(), 2);
    assert_eq!(p3.messages[0].text, "hello there");

    // Interrupting a long stream.
    let slow = s2.send(&t.id, &"x".repeat(400), "streamer", None).unwrap();
    std::thread::sleep(Duration::from_millis(30));
    assert!(s2.live_text(&slow.assistant).is_some_and(|t| !t.is_empty()), "partial text is readable mid-turn");
    assert!(s2.interrupt(&t.id));
    assert_eq!(slow.wait().unwrap().status, Status::Interrupted);
    assert!(!s2.interrupt(&t.id));
}

/// A provider refusing a native fork (its fork point is unknown) falls back
/// to a fresh session with the branch's history replayed.
#[test]
fn rejected_forks_fall_back_to_replay() {
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let t = s.create_thread(&e.wt.id, "fork").unwrap();
    s.send(&t.id, "first", "alpha", None).unwrap().wait().unwrap();
    let a2 = s.send(&t.id, "second", "alpha", None).unwrap().wait().unwrap();
    e.alpha.reject_forks(true);
    let edited = s.edit(a2.parent.as_ref().unwrap(), "second, edited", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(edited.status, Status::Done, "{:?}", edited.error);
    let calls = e.alpha.calls();
    let fallback = calls.last().unwrap();
    assert!(fallback.forked_at.is_none() && fallback.resumed.is_none(), "fresh session");
    assert!(
        fallback.prompt.contains(r#""text":"first""#) && !fallback.prompt.contains(r#""text":"second""#),
        "replays the branch only"
    );
    assert!(calls[calls.len() - 2].forked_at.is_some(), "the fork was tried first");
}

/// `ONDB_LIVE_SWITCH=1`: Claude Code -> Codex -> Claude Code in one thread.
#[test]
fn live_provider_switch() {
    if std::env::var("ONDB_LIVE_SWITCH").is_err() {
        return;
    }
    use ondb_agents::claude::{Access, ClaudeCode};
    use ondb_agents::codex::Codex;
    let dir = tempfile::tempdir().unwrap();
    let d = dir.path();
    sh(
        d,
        "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main init -q app && cd app && echo hi > a.txt && git add -A && git -c user.name=t -c user.email=t@t commit -qm init",
    );
    let worktrees = Worktrees::open(d.join("state"), d.join("checkouts"), MountOptions::default(), Forges::default()).unwrap();
    let wt = worktrees.create(d.join("app"), "switch", Some("main")).unwrap();
    let providers: Vec<Arc<dyn Provider>> = vec![Arc::new(ClaudeCode::new(Access::Full)), Arc::new(Codex::new(Access::Full))];
    let s = Sessions::open(d.join("state/sessions.db"), worktrees.clone(), providers, SessionOptions::default()).unwrap();
    let t = s.create_thread(&wt.id, "switch").unwrap();
    let c1 = s
        .send(&t.id, "Remember the code word: PELICAN. Reply with just: ok", "claude-code", Some("haiku"))
        .unwrap()
        .wait()
        .unwrap();
    assert_eq!(c1.status, Status::Done, "{:?}", c1.error);
    let x1 = s
        .send(
            &t.id,
            "Create a file named codex.txt containing the code word I told you, then reply with just the code word.",
            "codex",
            None,
        )
        .unwrap()
        .wait()
        .unwrap();
    assert_eq!(x1.status, Status::Done, "{:?}", x1.error);
    assert_eq!(x1.switched_from.as_deref(), Some("claude-code"));
    assert!(x1.text.to_uppercase().contains("PELICAN"), "codex got the history: {}", x1.text);
    assert_eq!(fs::read_to_string(wt.path.join("codex.txt")).unwrap().trim().to_uppercase(), "PELICAN");
    assert!(!s.tool_calls(&x1.id).unwrap().is_empty(), "codex's tool calls are recorded");
    let c2 = s
        .send(
            &t.id,
            "What file did the other assistant create while you were away? Reply with just the file name.",
            "claude-code",
            Some("haiku"),
        )
        .unwrap()
        .wait()
        .unwrap();
    assert_eq!(c2.status, Status::Done, "{:?}", c2.error);
    assert!(c2.text.contains("codex.txt"), "claude caught up: {}", c2.text);
    let sessions = s.provider_sessions(&t.id).unwrap();
    assert_eq!(sessions.len(), 2, "claude resumed its own session: {sessions:?}");
    println!("codex: {} | claude after switching back: {}", x1.text.trim(), c2.text.trim());
    s.close_idle();
}

#[test]
fn turns_cut_short_by_a_crash_resume_at_startup() {
    let e = env(SessionOptions::default());
    let t = e.sessions.create_thread(&e.wt.id, "crash").unwrap();
    let first = e.sessions.send(&t.id, "write a.txt one", "alpha", None).unwrap().wait().unwrap();
    // The process dies mid-turn: the next prompt and a running reply are on
    // disk, nothing else.
    let store = e.sessions.store();
    let msg = |id: &str, parent: &str, role: Role, text: &str, status: Status| ondb_agents::Message {
        id: id.into(),
        thread: t.id.clone(),
        parent: Some(parent.into()),
        role,
        provider: (role == Role::Assistant).then(|| "alpha".to_string()),
        model: None,
        text: text.into(),
        version: None,
        scope: None,
        session: first.session.clone(),
        native: None,
        status,
        error: None,
        created_ms: ondb_core::now_ms(),
        switched_from: None,
        git_branch: None,
        git_commit: None,
        worktree: Some(e.wt.id.clone()),
    };
    store.insert_message(&msg("u2", &first.id, Role::User, "write b.txt two", Status::Done)).unwrap();
    store.insert_message(&msg("a2", "u2", Role::Assistant, "partial", Status::Running)).unwrap();
    store.set_leaf(&t.id, "a2").unwrap();
    // A reply already revived three times in a row is left alone.
    store.insert_message(&msg("u9", &first.id, Role::User, "write c.txt three", Status::Done)).unwrap();
    let mut parent = "u9".to_string();
    for i in 0..4 {
        let status = if i == 3 { Status::Running } else { Status::Interrupted };
        store.insert_message(&msg(&format!("r{i}"), &parent, Role::Assistant, "partial", status)).unwrap();
        parent = format!("r{i}");
    }

    let providers: Vec<Arc<dyn Provider>> = vec![Arc::new(e.alpha.clone())];
    let db = e._dir.path().join("state/sessions.db");
    let restarted = Sessions::open(&db, e.worktrees.clone(), providers, SessionOptions::default()).unwrap();
    let resumed = restarted.resume_interrupted();
    assert_eq!(resumed.len(), 1, "only the fresh crash within its revival budget");
    let reply = resumed.into_iter().next().unwrap().wait().unwrap();
    assert_eq!(reply.status, Status::Done);
    assert_eq!(reply.parent.as_deref(), Some("a2"), "the transcript continues from the interrupted reply");
    assert_eq!(reply.text, "ok: write b.txt two");
    let interrupted = restarted.store().message("a2").unwrap().unwrap();
    assert_eq!(interrupted.status, Status::Interrupted);
    assert!(interrupted.error.unwrap().contains("resumed"));
    assert_eq!(restarted.store().message("r3").unwrap().unwrap().status, Status::Interrupted);
    let (ws, _) = e.worktrees.workspace(&e.wt.id).unwrap();
    assert_eq!(text(&ws, "b.txt").as_deref(), Some("two\n"));
    assert!(restarted.resume_interrupted().is_empty(), "resumes once per startup");
}

#[test]
fn restoring_a_message_returns_git_to_where_it_was() {
    use ondb_agents::Update;
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let wt = e.wt.path.clone();
    let git = "git -c user.name=t -c user.email=t@t";
    let out = |cmd: &str| -> String {
        String::from_utf8(Command::new("sh").arg("-c").arg(cmd).current_dir(&wt).output().unwrap().stdout)
            .unwrap()
            .trim()
            .to_string()
    };
    let (ws, mount) = e.worktrees.workspace(&e.wt.id).unwrap();
    let start_branch = out("git symbolic-ref --short HEAD");
    let start_commit = out("git rev-parse HEAD");
    let t = s.create_thread(&e.wt.id, "git moves").unwrap();
    let first = s.send(&t.id, "write a.txt one", "alpha", None).unwrap().wait().unwrap();
    let u1 = first.parent.clone().unwrap();

    // Mid-conversation, someone switches to a new branch and commits there.
    sh(&wt, &format!("{git} switch -qc feature && echo feat > feat.txt && {git} add feat.txt && {git} commit -qm feat"));
    mount.fence().unwrap();
    let feature_commit = out("git rev-parse HEAD");
    let second = s.send(&t.id, "write b.txt two", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(s.store().message(second.parent.as_ref().unwrap()).unwrap().unwrap().git_branch.as_deref(), Some("feature"));

    // Editing the first message goes back to the first branch and its files.
    let updates = s.subscribe();
    let edited = s.edit(&u1, "write c.txt three", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(out("git symbolic-ref --short HEAD"), start_branch);
    assert_eq!(out("git rev-parse HEAD"), start_commit);
    assert!(!wt.join("feat.txt").exists() && !wt.join("a.txt").exists() && !wt.join("b.txt").exists());
    assert_eq!(fs::read_to_string(wt.join("c.txt")).unwrap(), "three\n");
    assert!(updates.try_iter().any(|u| matches!(u, Update::GitMoved { created: false, .. })));
    assert_eq!(out("git status --porcelain"), "?? c.txt", "git agrees with the files: only the new reply's work is uncommitted");

    // Switching back to the other conversation branch returns to `feature`.
    s.switch_branch(&second.id).unwrap();
    assert_eq!(out("git symbolic-ref --short HEAD"), "feature");
    assert_eq!(out("git rev-parse HEAD"), feature_commit);
    for (f, body) in [("feat.txt", "feat\n"), ("a.txt", "one\n"), ("b.txt", "two\n")] {
        assert_eq!(fs::read_to_string(wt.join(f)).unwrap(), body);
    }
    assert!(!wt.join("c.txt").exists());

    // `feature` moves on; going back to that message must not move it, so a
    // new branch is made at the commit the message was on.
    s.switch_branch(&edited.id).unwrap();
    assert_eq!(out("git symbolic-ref --short HEAD"), start_branch);
    sh(
        &wt,
        &format!(
            "{git} switch -q feature && echo more > more.txt && {git} add more.txt && {git} commit -qm more && {git} switch -q {start_branch}"
        ),
    );
    mount.fence().unwrap();
    let feature_tip = out("git rev-parse feature");
    s.switch_branch(&second.id).unwrap();
    let now = out("git symbolic-ref --short HEAD");
    assert!(now.starts_with("ondb/"), "on a new branch, not {now}");
    assert_eq!(out("git rev-parse HEAD"), feature_commit);
    assert_eq!(out("git rev-parse feature"), feature_tip, "existing branches are never moved");
    assert_eq!(fs::read_to_string(wt.join("b.txt")).unwrap(), "two\n");
    assert!(!wt.join("more.txt").exists());
    let _ = ws;
}

#[test]
fn going_back_in_a_shared_worktree_forks_instead_of_rewinding_other_chats() {
    use ondb_agents::Update;
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let shared = e.wt.path.clone();
    let out = |dir: &Path, cmd: &str| -> String {
        String::from_utf8(Command::new("sh").arg("-c").arg(cmd).current_dir(dir).output().unwrap().stdout)
            .unwrap()
            .trim()
            .to_string()
    };
    let (_, mount) = e.worktrees.workspace(&e.wt.id).unwrap();
    // Uncommitted work already in the checkout when the chats start.
    fs::write(shared.join("base.txt"), "edited base\n").unwrap();
    fs::write(shared.join("notes.txt"), "untracked\n").unwrap();
    mount.fence().unwrap();
    let a = s.create_thread(&e.wt.id, "chat a").unwrap();
    let b = s.create_thread(&e.wt.id, "chat b").unwrap();

    // Alone in the worktree, going back rewinds it in place, as before.
    let a1 = s.send(&a.id, "write a.txt one", "alpha", None).unwrap().wait().unwrap();
    let a1u = a1.parent.clone().unwrap();
    s.edit(&a1u, "write a.txt redo", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(s.thread(&a.id).unwrap().worktree, e.wt.id);
    assert_eq!(fs::read_to_string(shared.join("a.txt")).unwrap(), "redo\n");

    // Chat b works in the same checkout.
    s.send(&b.id, "write b.txt from b", "beta", None).unwrap().wait().unwrap();

    // Chat a goes back to before its first message: rewinding would undo
    // b's work, so a forks into its own worktree instead.
    let updates = s.subscribe();
    let edited = s.edit(&a1u, "write c.txt three", "alpha", None).unwrap().wait().unwrap();
    let moved = updates.try_iter().find_map(|u| match u {
        Update::ThreadMoved { thread, to, forked, branch, .. } if thread == a.id => Some((to, forked, branch)),
        _ => None,
    });
    let (fork_id, forked, branch) = moved.expect("a moved");
    assert!(forked);
    assert_eq!(s.thread(&a.id).unwrap().worktree, fork_id);
    assert_eq!(edited.worktree.as_deref(), Some(fork_id.as_str()));
    let fork = e.worktrees.get(&fork_id).unwrap();
    assert_ne!(fork.path, shared);
    // The shared checkout is exactly as b left it.
    assert_eq!(fs::read_to_string(shared.join("a.txt")).unwrap(), "redo\n");
    assert_eq!(fs::read_to_string(shared.join("b.txt")).unwrap(), "from b\n");
    assert!(!shared.join("c.txt").exists());
    // The fork has the files as they were at the message, uncommitted and
    // untracked ones included, then the new reply's work.
    assert_eq!(fs::read_to_string(fork.path.join("base.txt")).unwrap(), "edited base\n");
    assert_eq!(fs::read_to_string(fork.path.join("notes.txt")).unwrap(), "untracked\n");
    assert_eq!(fs::read_to_string(fork.path.join("c.txt")).unwrap(), "three\n");
    assert!(!fork.path.join("a.txt").exists() && !fork.path.join("b.txt").exists());
    // Its branch can't be the one checked out in the shared worktree, so a
    // new one is made at the same commit.
    let branch = branch.expect("forks of a branch are on a branch");
    assert!(branch.starts_with("ondb/chat-a"), "{branch}");
    assert_eq!(out(&fork.path, "git symbolic-ref --short HEAD"), branch);
    assert_eq!(out(&fork.path, "git rev-parse HEAD"), out(&shared, "git rev-parse HEAD"));

    // b carries on in the shared checkout undisturbed.
    s.send(&b.id, "write b2.txt more", "beta", None).unwrap().wait().unwrap();
    assert!(shared.join("b2.txt").exists() && !fork.path.join("b2.txt").exists());

    // Switching a back to its original branch: b has worked there since, so
    // that point gets a fork too, with a's reply as it was.
    let old_reply = s.siblings(&edited.parent.clone().unwrap()).unwrap()[1].clone();
    let old_leaf = s.switch_branch(&old_reply.id).unwrap();
    let back = s.thread(&a.id).unwrap().worktree;
    assert!(back != e.wt.id && back != fork_id);
    let back_path = e.worktrees.get(&back).unwrap().path;
    assert_eq!(fs::read_to_string(back_path.join("a.txt")).unwrap(), "redo\n");
    assert!(!back_path.join("b.txt").exists() && !back_path.join("c.txt").exists());

    // Back to the edited branch: only a is in its fork, so a returns to it
    // (rewinding it in place, nothing to undo).
    s.switch_branch(&edited.id).unwrap();
    assert_eq!(s.thread(&a.id).unwrap().worktree, fork_id);
    // And again to the old branch: its fork is unchanged, so it is reused.
    let count = e.worktrees.list().len();
    s.switch_branch(&old_leaf.id).unwrap();
    assert_eq!(s.thread(&a.id).unwrap().worktree, back);
    assert_eq!(e.worktrees.list().len(), count, "no new fork for the same point");
}

#[test]
fn plain_folders_fork_by_cloning_and_land_with_line_merges_and_conflicts() {
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let dir = e._dir.path().join("notes");
    fs::create_dir_all(dir.join("node_modules/pkg")).unwrap();
    fs::write(dir.join("notes.md"), "intro\nalpha\nbeta\ngap\ngamma\n").unwrap();
    fs::write(dir.join("node_modules/pkg/index.js"), "dep\n").unwrap();
    let w = e.worktrees.adopt(&dir, "notes").unwrap();
    let (ws, mount) = e.worktrees.workspace(&w.id).unwrap();
    mount.fence().unwrap();
    assert!(text(&ws, "node_modules/pkg/index.js").is_none(), "dependency folders aren't tracked in plain folders");
    let read = |p: &Path| fs::read_to_string(p).unwrap();

    let a = s.create_thread(&w.id, "chat a").unwrap();
    let b = s.create_thread(&w.id, "chat b").unwrap();
    let a1 = s.send(&a.id, "write notes.md intro\\nalpha-A\\nbeta\\ngap\\ngamma", "alpha", None).unwrap().wait().unwrap();
    s.send(&b.id, "write other.txt from b", "beta", None).unwrap().wait().unwrap();

    // a goes back before its first turn: b has worked here since, and this
    // isn't git, so a gets a clone at that point.
    let edited =
        s.edit(a1.parent.as_ref().unwrap(), "write notes.md intro\\nalpha\\nbeta\\ngap\\ngamma-A", "alpha", None).unwrap();
    edited.wait().unwrap();
    let fork = e.worktrees.get(&s.thread(&a.id).unwrap().worktree).unwrap();
    assert_ne!(fork.path, dir);
    let origin = fork.forked_from.clone().unwrap();
    assert!(origin.shared, "the fork replicates the folder's history");
    assert_eq!(read(&fork.path.join("notes.md")), "intro\nalpha\nbeta\ngap\ngamma-A\n");
    assert!(!fork.path.join("other.txt").exists());
    assert_eq!(read(&fork.path.join("node_modules/pkg/index.js")), "dep\n", "the clone keeps ignored files");
    assert_eq!(read(&dir.join("notes.md")), "intro\nalpha-A\nbeta\ngap\ngamma\n", "the shared folder is untouched");

    // Meanwhile b edits another line in the shared folder.
    s.send(&b.id, "write notes.md intro\\nalpha-A\\nbeta-B\\ngap\\ngamma", "beta", None).unwrap().wait().unwrap();

    // Landing merges line by line: everyone's edits survive, in both places.
    let landed = s.land(&a.id).unwrap();
    assert!(landed.landed > 0 && landed.sync.conflicts.is_empty(), "{landed:?}");
    assert_eq!(landed.sync.merged, ["notes.md"]);
    let merged = "intro\nalpha-A\nbeta-B\ngap\ngamma-A\n";
    assert_eq!(read(&dir.join("notes.md")), merged);
    assert_eq!(read(&fork.path.join("notes.md")), merged);
    assert!(fork.path.join("other.txt").exists());

    // Both change the same line: landing stops, the conflict is marked in
    // the fork only, and the shared folder keeps its version.
    fs::write(dir.join("notes.md"), "intro\nalpha-A\nbeta-B\ngap\ngamma-W\n").unwrap();
    mount.fence().unwrap();
    s.send(&a.id, "write notes.md intro\\nalpha-A\\nbeta-B\\ngap\\ngamma-A2", "alpha", None).unwrap().wait().unwrap();
    let err = s.land(&a.id).unwrap_err().to_string();
    assert!(err.contains("conflicts") && err.contains("notes.md"), "{err}");
    let conflicts = s.conflicts(&a.id).unwrap();
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0].kind, ondb::ConflictKind::Text);
    let marked = read(&fork.path.join("notes.md"));
    assert!(marked.contains("<<<<<<<") && marked.contains("gamma-A2") && marked.contains("gamma-W"), "{marked}");
    assert_eq!(read(&dir.join("notes.md")), "intro\nalpha-A\nbeta-B\ngap\ngamma-W\n");

    // Resolving (here: keep both lines) lets it land.
    s.resolve(&a.id, "notes.md", ondb::Resolution::Content(Some(b"intro\nalpha-A\nbeta-B\ngap\ngamma-W\ngamma-A2\n".to_vec())))
        .unwrap();
    assert!(s.conflicts(&a.id).unwrap().is_empty());
    s.land(&a.id).unwrap();
    assert_eq!(read(&dir.join("notes.md")), "intro\nalpha-A\nbeta-B\ngap\ngamma-W\ngamma-A2\n");
    assert_eq!(read(&fork.path.join("notes.md")), read(&dir.join("notes.md")));
}

#[test]
fn editing_away_conflict_markers_resolves_them_and_git_forks_land_too() {
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let shared = e.wt.path.clone();
    let (_, mount) = e.worktrees.workspace(&e.wt.id).unwrap();
    fs::write(shared.join("doc.txt"), "one\ntwo\n").unwrap();
    mount.fence().unwrap();
    let a = s.create_thread(&e.wt.id, "chat a").unwrap();
    let b = s.create_thread(&e.wt.id, "chat b").unwrap();
    let a1 = s.send(&a.id, "write a.txt first", "alpha", None).unwrap().wait().unwrap();
    s.send(&b.id, "write doc.txt one\\ntwo-B", "beta", None).unwrap().wait().unwrap();
    s.edit(a1.parent.as_ref().unwrap(), "write doc.txt one\\ntwo-A", "alpha", None).unwrap().wait().unwrap();
    let fork = e.worktrees.get(&s.thread(&a.id).unwrap().worktree).unwrap();
    assert!(fork.forked_from.as_ref().unwrap().shared);
    assert!(fork.branch.as_deref().is_some_and(|b| b.starts_with("ondb/")));

    // Syncing marks the clash; editing the markers away (by hand, or by the
    // agent) is enough to resolve it.
    let report = s.sync(&a.id).unwrap();
    assert_eq!(report.conflicts.len(), 1);
    assert!(fs::read_to_string(fork.path.join("doc.txt")).unwrap().contains("<<<<<<<"));
    s.send(&a.id, "write doc.txt one\\ntwo-A\\ntwo-B", "alpha", None).unwrap().wait().unwrap();
    assert!(s.conflicts(&a.id).unwrap().is_empty());
    s.land(&a.id).unwrap();
    for p in [&shared, &fork.path] {
        assert_eq!(fs::read_to_string(p.join("doc.txt")).unwrap(), "one\ntwo-A\ntwo-B\n");
        assert_eq!(fs::read_to_string(p.join("a.txt")).unwrap(), "first\n", "a's earlier turn stays");
    }
}

#[test]
fn chats_without_a_folder_get_a_tracked_scratch_folder() {
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let t = s.create_chat("just chatting").unwrap();
    let wt = e.worktrees.get(&t.worktree).unwrap();
    assert!(wt.path.is_dir() && fs::read_dir(&wt.path).unwrap().flatten().all(|e| e.file_name() == ".0ndb"));
    s.send(&t.id, "write draft.md hello", "alpha", None).unwrap().wait().unwrap();
    assert_eq!(fs::read_to_string(wt.path.join("draft.md")).unwrap(), "hello\n");
    let (ws, _) = e.worktrees.workspace(&wt.id).unwrap();
    assert_eq!(text(&ws, "draft.md").as_deref(), Some("hello\n"), "tracked like any folder");
    // Going back undoes it, as anywhere else.
    let u = s.path(&t.id).unwrap()[0].clone();
    s.edit(&u.id, "say nothing", "alpha", None).unwrap().wait().unwrap();
    assert!(!wt.path.join("draft.md").exists());
}

#[test]
fn the_timeline_lists_changes_by_turn_and_tool_call_with_diffs() {
    let e = env(SessionOptions::default());
    let s = &e.sessions;
    let t = s.create_thread(&e.wt.id, "history").unwrap();
    s.send(&t.id, "write notes.md one\\ntwo", "alpha", None).unwrap().wait().unwrap();
    s.send(&t.id, "write notes.md one\\nTWO\\nthree", "alpha", None).unwrap().wait().unwrap();
    let (ws, _) = e.worktrees.workspace(&e.wt.id).unwrap();
    let page = ondb::timeline::entries(&ws, None, 50).unwrap();
    let edits: Vec<_> = page.entries.iter().filter(|en| en.files.iter().any(|f| f.path == "notes.md")).collect();
    assert_eq!(edits.len(), 2, "{:#?}", page.entries);
    let newest = edits[0];
    assert_eq!(newest.actor, "alpha");
    assert_eq!(newest.turn.as_ref().unwrap().label, "write notes.md one\\nTWO\\nthree");
    assert_eq!(newest.scope.as_ref().unwrap().kind, ondb::ScopeKind::ToolCall);
    let f = &newest.files[0];
    assert_eq!((f.status, f.added, f.removed), (ondb::timeline::FileStatus::Modified, 2, 1));
    let id = ondb::timeline::parse_batch_id(&newest.id).unwrap();
    let diff = ondb::timeline::diff(&ws, &[id]).unwrap();
    let patch = diff[0].patch.as_deref().unwrap();
    assert!(patch.contains("-two") && patch.contains("+TWO") && patch.contains("+three"), "{patch}");
    // Paging continues after the last entry shown.
    let older = ondb::timeline::entries(&ws, Some(&newest.id), 50).unwrap();
    assert!(older.entries.iter().all(|en| en.id != newest.id) && older.entries.iter().any(|en| en.id == edits[1].id));
}
