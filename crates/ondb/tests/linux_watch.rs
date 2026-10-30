//! Linux watching at scale: every mount in a process shares one inotify
//! instance, ignored trees cost no watches, and directories are followed as
//! they appear, move and disappear. (Own test binary: counts are per
//! process.)
#![cfg(target_os = "linux")]

use std::fs;
use std::path::Path;

use ondb::{Mount, MountOptions, Workspace};

/// (inotify instances, total watches) held by this process.
fn inotify_usage() -> (usize, usize) {
    let mut instances = 0;
    let mut watches = 0;
    for fd in fs::read_dir("/proc/self/fd").unwrap().flatten() {
        if fs::read_link(fd.path()).is_ok_and(|t| t.to_string_lossy().contains("inotify")) {
            instances += 1;
            let info = fs::read_to_string(Path::new("/proc/self/fdinfo").join(fd.file_name())).unwrap_or_default();
            watches += info.lines().filter(|l| l.starts_with("inotify wd:")).count();
        }
    }
    (instances, watches)
}

fn text(ws: &Workspace, path: &str) -> Option<String> {
    ws.read(|h| h.lookup(path).and_then(|i| h.text(&i))).map(|b| String::from_utf8(b).unwrap())
}

#[test]
fn mounts_share_one_inotify_instance_and_skip_ignored_trees() {
    let dir = tempfile::tempdir().unwrap();
    // More than the default per-user instance limit (128).
    let n = 150;
    let mut mounts = Vec::new();
    for i in 0..n {
        let root = dir.path().join(format!("wt{i}"));
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("src/lib.rs"), "fn a() {}\n").unwrap();
        fs::write(root.join(".gitignore"), "node_modules/\n").unwrap();
        for d in 0..40 {
            fs::create_dir_all(root.join(format!("node_modules/pkg{d}/lib"))).unwrap();
        }
        let ws = Workspace::open(dir.path().join(format!("{i}.db")), None).unwrap();
        let m = Mount::start(&ws, &root, MountOptions::default()).unwrap();
        mounts.push((ws, m, root));
    }
    let (instances, watches) = inotify_usage();
    assert_eq!(instances, 1, "mounts must share one inotify instance");
    // root, src, .0ndb/fences per worktree; none of the 80 node_modules dirs.
    assert!(watches <= 3 * n, "{watches} watches for {n} worktrees");

    for (ws, m, root) in &mounts {
        fs::write(root.join("src/lib.rs"), "fn b() {}\n").unwrap();
        m.fence().unwrap();
        assert_eq!(text(ws, "src/lib.rs").as_deref(), Some("fn b() {}\n"));
    }

    // Directories are followed: created, renamed, removed.
    let (ws, m, root) = &mounts[0];
    fs::create_dir_all(root.join("a/b/c")).unwrap();
    fs::write(root.join("a/b/c/f.txt"), "deep\n").unwrap();
    m.fence().unwrap();
    assert_eq!(text(ws, "a/b/c/f.txt").as_deref(), Some("deep\n"));
    fs::write(root.join("a/b/c/f.txt"), "deep, edited\n").unwrap();
    m.fence().unwrap();
    assert_eq!(text(ws, "a/b/c/f.txt").as_deref(), Some("deep, edited\n"), "new directory not watched");
    fs::rename(root.join("a"), root.join("z")).unwrap();
    m.fence().unwrap();
    fs::write(root.join("z/b/c/g.txt"), "after move\n").unwrap();
    m.fence().unwrap();
    assert_eq!(text(ws, "z/b/c/g.txt").as_deref(), Some("after move\n"), "moved directory not followed");
    assert!(ws.read(|h| h.lookup("a")).is_none());
    fs::remove_dir_all(root.join("z")).unwrap();
    m.fence().unwrap();
    assert!(ws.read(|h| h.lookup("z")).is_none());

    // Un-ignoring a tree starts watching it.
    fs::write(root.join(".gitignore"), "").unwrap();
    m.fence().unwrap();
    fs::write(root.join("node_modules/pkg0/lib/index.js"), "x\n").unwrap();
    m.fence().unwrap();
    assert_eq!(text(ws, "node_modules/pkg0/lib/index.js").as_deref(), Some("x\n"));

    drop(mounts);
    let (_, watches) = inotify_usage();
    assert_eq!(watches, 0, "watches leaked after unmounting");
}
