//! Managed worktrees against real git.

use std::fs;
use std::path::Path;
use std::process::Command;

use ondb::git::Forges;
use ondb::{MountOptions, Worktrees};

fn sh(dir: &Path, script: &str) {
    let ok = Command::new("sh").arg("-c").arg(script).current_dir(dir).status().unwrap().success();
    assert!(ok, "{script}");
}

const GIT: &str = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main";

fn text(ws: &ondb::Workspace, path: &str) -> Option<String> {
    ws.read(|h| h.lookup(path).and_then(|i| h.text(&i))).map(|b| String::from_utf8(b).unwrap())
}

#[test]
fn creates_mounts_reopens_and_removes_worktrees() {
    let dir = tempfile::tempdir().unwrap();
    let d = dir.path();
    sh(d, &format!("{GIT} init -q --bare remote.git && {GIT} clone -q remote.git app 2>/dev/null"));
    let app = d.join("app");
    fs::write(app.join("main.rs"), "fn main() {}\n").unwrap();
    sh(&app, &format!("{GIT} add -A && {GIT} commit -qm init && {GIT} push -q origin main && git remote set-head origin main"));

    let state = d.join("state");
    let checkouts = d.join("checkouts");
    let wts = Worktrees::open(&state, &checkouts, MountOptions::default(), Forges::default()).unwrap();
    let wt = wts.create(&app, "Fix the bug", None).unwrap();
    assert_eq!(wt.branch.as_deref(), Some("ondb/fix-the-bug"));
    assert!(wt.path.starts_with(fs::canonicalize(&checkouts).unwrap()));
    assert_eq!(fs::read_to_string(wt.path.join("main.rs")).unwrap(), "fn main() {}\n");
    assert!(!wt.path.join(".0ndb/0ndb.db").exists(), "history lives in the state dir");

    // It's mounted: edits are tracked.
    let (ws, mount) = wts.workspace(&wt.id).unwrap();
    fs::write(wt.path.join("main.rs"), "fn main() { fix() }\n").unwrap();
    mount.fence().unwrap();
    assert_eq!(text(&ws, "main.rs").as_deref(), Some("fn main() { fix() }\n"));
    let main = wts.adopt(&app, "main checkout").unwrap();
    assert!(!main.created);
    assert_eq!(wts.list().len(), 2);
    drop((ws, mount));
    drop(wts);

    // A restart remounts everything, and edits made meanwhile are picked up.
    fs::write(wt.path.join("notes.md"), "while closed\n").unwrap();
    let wts = Worktrees::open(&state, &checkouts, MountOptions::default(), Forges::default()).unwrap();
    assert_eq!(wts.list().len(), 2);
    let (ws, _) = wts.workspace(&wt.id).unwrap();
    assert_eq!(text(&ws, "notes.md").as_deref(), Some("while closed\n"));

    // Removal refuses uncommitted work unless forced, then cleans up fully.
    assert!(wts.remove(&wt.id, false, true).is_err());
    wts.remove(&wt.id, true, true).unwrap();
    assert!(!wt.path.exists());
    assert!(!wt.db.exists());
    let branches = Command::new("git").args(["branch", "--list", "ondb/*"]).current_dir(&app).output().unwrap();
    assert!(branches.stdout.is_empty(), "branch deleted");
    // Adopted folders are only unmounted, never deleted.
    wts.remove(&main.id, false, false).unwrap();
    assert!(app.join("main.rs").exists());
    assert!(wts.list().is_empty());
}
