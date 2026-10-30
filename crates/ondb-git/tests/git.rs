//! Against real git: a bare "remote", a clone, and linked worktrees.

use std::fs;
use std::path::Path;
use std::process::Command;

use ondb_git::{Checkout, Forges, RemoteUrl, Repo, RepoId};

fn sh(dir: &Path, script: &str) {
    let ok = Command::new("sh").arg("-c").arg(script).current_dir(dir).status().unwrap().success();
    assert!(ok, "{script}");
}

const GIT: &str = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main";

fn setup() -> (tempfile::TempDir, Repo) {
    let dir = tempfile::tempdir().unwrap();
    let d = dir.path();
    sh(d, &format!("{GIT} init -q --bare remote.git"));
    sh(d, &format!("{GIT} clone -q remote.git clone 2>/dev/null"));
    let clone = d.join("clone");
    fs::write(clone.join("a.txt"), "a\n").unwrap();
    sh(
        &clone,
        &format!("{GIT} add -A && {GIT} commit -qm first && {GIT} push -q origin main && git remote set-head origin main"),
    );
    sh(&clone, "git remote add upstream git@github.com:zeronsh/0ndb.git");
    let repo = Repo::open(clone.join(".")).unwrap();
    (dir, repo)
}

#[test]
fn inspects_a_repository() {
    let (_dir, repo) = setup();
    let head = repo.head().unwrap();
    assert_eq!(head.branch.as_deref(), Some("main"));
    assert!(head.oid.is_some());
    assert!(matches!(repo.identity().unwrap(), RepoId::RootCommit(_)));
    assert_eq!(repo.default_branch("origin").unwrap().as_deref(), Some("main"));
    let remotes = repo.remotes().unwrap();
    let upstream = remotes.iter().find(|r| r.name == "upstream").unwrap();
    assert_eq!(upstream.parsed.as_ref().map(RemoteUrl::slug).as_deref(), Some("zeronsh/0ndb"));
    assert_eq!(repo.primary_remote(Some("main")).unwrap().unwrap().name, "origin");

    let root = repo.root().to_path_buf();
    fs::write(root.join("a.txt"), "changed\n").unwrap();
    fs::write(root.join("new.txt"), "n\n").unwrap();
    sh(&root, "git add new.txt");
    fs::write(root.join("untracked.txt"), "u\n").unwrap();
    let st = repo.status().unwrap();
    assert_eq!((st.staged, st.unstaged, st.untracked), (1, 1, 1));
    assert_eq!(st.branch.as_deref(), Some("main"));
    assert_eq!(st.upstream.as_deref(), Some("origin/main"));
    // Read-only commands never leave an index lock behind for the user.
    assert!(!repo.git_dir().join("index.lock").exists());
}

#[test]
fn manages_worktrees() {
    let (dir, repo) = setup();
    let name = repo.unique_branch("ondb/", "Fix the login bug").unwrap();
    assert_eq!(name, "ondb/fix-the-login-bug");
    let path = dir.path().join("wt-login");
    let wt = repo.add_worktree(&path, &Checkout::NewBranch { name: name.clone(), base: "main".into() }).unwrap();
    assert_eq!(wt.branch.as_deref(), Some(name.as_str()));
    assert_eq!(repo.unique_branch("ondb/", "Fix the login bug").unwrap(), "ondb/fix-the-login-bug-2");

    let linked = Repo::open(&path).unwrap();
    assert!(linked.is_linked_worktree());
    assert_eq!(linked.common_dir(), repo.common_dir());
    assert_eq!(linked.identity().unwrap(), repo.identity().unwrap(), "worktrees share an identity");

    let detached = dir.path().join("wt-detached");
    let d = repo.add_worktree(&detached, &Checkout::Detached("main".into())).unwrap();
    assert!(d.detached);
    let branches = repo.branches().unwrap();
    let b = branches.iter().find(|b| b.name == name).unwrap();
    assert!(b.worktree.as_ref().is_some_and(|w| w.ends_with("wt-login")));
    assert_eq!(repo.worktrees().unwrap().len(), 3);

    // Dirty worktrees are only removed when forced.
    fs::write(path.join("wip.txt"), "wip\n").unwrap();
    assert!(repo.remove_worktree(&path, false).is_err());
    repo.remove_worktree(&path, true).unwrap();
    assert!(!path.exists());
    fs::remove_dir_all(&detached).unwrap();
    repo.prune_worktrees().unwrap();
    assert_eq!(repo.worktrees().unwrap().len(), 1);
    repo.delete_branch(&name, true).unwrap();
    assert!(!repo.branch_exists(&name).unwrap());
}

#[test]
fn routes_remotes_to_providers() {
    let mut forges = Forges::default();
    let gh = RemoteUrl::parse("git@github.com:zeronsh/0ndb.git").unwrap();
    assert_eq!(forges.for_remote(&gh).unwrap().id(), "github");
    let ghe = RemoteUrl::parse("https://github.acme.com/team/repo").unwrap();
    assert!(forges.for_remote(&ghe).is_err());
    forges.map_host("github.acme.com", "github").unwrap();
    assert_eq!(forges.for_remote(&ghe).unwrap().id(), "github");
    assert!(forges.map_host("gitlab.acme.com", "gitlab").is_err(), "unknown providers can't be mapped");
}

/// `ONDB_LIVE_GITHUB=owner/repo` checks the GitHub provider against a real
/// repository (read-only).
#[test]
fn live_github_read_only() {
    let Ok(slug) = std::env::var("ONDB_LIVE_GITHUB") else { return };
    let remote = RemoteUrl::parse(&format!("https://github.com/{slug}")).unwrap();
    let forges = Forges::default();
    let gh = forges.for_remote(&remote).unwrap();
    assert!(gh.signed_in("github.com").unwrap());
    let repo = gh.repository(&remote).unwrap();
    assert_eq!(repo.slug.to_ascii_lowercase(), slug.to_ascii_lowercase());
    gh.open_change_requests(&remote, 5).unwrap();
    assert_eq!(gh.change_request_for_branch(&remote, "no-such-branch-for-ondb", None).unwrap(), None);
}
