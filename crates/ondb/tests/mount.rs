//! End-to-end tests against real directories and real processes.

use std::fs;
use std::path::Path;
use std::process::Command;

use ondb::report::{FileChange, foreign_changes};
use ondb::{ActorKind, Mount, MountOptions, Recorder, ScopeKind, Workspace};
use ondb_core::{InodeId, Version};

fn text(ws: &Workspace, path: &str) -> Option<String> {
    ws.read(|h| h.lookup(path).and_then(|i| h.text(&i))).map(|b| String::from_utf8(b).unwrap())
}

fn inode(ws: &Workspace, path: &str) -> Option<InodeId> {
    ws.read(|h| h.lookup(path))
}

fn sh(dir: &Path, script: &str) {
    let status = Command::new("sh").arg("-c").arg(script).current_dir(dir).status().unwrap();
    assert!(status.success(), "{script}");
}

fn setup() -> (tempfile::TempDir, Workspace) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("wt");
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(root.join("src/main.rs"), "fn main() {\n    println!(\"hi\");\n}\n").unwrap();
    fs::write(root.join("README.md"), "# demo\n").unwrap();
    fs::write(root.join(".gitignore"), "target/\n").unwrap();
    fs::create_dir_all(root.join("target")).unwrap();
    fs::write(root.join("target/junk"), "ignored").unwrap();
    let ws = Workspace::open(dir.path().join("0ndb.db"), None).unwrap();
    (dir, ws)
}

#[test]
fn ingests_any_process_and_attributes_commands() {
    let (dir, ws) = setup();
    let root = dir.path().join("wt");
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    assert_eq!(text(&ws, "README.md").as_deref(), Some("# demo\n"));
    assert!(inode(&ws, "target/junk").is_none(), "gitignored paths stay out");

    let agent = ws.actor("codex", ActorKind::Agent).unwrap();
    let recorder = Recorder::new(&ws, vec![mount.handle()]).unwrap();

    // A script rewrites a file outside any edit tool: it's still tracked, and
    // the command scope it ran in gets the credit.
    let (_, record) = recorder
        .scoped(ScopeKind::Command, "python rewrite", Some(agent), None, |_| {
            sh(&root, "python3 -c \"import re,io;p='src/main.rs';s=open(p).read();open(p,'w').write(s.replace('hi','hello'))\"");
        })
        .unwrap();
    assert!(record.settled);
    assert_eq!(record.batches.len(), 1);
    assert_eq!(text(&ws, "src/main.rs").as_deref(), Some("fn main() {\n    println!(\"hello\");\n}\n"));
    let summary = ws.summary(&record.batches[0]).unwrap();
    assert_eq!(summary.actor, mount.ingestion_actor());

    // The user editing outside a scope is reported to the agent as foreign;
    // the agent's own command is not.
    fs::write(root.join("README.md"), "# demo\n\nmore\n").unwrap();
    mount.fence().unwrap();
    let report = foreign_changes(&ws, &record.start_version, agent).unwrap();
    assert_eq!(report.changes.len(), 1, "{report:?}");
    assert!(matches!(&report.changes[0], FileChange::Edited { path, .. } if path == "README.md"));
    let rendered = report.render("wt");
    assert!(rendered.contains("+more"), "{rendered}");

    // Blame names the command scope for the line the script rewrote.
    let lines = ondb::blame::blame(&ws, "src/main.rs").unwrap();
    assert_eq!(lines[1].scope.as_ref().map(|s| s.label.as_str()), Some("python rewrite"));
    assert_eq!(lines[0].scope, None);

    // Selective revert of the command keeps the later README edit.
    let (_, _) = recorder.revert(&record.id, agent, false).unwrap();
    mount.fence().unwrap();
    assert_eq!(fs::read_to_string(root.join("src/main.rs")).unwrap(), "fn main() {\n    println!(\"hi\");\n}\n");
    assert_eq!(fs::read_to_string(root.join("README.md")).unwrap(), "# demo\n\nmore\n");
}

#[test]
fn tool_writes_are_authored_by_the_agent_without_reingestion() {
    let (dir, ws) = setup();
    let root = dir.path().join("wt");
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    let agent = ws.actor("claude", ActorKind::Agent).unwrap();
    let before = ws.read(|h| h.dag().len());
    let batch = mount.write_file(agent, "src/lib.rs", b"pub fn x() {}\n".to_vec()).unwrap().unwrap();
    assert_eq!(fs::read_to_string(root.join("src/lib.rs")).unwrap(), "pub fn x() {}\n");
    mount.fence().unwrap();
    assert_eq!(ws.read(|h| h.dag().len()), before + 1, "the watcher must not re-ingest a tool write");
    assert_eq!(ws.summary(&batch).unwrap().actor, agent);
    mount.write_file(agent, "deep/new/dir/file.txt", b"x\n".to_vec()).unwrap();
    assert!(root.join("deep/new/dir/file.txt").exists());
    mount.rename(agent, "deep/new/dir/file.txt", "deep/moved.txt").unwrap();
    assert!(root.join("deep/moved.txt").exists() && !root.join("deep/new/dir/file.txt").exists());
    mount.remove(agent, "deep").unwrap();
    assert!(!root.join("deep").exists());
}

#[test]
fn renames_keep_identity() {
    let (dir, ws) = setup();
    let root = dir.path().join("wt");
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    let file = inode(&ws, "README.md").unwrap();
    let src = inode(&ws, "src").unwrap();
    sh(&root, "mv README.md DOCS.md && mv src source");
    mount.fence().unwrap();
    assert_eq!(inode(&ws, "DOCS.md"), Some(file));
    assert_eq!(inode(&ws, "source"), Some(src));
    assert_eq!(text(&ws, "source/main.rs").as_deref(), Some("fn main() {\n    println!(\"hi\");\n}\n"));
    assert!(inode(&ws, "README.md").is_none());
}

#[test]
fn offline_edits_are_ingested_on_restart() {
    let (dir, ws) = setup();
    let root = dir.path().join("wt");
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    let synced = ws.heads();
    mount.stop();
    fs::write(root.join("README.md"), "# changed while closed\n").unwrap();
    fs::remove_file(root.join("src/main.rs")).unwrap();
    drop(ws);
    let ws = Workspace::open(dir.path().join("0ndb.db"), None).unwrap();
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    assert_eq!(text(&ws, "README.md").as_deref(), Some("# changed while closed\n"));
    assert!(inode(&ws, "src/main.rs").is_none());
    let heads = ws.heads();
    let batch = *heads.heads().next().unwrap();
    let header = ws.read(|h| h.dag().header(&batch).cloned()).unwrap();
    assert_eq!(header.parents, synced, "offline edits are parented on what the disk reflected");
    drop(mount);
}

#[test]
fn crlf_and_binary_roundtrip() {
    let (dir, ws) = setup();
    let root = dir.path().join("wt");
    fs::write(root.join("win.txt"), "a\r\nb\r\n").unwrap();
    fs::write(root.join("blob.bin"), [0u8, 1, 2, 255]).unwrap();
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    assert_eq!(text(&ws, "win.txt").as_deref(), Some("a\nb\n"), "stored normalized");
    let agent = ws.actor("a", ActorKind::Agent).unwrap();
    mount.write_file(agent, "win.txt", b"a\r\nb\r\nc\r\n".to_vec()).unwrap();
    assert_eq!(fs::read(root.join("win.txt")).unwrap(), b"a\r\nb\r\nc\r\n");
    fs::write(root.join("blob.bin"), [9u8, 0, 9]).unwrap();
    mount.fence().unwrap();
    let ws2 = Workspace::in_memory(Some(ws.id())).unwrap();
    ws2.integrate(ws.batches_missing_from(&Version::root()).unwrap()).unwrap();
    let dir2 = tempfile::tempdir().unwrap();
    let m2 = Mount::start(&ws2, dir2.path(), MountOptions::default()).unwrap();
    assert_eq!(fs::read(dir2.path().join("blob.bin")).unwrap(), [9u8, 0, 9]);
    assert_eq!(fs::read(dir2.path().join("win.txt")).unwrap(), b"a\r\nb\r\nc\r\n");
    drop(m2);
}

/// Two replicas, both mounted; a remote edit arrives while the local disk has
/// a concurrent edit to the same file. Both survive on both sides.
#[test]
fn concurrent_disk_and_remote_edits_merge() {
    let (dir, a) = setup();
    let root_a = dir.path().join("wt");
    let mount_a = Mount::start(&a, &root_a, MountOptions::default()).unwrap();
    fs::write(root_a.join("notes.txt"), "one\ntwo\nthree\n").unwrap();
    mount_a.fence().unwrap();

    let dir_b = tempfile::tempdir().unwrap();
    let b = Workspace::open(dir_b.path().join("b.db"), Some(a.id())).unwrap();
    b.integrate(a.batches_missing_from(&Version::root()).unwrap()).unwrap();
    let root_b = dir_b.path().join("wt");
    fs::create_dir_all(&root_b).unwrap();
    let mount_b = Mount::start(&b, &root_b, MountOptions::default()).unwrap();
    assert_eq!(fs::read_to_string(root_b.join("notes.txt")).unwrap(), "one\ntwo\nthree\n");

    // Concurrent: A edits line 1, B edits line 3 on disk.
    fs::write(root_a.join("notes.txt"), "ONE\ntwo\nthree\n").unwrap();
    mount_a.fence().unwrap();
    fs::write(root_b.join("notes.txt"), "one\ntwo\nTHREE\n").unwrap();
    // Deliver A's change to B before B's watcher has necessarily ingested.
    b.integrate(a.batches_missing_from(&b.heads()).unwrap()).unwrap();
    mount_b.fence().unwrap();
    a.integrate(b.batches_missing_from(&a.heads()).unwrap()).unwrap();
    mount_a.fence().unwrap();

    let expected = "ONE\ntwo\nTHREE\n";
    assert_eq!(fs::read_to_string(root_b.join("notes.txt")).unwrap(), expected);
    assert_eq!(fs::read_to_string(root_a.join("notes.txt")).unwrap(), expected);
    assert_eq!(a.heads(), b.heads());
}

#[test]
fn watcher_ingests_on_its_own_and_fences_use_markers() {
    let (dir, ws) = setup();
    let root = dir.path().join("wt");
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    fs::write(root.join("README.md"), "# live\n").unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while text(&ws, "README.md").as_deref() != Some("# live\n") {
        assert!(std::time::Instant::now() < deadline, "watcher never ingested the change");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    fs::write(root.join("README.md"), "# fenced\n").unwrap();
    let outcome = mount.fence().unwrap();
    assert!(!outcome.rescanned, "fence should resolve via its marker event");
    assert_eq!(text(&ws, "README.md").as_deref(), Some("# fenced\n"));
}

#[test]
fn one_live_mount_per_directory() {
    let (dir, ws) = setup();
    let root = dir.path().join("wt");
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    let other = Workspace::open(dir.path().join("0ndb.db"), None).unwrap();
    assert!(
        matches!(Mount::start(&other, &root, MountOptions::default()), Err(ondb::Error::Invalid(m)) if m.contains("already mounted"))
    );
    mount.stop();
    Mount::start(&other, &root, MountOptions::default()).unwrap();
}

/// Separate databases (say, production and a test build) can track the same
/// directory at once. Each records the other's writes once, as an external
/// change, and nothing is duplicated.
#[test]
fn separate_histories_share_a_directory() {
    let (dir, prod) = setup();
    let root = dir.path().join("wt");
    let test = Workspace::open(dir.path().join("test.db"), None).unwrap();
    let prod_mount = Mount::start(&prod, &root, MountOptions::default()).unwrap();
    let test_mount = Mount::start(&test, &root, MountOptions::default()).unwrap();
    assert_ne!(prod.id(), test.id());
    assert_eq!(text(&test, "README.md").as_deref(), Some("# demo\n"));

    // Any process's write lands once in each history.
    fs::write(root.join("README.md"), "# demo\nline two\n").unwrap();
    prod_mount.fence().unwrap();
    test_mount.fence().unwrap();
    for ws in [&prod, &test] {
        assert_eq!(text(ws, "README.md").as_deref(), Some("# demo\nline two\n"));
    }

    // An agent attributed in the test history: its edit is credited there,
    // and production sees it as an ordinary disk change, exactly once.
    let agent = test.actor("codex", ActorKind::Agent).unwrap();
    let recorder = Recorder::new(&test, vec![test_mount.handle()]).unwrap();
    let (_, record) =
        recorder.scoped(ScopeKind::Command, "append", Some(agent), None, |_| sh(&root, "echo 'from test' >> README.md")).unwrap();
    assert_eq!(record.batches.len(), 1);
    prod_mount.fence().unwrap();
    let expected = "# demo\nline two\nfrom test\n";
    assert_eq!(text(&prod, "README.md").as_deref(), Some(expected));
    assert_eq!(text(&test, "README.md").as_deref(), Some(expected));

    // Tool writes and reverts in one history reach disk; the other ingests
    // them without echoing anything back.
    let tool = prod.actor("claude", ActorKind::Agent).unwrap();
    prod_mount.write_file(tool, "src/new.rs", b"pub fn x() {}\n".to_vec()).unwrap();
    test_mount.fence().unwrap();
    assert_eq!(text(&test, "src/new.rs").as_deref(), Some("pub fn x() {}\n"));
    recorder.revert(&record.id, agent, true).unwrap();
    test_mount.fence().unwrap();
    prod_mount.fence().unwrap();
    let expected = "# demo\nline two\n";
    assert_eq!(fs::read_to_string(root.join("README.md")).unwrap(), expected);
    assert_eq!(text(&prod, "README.md").as_deref(), Some(expected));
    assert_eq!(text(&test, "README.md").as_deref(), Some(expected));

    // Quiet afterwards: neither keeps re-ingesting the other's writes.
    let (p, t) = (prod.heads(), test.heads());
    std::thread::sleep(std::time::Duration::from_millis(600));
    prod_mount.fence().unwrap();
    test_mount.fence().unwrap();
    assert_eq!((prod.heads(), test.heads()), (p, t), "the mounts echo each other");

    // Same history twice is still refused.
    let again = Workspace::open(dir.path().join("test.db"), None).unwrap();
    assert!(
        matches!(Mount::start(&again, &root, MountOptions::default()), Err(ondb::Error::Invalid(m)) if m.contains("already mounted"))
    );
}

/// A program writing a temp file and renaming it into place (`sed -i`,
/// editors) must not leave the temp file in history, even when it lives
/// longer than the debounce window.
#[test]
fn transient_temp_files_are_not_recorded() {
    let (dir, ws) = setup();
    let root = dir.path().join("wt");
    let _mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    fs::write(root.join(".!123!README.md"), "# rewritten\n").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(70));
    fs::rename(root.join(".!123!README.md"), root.join("README.md")).unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while text(&ws, "README.md").as_deref() != Some("# rewritten\n") {
        assert!(std::time::Instant::now() < deadline, "rewrite never ingested");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let created_temp = ws
        .batches_missing_from(&Version::root())
        .unwrap()
        .iter()
        .flat_map(|b| b.ops.clone())
        .any(|op| matches!(op, ondb_core::Op::CreateFile { name, .. } if name.starts_with(".!123!")));
    assert!(!created_temp, "temp file was recorded");
}

/// `git checkout` rewrites files, but it is git moving the checkout, not an
/// edit: one batch marked as a checkout, never credited to the scope that
/// ran it, summarized (not diffed) in reports, and untouched by revert.
#[test]
fn git_branch_switches_are_not_edits() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    let git = |args: &str| sh(&root, &format!("git -c user.name=t -c user.email=t@t {args}"));
    git("init -q -b main");
    fs::write(root.join("a.txt"), "main a\n").unwrap();
    fs::write(root.join("shared.txt"), (0..200).map(|i| format!("line {i}\n")).collect::<String>()).unwrap();
    git("add -A && git -c user.name=t -c user.email=t@t commit -qm main");
    git("checkout -qb feature");
    fs::write(root.join("a.txt"), "feature a\n").unwrap();
    fs::write(root.join("only-feature.txt"), "f\n").unwrap();
    fs::remove_file(root.join("shared.txt")).unwrap();
    git("add -A && git -c user.name=t -c user.email=t@t commit -qm feature");
    git("checkout -q main");

    let ws = Workspace::open(dir.path().join("0ndb.db"), None).unwrap();
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    let agent = ws.actor("codex", ActorKind::Agent).unwrap();
    let recorder = Recorder::new(&ws, vec![mount.handle()]).unwrap();
    let a_inode = inode(&ws, "a.txt").unwrap();

    let (_, record) = recorder
        .scoped(ScopeKind::Command, "git checkout feature", Some(agent), None, |_| {
            git("checkout -q feature");
            fs::write(root.join("note.md"), "agent note\n").unwrap();
        })
        .unwrap();
    assert_eq!(text(&ws, "a.txt").as_deref(), Some("feature a\n"));
    assert!(inode(&ws, "shared.txt").is_none());
    assert_eq!(inode(&ws, "a.txt"), Some(a_inode), "files keep identity across a checkout");

    // The checkout batch exists, is marked, and is not credited to the scope.
    let all = ws.batches_missing_from(&Version::root()).unwrap();
    let checkouts: Vec<_> =
        all.iter().filter(|b| b.ops.iter().any(|op| matches!(op, ondb_core::Op::GitCheckout { .. }))).collect();
    assert_eq!(checkouts.len(), 1, "one checkout batch, not split into edits");
    assert!(!record.batches.contains(&checkouts[0].id()), "checkout credited to the scope");
    assert!(!record.batches.is_empty(), "the agent's real edit is still credited");

    // Reports summarize the switch instead of diffing every file.
    let user = ws.actor("someone-else", ActorKind::Agent).unwrap();
    let report = foreign_changes(&ws, &record.start_version, user).unwrap();
    let head = report.git_head.as_ref().expect("head move reported");
    assert!(head.to.starts_with("refs/heads/feature@"), "{head:?}");
    assert_eq!((head.edited, head.created, head.removed), (1, 1, 1));
    assert!(report.changes.iter().all(|c| !matches!(c, FileChange::Edited { path, .. } if path == "a.txt")));

    // Reverting the scope undoes the agent's edit, not the branch switch.
    recorder.revert(&record.id, agent, true).unwrap();
    mount.fence().unwrap();
    assert!(!root.join("note.md").exists());
    assert_eq!(fs::read_to_string(root.join("a.txt")).unwrap(), "feature a\n");

    // Switching back is another checkout, also not an edit.
    git("checkout -q main");
    mount.fence().unwrap();
    assert_eq!(text(&ws, "a.txt").as_deref(), Some("main a\n"));
    assert!(inode(&ws, "shared.txt").is_some());
}

/// What git wrote is told apart from what anyone edited using git's own
/// records: commits write nothing, an edit right after a switch is still an
/// edit, a conflicted merge's writes are git's, and a switch made while
/// unmounted is still recognized as one.
#[test]
fn git_writes_are_told_apart_from_edits() {
    use ondb_core::Op;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    let git = |args: &str| sh(&root, &format!("git -c user.name=t -c user.email=t@t {args}"));
    git("init -q -b main");
    fs::write(root.join("a.txt"), "main a\n").unwrap();
    fs::write(root.join("b.txt"), "b\n").unwrap();
    git("add -A && git -c user.name=t -c user.email=t@t commit -qm main");
    git("checkout -qb feature");
    fs::write(root.join("a.txt"), "feature a\n").unwrap();
    git("commit -qam feature && git checkout -q main");

    let ws = Workspace::open(dir.path().join("0ndb.db"), None).unwrap();
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    let agent = ws.actor("codex", ActorKind::Agent).unwrap();
    let recorder = Recorder::new(&ws, vec![mount.handle()]).unwrap();
    let marked = |id: &ondb_core::BatchId| ws.summary(id).unwrap().git_checkout;

    // Edit + commit in one command: the commit moves HEAD but writes
    // nothing, so the edit is the agent's.
    let (_, rec) = recorder
        .scoped(ScopeKind::Command, "edit and commit", Some(agent), None, |_| {
            fs::write(root.join("b.txt"), "b by agent\n").unwrap();
            git("commit -qam agent");
        })
        .unwrap();
    let credited: Vec<_> = rec.batches.iter().filter(|b| !marked(b)).collect();
    assert_eq!(credited.len(), 1, "the committed edit is credited");

    // Switch, then edit a file the switch wrote, in the same window: git's
    // version lands in the checkout batch, the edit on top of it is credited.
    let (_, rec) = recorder
        .scoped(ScopeKind::Command, "switch and edit", Some(agent), None, |_| {
            git("checkout -q feature");
            fs::write(root.join("a.txt"), "feature a\nagent line\n").unwrap();
        })
        .unwrap();
    assert_eq!(text(&ws, "a.txt").as_deref(), Some("feature a\nagent line\n"));
    let all = ws.batches_missing_from(&Version::root()).unwrap();
    let checkout = all.iter().rev().find(|b| b.ops.iter().any(|op| matches!(op, Op::GitCheckout { .. }))).unwrap();
    assert!(!rec.batches.contains(&checkout.id()));
    assert!(rec.batches.iter().any(|b| !marked(b)), "the edit on top of the switch is credited");
    recorder.revert(&rec.id, agent, true).unwrap();
    mount.fence().unwrap();
    assert_eq!(fs::read_to_string(root.join("a.txt")).unwrap(), "feature a\n", "revert keeps git's version");
    git("checkout -q -- . && git checkout -q main");
    mount.fence().unwrap();

    // A conflicted merge: HEAD doesn't move, but the conflict markers are
    // git's. The resolution is the agent's.
    git("checkout -qb clash && echo 'clash a' > a.txt && git -c user.name=t -c user.email=t@t commit -qam clash");
    mount.fence().unwrap();
    let (_, rec) = recorder
        .scoped(ScopeKind::Command, "merge", Some(agent), None, |_| {
            let _ = Command::new("git").args(["merge", "-q", "feature"]).current_dir(&root).output();
        })
        .unwrap();
    assert!(fs::read_to_string(root.join("a.txt")).unwrap().contains("<<<<<<<"));
    assert!(rec.batches.iter().all(&marked), "conflict markers credited to the agent");
    let all = ws.batches_missing_from(&Version::root()).unwrap();
    assert!(all.iter().any(|b| b.ops.iter().any(|op| matches!(op, Op::GitWrite { operation, .. } if operation == "merge"))));
    let (_, rec) = recorder
        .scoped(ScopeKind::Command, "resolve", Some(agent), None, |_| {
            fs::write(root.join("a.txt"), "resolved a\n").unwrap();
            git("add -A && git -c user.name=t -c user.email=t@t commit -qm merged");
        })
        .unwrap();
    assert!(rec.batches.iter().any(|b| !marked(b)), "the resolution is credited");
    drop(recorder);
    mount.stop();

    // While unmounted: a switch plus an unrelated edit.
    git("checkout -q main");
    fs::write(root.join("b.txt"), "offline\n").unwrap();
    let before = ws.heads();
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    mount.fence().unwrap();
    let new = ws.batches_missing_from(&before).unwrap();
    let co: Vec<_> = new.iter().filter(|b| b.ops.iter().any(|op| matches!(op, Op::GitCheckout { .. }))).collect();
    assert_eq!(co.len(), 1, "offline switch recognized");
    let b_inode = inode(&ws, "b.txt").unwrap();
    assert!(!co[0].touched().contains(&b_inode), "the offline edit isn't git's");
    assert!(new.iter().any(|b| !co.contains(&b) && b.touched().contains(&b_inode)));
}

/// An idle mount drops its in-memory state; ignored build output doesn't
/// wake it, and anything relevant (edits, tool writes, git switches) wakes it
/// and is handled exactly as if it had stayed resident.
#[test]
fn idle_mounts_hibernate_and_wake_transparently() {
    use std::time::{Duration, Instant};
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    let git = |args: &str| sh(&root, &format!("git -c user.name=t -c user.email=t@t {args}"));
    git("init -q -b main");
    fs::write(root.join(".gitignore"), "target/\n").unwrap();
    fs::write(root.join("a.txt"), "main a\n").unwrap();
    git("add -A && git -c user.name=t -c user.email=t@t commit -qm main");
    git(
        "checkout -qb feature && echo 'feature a' > a.txt && git -c user.name=t -c user.email=t@t commit -qam f && git checkout -q main",
    );

    let ws = Workspace::open(dir.path().join("0ndb.db"), None).unwrap();
    let opts = MountOptions { idle_unload: Some(Duration::from_millis(300)), ..MountOptions::default() };
    let mount = Mount::start(&ws, &root, opts).unwrap();
    let wait_hibernating = || {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !ws.is_hibernating() {
            assert!(Instant::now() < deadline, "never hibernated");
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    wait_hibernating();

    // Build output in an ignored directory doesn't wake it.
    fs::create_dir_all(root.join("target/debug")).unwrap();
    for i in 0..200 {
        fs::write(root.join(format!("target/debug/obj{i}.o")), "x").unwrap();
    }
    std::thread::sleep(Duration::from_millis(250));
    assert!(ws.is_hibernating(), "ignored churn woke the mount");

    // An edit wakes it and is ingested against the reloaded shadow.
    fs::write(root.join("a.txt"), "main a\nedited\n").unwrap();
    mount.fence().unwrap();
    assert_eq!(text(&ws, "a.txt").as_deref(), Some("main a\nedited\n"));
    git("checkout -q -- .");
    mount.fence().unwrap();
    wait_hibernating();

    // A tool write while hibernating.
    let agent = ws.actor("codex", ActorKind::Agent).unwrap();
    wait_hibernating();
    mount.write_file(agent, "b.txt", b"from tool\n".to_vec()).unwrap();
    assert_eq!(fs::read_to_string(root.join("b.txt")).unwrap(), "from tool\n");
    fs::remove_file(root.join("b.txt")).unwrap();
    mount.fence().unwrap();
    wait_hibernating();

    // A branch switch while hibernating is still recognized as git's.
    let before = ws.heads();
    git("checkout -q feature");
    mount.fence().unwrap();
    assert_eq!(text(&ws, "a.txt").as_deref(), Some("feature a\n"));
    let new = ws.batches_missing_from(&before).unwrap();
    assert!(new.iter().any(|b| b.ops.iter().any(|op| matches!(op, ondb_core::Op::GitCheckout { .. }))));
    assert!(new.iter().all(|b| ws.summary(&b.id()).unwrap().git_checkout || b.touched().is_empty()), "switch split into edits");
    assert!(inode(&ws, "target/debug/obj1.o").is_none());
}

/// Adopting a directory larger than one chunk commits several batches whose
/// directories and files still line up, and everything round-trips.
#[test]
fn large_adoption_commits_in_chunks() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("big");
    fs::create_dir_all(root.join("data")).unwrap();
    let mut seed = 0x9e3779b97f4a7c15u64;
    for i in 0..40 {
        let bytes: Vec<u8> = (0..1 << 20)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                seed as u8
            })
            .collect();
        fs::write(root.join(format!("data/blob{i:02}.bin")), bytes).unwrap();
    }
    fs::create_dir_all(root.join("data/zz/deeper")).unwrap();
    fs::write(root.join("data/zz/deeper/note.txt"), "after the chunk boundary\n").unwrap();
    let ws = Workspace::open(dir.path().join("0ndb.db"), None).unwrap();
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    let batches = ws.batches_missing_from(&Version::root()).unwrap();
    assert!(batches.iter().filter(|b| !b.touched().is_empty()).count() > 1, "adoption wasn't chunked");
    assert_eq!(text(&ws, "data/zz/deeper/note.txt").as_deref(), Some("after the chunk boundary\n"));
    for i in [0, 20, 39] {
        let p = format!("data/blob{i:02}.bin");
        let state = ws.read(|h| h.lookup(&p).and_then(|id| h.file_state(&h.current(), &id))).expect("tracked");
        let ondb_core::FileState::Binary { blob, .. } = state else { panic!("{p} not binary") };
        assert_eq!(ws.blob(&blob.oid).unwrap().unwrap(), fs::read(root.join(&p)).unwrap());
    }
    drop(mount);
    // A restart finds nothing to re-ingest.
    let heads = ws.heads();
    let _mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    assert_eq!(ws.heads(), heads);
}

#[test]
fn git_content_is_referenced_pinned_and_survives_gc() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    let big: String = (0..3000).map(|i| format!("line {i}\n")).collect();
    fs::write(root.join("big.txt"), &big).unwrap();
    fs::write(root.join("small.txt"), "small\n").unwrap();
    fs::write(root.join("bin.dat"), [0u8, 1, 2, 3, 255]).unwrap();
    let git = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main";
    sh(&root, &format!("{git} init -q && {git} add -A && {git} commit -qm base"));
    sh(&root, &format!("{git} switch -qc side && echo only-on-side > side.txt && {git} add side.txt && {git} commit -qm side"));

    let db = dir.path().join("0ndb.db");
    let ws = Workspace::open(&db, None).unwrap();
    let mount = Mount::start(&ws, &root, MountOptions::default()).unwrap();
    let side = inode(&ws, "side.txt").unwrap();
    let stored = ws.with(|c| c.store().0.stored_blob_count()).unwrap();
    assert_eq!(stored, 0, "everything git holds is referenced, not copied");
    let pin = format!("refs/0ndb/{}", ws.id());
    sh(&root, &format!("git rev-parse -q --verify {pin} >/dev/null"));

    // The only commit holding side.txt goes away and git collects garbage.
    let before = ws.heads();
    sh(&root, &format!("{git} switch -q main && {git} branch -qD side"));
    mount.fence().unwrap();
    assert!(inode(&ws, "side.txt").is_none());
    sh(&root, "git reflog expire --expire=now --all && git gc -q --prune=now");
    let side_oid = String::from_utf8(
        Command::new("git")
            .args(["hash-object", "--stdin"])
            .current_dir(&root)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut c| {
                use std::io::Write;
                c.stdin.take().unwrap().write_all(b"only-on-side\n")?;
                c.wait_with_output()
            })
            .unwrap()
            .stdout,
    )
    .unwrap();
    sh(&root, &format!("git cat-file -e {}", side_oid.trim()));

    // Restoring the deleted file reads it back out of git.
    let undo: std::collections::HashSet<_> = ws.read(|h| h.dag().difference(h.heads(), &before)).into_iter().collect();
    ondb::revert::revert_batches(&ws, ws.actor("t", ActorKind::Human).unwrap(), &undo).unwrap();
    mount.fence().unwrap();
    assert_eq!(fs::read_to_string(root.join("side.txt")).unwrap(), "only-on-side\n");
    assert_eq!(inode(&ws, "side.txt"), Some(side), "same file, same identity");
    drop(mount);

    // Without a mount, a fresh workspace still reads git-held content.
    drop(ws);
    let ws = Workspace::open(&db, None).unwrap();
    assert_eq!(text(&ws, "big.txt").as_deref(), Some(big.as_str()));
    assert_eq!(text(&ws, "small.txt").as_deref(), Some("small\n"));
}

#[test]
fn files_over_the_size_limit_are_tracked_through_git() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    let big = |tag: &str| -> String { (0..400).map(|i| format!("{tag} {i}\n")).collect() };
    fs::write(root.join("tracked.bin"), big("tracked")).unwrap();
    let git = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main";
    sh(&root, &format!("{git} init -q && {git} add -A && {git} commit -qm base"));
    // Untracked and over the limit: written into git's objects to be kept.
    fs::write(root.join("untracked.bin"), big("untracked")).unwrap();

    let opts = MountOptions { max_file_size: 1024, ..MountOptions::default() };
    let ws = Workspace::open(dir.path().join("0ndb.db"), None).unwrap();
    let mount = Mount::start(&ws, &root, opts).unwrap();
    for f in ["tracked.bin", "untracked.bin"] {
        assert!(inode(&ws, f).is_some(), "{f} is tracked");
    }
    assert_eq!(ws.with(|c| c.store().0.stored_blob_count()).unwrap(), 0, "large content lives in git, not the store");
    let state = |p: &str| ws.read(|h| h.lookup(p).and_then(|i| h.file_state(&h.current(), &i)));
    assert!(matches!(state("untracked.bin"), Some(ondb_core::FileState::Binary { .. })));

    // An edit to a large file is recorded, and undoing it streams the old
    // bytes back out of git.
    let before = ws.heads();
    fs::write(root.join("untracked.bin"), big("edited")).unwrap();
    mount.fence().unwrap();
    assert_ne!(ws.heads(), before);
    let undo: std::collections::HashSet<_> = ws.read(|h| h.dag().difference(h.heads(), &before)).into_iter().collect();
    ondb::revert::revert_batches(&ws, ws.actor("t", ActorKind::Human).unwrap(), &undo).unwrap();
    mount.fence().unwrap();
    assert_eq!(fs::read_to_string(root.join("untracked.bin")).unwrap(), big("untracked"));

    // The untracked file's blob is referenced by no commit; only the pin
    // keeps it through garbage collection. Delete the file, then restore it.
    sh(&root, "git reflog expire --expire=now --all && git gc -q --prune=now");
    let present = ws.heads();
    fs::remove_file(root.join("untracked.bin")).unwrap();
    mount.fence().unwrap();
    assert!(inode(&ws, "untracked.bin").is_none());
    let undo: std::collections::HashSet<_> = ws.read(|h| h.dag().difference(h.heads(), &present)).into_iter().collect();
    ondb::revert::revert_batches(&ws, ws.actor("t", ActorKind::Human).unwrap(), &undo).unwrap();
    mount.fence().unwrap();
    assert_eq!(fs::read_to_string(root.join("untracked.bin")).unwrap(), big("untracked"));
}
