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
