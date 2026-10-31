//! A repository and its worktrees, read and changed through `git` itself
//! (never a reimplementation), using machine-readable output throughout.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::Error;
use crate::cmd::Cmd;
use crate::remote::RemoteUrl;

const NETWORK_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, Debug)]
pub struct Repo {
    /// The worktree's top level.
    root: PathBuf,
    /// Per-worktree git dir.
    git_dir: PathBuf,
    /// Shared git dir (refs, objects, config).
    common_dir: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Head {
    /// Checked-out branch; `None` when detached.
    pub branch: Option<String>,
    /// `None` on an unborn branch.
    pub oid: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Remote {
    pub name: String,
    pub url: String,
    pub parsed: Option<RemoteUrl>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Branch {
    pub name: String,
    pub oid: String,
    pub upstream: Option<String>,
    /// Worktree that has it checked out, if any.
    pub worktree: Option<PathBuf>,
    pub committed_unix: i64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Status {
    pub branch: Option<String>,
    pub oid: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub staged: u32,
    pub unstaged: u32,
    pub untracked: u32,
    pub conflicted: u32,
}

impl Status {
    pub fn is_clean(&self) -> bool {
        self.staged + self.unstaged + self.untracked + self.conflicted == 0
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Worktree {
    pub path: PathBuf,
    pub oid: Option<String>,
    pub branch: Option<String>,
    pub detached: bool,
    pub bare: bool,
    pub locked: bool,
    /// Git considers it stale (its directory is gone).
    pub prunable: bool,
}

/// What a new worktree checks out.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Checkout {
    /// A new branch `name` starting at `base`.
    NewBranch { name: String, base: String },
    /// An existing local branch (git refuses if another worktree has it).
    Branch(String),
    /// A detached HEAD at a revision.
    Detached(String),
}

/// A repository's stable identity, the same for every clone and worktree:
/// its root commit; for shallow or empty histories, the normalized origin
/// remote; otherwise this device's common git dir.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RepoId {
    RootCommit(String),
    Remote(String),
    Local(PathBuf),
}

impl Repo {
    /// The repository containing `path`.
    pub fn open(path: impl AsRef<Path>) -> Result<Repo, Error> {
        let path = path.as_ref();
        let out = Cmd::git()
            .args(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"])
            .cwd(path)
            .output()?;
        if !out.success() {
            return Err(Error::NotARepo(path.to_path_buf()));
        }
        let text = out.text();
        let mut lines = text.lines().map(PathBuf::from);
        let (Some(root), Some(git_dir), Some(common_dir)) = (lines.next(), lines.next(), lines.next()) else {
            return Err(Error::NotARepo(path.to_path_buf()));
        };
        Ok(Repo { root, git_dir, common_dir })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn git_dir(&self) -> &Path {
        &self.git_dir
    }

    pub fn common_dir(&self) -> &Path {
        &self.common_dir
    }

    /// Whether this is a linked worktree rather than the main checkout.
    pub fn is_linked_worktree(&self) -> bool {
        self.git_dir != self.common_dir
    }

    fn git(&self) -> Cmd {
        Cmd::git().cwd(&self.root)
    }

    pub fn head(&self) -> Result<Head, Error> {
        let branch = self.git().args(["symbolic-ref", "--quiet", "--short", "HEAD"]).output()?;
        let oid = self.git().args(["rev-parse", "--verify", "--quiet", "HEAD"]).output()?;
        Ok(Head {
            branch: branch.success().then(|| branch.text().trim().to_string()),
            oid: oid.success().then(|| oid.text().trim().to_string()),
        })
    }

    pub fn remotes(&self) -> Result<Vec<Remote>, Error> {
        let out = self.git().args(["remote", "-v"]).ok()?;
        let mut remotes: Vec<Remote> = Vec::new();
        for line in out.text().lines() {
            let mut parts = line.split_whitespace();
            let (Some(name), Some(url)) = (parts.next(), parts.next()) else { continue };
            if remotes.iter().any(|r| r.name == name) {
                continue;
            }
            remotes.push(Remote { name: name.into(), url: url.into(), parsed: RemoteUrl::parse(url) });
        }
        Ok(remotes)
    }

    /// The remote a branch tracks, else `origin`, else the only remote.
    pub fn primary_remote(&self, branch: Option<&str>) -> Result<Option<Remote>, Error> {
        let remotes = self.remotes()?;
        if let Some(b) = branch {
            let tracked = self.git().args(["config", "--get", &format!("branch.{b}.remote")]).output()?;
            let name = tracked.text().trim().to_string();
            if let Some(r) = remotes.iter().find(|r| r.name == name) {
                return Ok(Some(r.clone()));
            }
        }
        if let Some(r) = remotes.iter().find(|r| r.name == "origin") {
            return Ok(Some(r.clone()));
        }
        Ok((remotes.len() == 1).then(|| remotes[0].clone()))
    }

    /// The remote's default branch, from its `HEAD` ref (no network).
    pub fn default_branch(&self, remote: &str) -> Result<Option<String>, Error> {
        let out = self.git().args(["symbolic-ref", "--quiet", "--short", &format!("refs/remotes/{remote}/HEAD")]).output()?;
        Ok(out.success().then(|| {
            let full = out.text().trim().to_string();
            full.strip_prefix(&format!("{remote}/")).map(str::to_string).unwrap_or(full)
        }))
    }

    pub fn identity(&self) -> Result<RepoId, Error> {
        let shallow = self.git().args(["rev-parse", "--is-shallow-repository"]).output()?.text().trim() == "true";
        if !shallow {
            let roots = self.git().args(["rev-list", "--max-parents=0", "HEAD"]).output()?;
            if roots.success()
                && let Some(min) = roots.text().lines().map(str::trim).filter(|l| !l.is_empty()).min()
            {
                return Ok(RepoId::RootCommit(min.to_string()));
            }
        }
        if let Some(r) = self.primary_remote(None)?.and_then(|r| r.parsed) {
            return Ok(RepoId::Remote(r.key()));
        }
        Ok(RepoId::Local(self.common_dir.clone()))
    }

    pub fn branches(&self) -> Result<Vec<Branch>, Error> {
        let out = self
            .git()
            .args([
                "for-each-ref",
                "--format=%(refname:short)%00%(objectname)%00%(upstream:short)%00%(worktreepath)%00%(committerdate:unix)",
                "refs/heads",
            ])
            .ok()?;
        Ok(out
            .text()
            .lines()
            .filter_map(|l| {
                let f: Vec<&str> = l.split('\0').collect();
                (f.len() == 5).then(|| Branch {
                    name: f[0].into(),
                    oid: f[1].into(),
                    upstream: (!f[2].is_empty()).then(|| f[2].into()),
                    worktree: (!f[3].is_empty()).then(|| PathBuf::from(f[3])),
                    committed_unix: f[4].parse().unwrap_or(0),
                })
            })
            .collect())
    }

    /// Whether `oid` names a commit this repository has.
    pub fn commit_exists(&self, oid: &str) -> Result<bool, Error> {
        Ok(self.git().args(["cat-file", "-e", &format!("{oid}^{{commit}}")]).output()?.success())
    }

    /// The commit `refs/heads/<name>` points at.
    pub fn branch_tip(&self, name: &str) -> Result<Option<String>, Error> {
        let out = self.git().args(["rev-parse", "--verify", "--quiet", &format!("refs/heads/{name}^{{commit}}")]).output()?;
        Ok(out.success().then(|| out.text().trim().to_string()))
    }

    /// Whether another worktree of this repository has `name` checked out.
    pub fn branch_checked_out_elsewhere(&self, name: &str) -> Result<bool, Error> {
        let here = std::fs::canonicalize(&self.root).unwrap_or_else(|_| self.root.clone());
        Ok(self.worktrees()?.iter().any(|w| {
            w.branch.as_deref() == Some(name) && std::fs::canonicalize(&w.path).unwrap_or_else(|_| w.path.clone()) != here
        }))
    }

    /// A merge, rebase, cherry-pick, revert or bisect in progress here.
    pub fn operation(&self) -> Option<&'static str> {
        [
            ("MERGE_HEAD", "merge"),
            ("rebase-merge", "rebase"),
            ("rebase-apply", "rebase"),
            ("CHERRY_PICK_HEAD", "cherry-pick"),
            ("REVERT_HEAD", "revert"),
            ("BISECT_LOG", "bisect"),
        ]
        .into_iter()
        .find(|(f, _)| self.git_dir.join(f).exists())
        .map(|(_, op)| op)
    }

    pub fn create_branch(&self, name: &str, at: &str) -> Result<(), Error> {
        self.git().args(["branch", "--no-track", name, at]).ok()?;
        Ok(())
    }

    /// Points HEAD at `branch` (or, with `None`, detaches it at `commit`)
    /// and resets the index to it, leaving the working tree untouched: the
    /// caller owns the files. Logged in HEAD's reflog as a checkout.
    pub fn move_head(&self, branch: Option<&str>, commit: &str, reason: &str) -> Result<(), Error> {
        let msg = format!("checkout: {reason}");
        match branch {
            Some(b) => self.git().args(["symbolic-ref", "-m", &msg, "HEAD", &format!("refs/heads/{b}")]).ok()?,
            None => self.git().args(["update-ref", "--no-deref", "-m", &msg, "HEAD", commit]).ok()?,
        };
        self.git().args(["reset", "--quiet", "--mixed"]).ok()?;
        Ok(())
    }

    pub fn branch_exists(&self, name: &str) -> Result<bool, Error> {
        Ok(self.git().args(["show-ref", "--verify", "--quiet", &format!("refs/heads/{name}")]).output()?.success())
    }

    /// `prefix/slug`, suffixed with `-2`, `-3`... until no branch has it.
    pub fn unique_branch(&self, prefix: &str, title: &str) -> Result<String, Error> {
        let base = format!("{prefix}{}", slugify(title));
        let mut name = base.clone();
        let mut n = 2;
        while self.branch_exists(&name)? {
            name = format!("{base}-{n}");
            n += 1;
        }
        Ok(name)
    }

    pub fn status(&self) -> Result<Status, Error> {
        let out = self.git().args(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"]).ok()?;
        let mut st = Status::default();
        let mut fields = out.stdout.split(|b| *b == 0).map(|f| String::from_utf8_lossy(f).into_owned());
        while let Some(f) = fields.next() {
            if let Some(h) = f.strip_prefix("# branch.") {
                let (k, v) = h.split_once(' ').unwrap_or((h, ""));
                match k {
                    "oid" if v != "(initial)" => st.oid = Some(v.into()),
                    "head" if v != "(detached)" => st.branch = Some(v.into()),
                    "upstream" => st.upstream = Some(v.into()),
                    "ab" => {
                        for part in v.split_whitespace() {
                            if let Some(a) = part.strip_prefix('+') {
                                st.ahead = a.parse().unwrap_or(0);
                            } else if let Some(b) = part.strip_prefix('-') {
                                st.behind = b.parse().unwrap_or(0);
                            }
                        }
                    }
                    _ => {}
                }
                continue;
            }
            let kind = f.chars().next();
            match kind {
                Some('1') | Some('2') => {
                    let xy: Vec<char> = f.chars().skip(2).take(2).collect();
                    if xy.first().is_some_and(|c| *c != '.') {
                        st.staged += 1;
                    }
                    if xy.get(1).is_some_and(|c| *c != '.') {
                        st.unstaged += 1;
                    }
                    if kind == Some('2') {
                        fields.next(); // the rename's original path
                    }
                }
                Some('u') => st.conflicted += 1,
                Some('?') => st.untracked += 1,
                _ => {}
            }
        }
        Ok(st)
    }

    pub fn fetch(&self, remote: &str) -> Result<(), Error> {
        self.git().args(["fetch", "--prune", "--quiet", remote]).timeout(NETWORK_TIMEOUT).ok()?;
        Ok(())
    }

    pub fn push(&self, remote: &str, branch: &str, set_upstream: bool) -> Result<(), Error> {
        let mut c = self.git().arg("push").arg("--quiet");
        if set_upstream {
            c = c.arg("--set-upstream");
        }
        c.args([remote, branch]).timeout(NETWORK_TIMEOUT).ok()?;
        Ok(())
    }

    /// Switches this worktree to `branch` (creating it from `base` if given).
    pub fn switch(&self, branch: &str, create_from: Option<&str>) -> Result<(), Error> {
        let c = self.git().arg("switch").arg("--quiet");
        match create_from {
            Some(base) => c.args(["-c", branch, base]).ok()?,
            None => c.arg(branch).ok()?,
        };
        Ok(())
    }

    pub fn delete_branch(&self, name: &str, force: bool) -> Result<(), Error> {
        self.git().args(["branch", if force { "-D" } else { "-d" }, name]).ok()?;
        Ok(())
    }

    pub fn rename_branch(&self, from: &str, to: &str) -> Result<(), Error> {
        self.git().args(["branch", "-m", from, to]).ok()?;
        Ok(())
    }

    pub fn worktrees(&self) -> Result<Vec<Worktree>, Error> {
        let out = self.git().args(["worktree", "list", "--porcelain", "-z"]).ok()?;
        Ok(parse_worktrees(&out.stdout))
    }

    /// Adds a linked worktree at `path`.
    pub fn add_worktree(&self, path: &Path, checkout: &Checkout) -> Result<Worktree, Error> {
        let p = path.to_string_lossy().into_owned();
        let c = self.git().args(["worktree", "add", "--quiet"]);
        match checkout {
            Checkout::NewBranch { name, base } => c.args(["-b", name, &p, base]),
            Checkout::Branch(name) => c.args([&p, name]),
            Checkout::Detached(rev) => c.args(["--detach", &p, rev]),
        }
        .timeout(Duration::from_secs(300))
        .ok()?;
        let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        self.worktrees()?
            .into_iter()
            .find(|w| std::fs::canonicalize(&w.path).unwrap_or_else(|_| w.path.clone()) == canonical)
            .ok_or_else(|| Error::Invalid(format!("worktree {} missing after add", path.display())))
    }

    /// Removes a linked worktree. Without `force`, git refuses when it has
    /// uncommitted or untracked changes.
    pub fn remove_worktree(&self, path: &Path, force: bool) -> Result<(), Error> {
        let mut c = self.git().args(["worktree", "remove"]);
        if force {
            c = c.arg("--force");
        }
        c.arg(path.to_string_lossy()).ok()?;
        Ok(())
    }

    /// Forgets worktrees whose directories were deleted.
    pub fn prune_worktrees(&self) -> Result<(), Error> {
        self.git().args(["worktree", "prune"]).ok()?;
        Ok(())
    }
}

fn parse_worktrees(stdout: &[u8]) -> Vec<Worktree> {
    let mut out = Vec::new();
    let mut cur: Option<Worktree> = None;
    for field in stdout.split(|b| *b == 0) {
        let f = String::from_utf8_lossy(field);
        if f.is_empty() {
            out.extend(cur.take());
            continue;
        }
        let (k, v) = f.split_once(' ').unwrap_or((&f, ""));
        match k {
            "worktree" => {
                out.extend(cur.take());
                cur = Some(Worktree {
                    path: PathBuf::from(v),
                    oid: None,
                    branch: None,
                    detached: false,
                    bare: false,
                    locked: false,
                    prunable: false,
                });
            }
            _ => {
                let Some(w) = cur.as_mut() else { continue };
                match k {
                    "HEAD" => w.oid = Some(v.to_string()),
                    "branch" => w.branch = Some(v.strip_prefix("refs/heads/").unwrap_or(v).to_string()),
                    "detached" => w.detached = true,
                    "bare" => w.bare = true,
                    "locked" => w.locked = true,
                    "prunable" => w.prunable = true,
                    _ => {}
                }
            }
        }
    }
    out.extend(cur);
    out
}

/// A branch- and directory-safe slug: lowercase ASCII, digits and dashes.
pub fn slugify(title: &str) -> String {
    let mut s = String::new();
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            s.push(c.to_ascii_lowercase());
        } else if !s.ends_with('-') && !s.is_empty() {
            s.push('-');
        }
        if s.len() >= 48 {
            break;
        }
    }
    let s = s.trim_matches('-').to_string();
    if s.is_empty() { "work".into() } else { s }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_worktree_porcelain() {
        let raw = b"worktree /r\0HEAD abc\0branch refs/heads/main\0\0worktree /r-wt\0HEAD def\0detached\0locked\0\0worktree /gone\0HEAD 123\0branch refs/heads/x\0prunable gitdir file points to non-existent location\0\0";
        let w = parse_worktrees(raw);
        assert_eq!(w.len(), 3);
        assert_eq!(w[0].branch.as_deref(), Some("main"));
        assert!(w[1].detached && w[1].locked && w[1].branch.is_none());
        assert!(w[2].prunable);
    }

    #[test]
    fn slugs() {
        assert_eq!(slugify("Fix the login bug!"), "fix-the-login-bug");
        assert_eq!(slugify("   "), "work");
        assert_eq!(slugify("Ünïcödé — ok"), "n-c-d-ok");
    }
}
