//! Locating a checkout's git metadata. In linked worktrees (and submodules)
//! `.git` is a file pointing at a per-worktree git dir, which may live
//! outside the mount, and refs live in a shared common dir.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

pub(crate) struct GitDirs {
    /// Per-worktree state: `HEAD`, `index`, their locks.
    pub dir: PathBuf,
    /// Shared state: `refs/`, `packed-refs`, `info/`.
    pub common: PathBuf,
}

impl GitDirs {
    pub fn locate(root: &Path) -> Option<GitDirs> {
        let dot = root.join(".git");
        let dir = if dot.is_dir() {
            dot
        } else {
            let s = fs::read_to_string(&dot).ok()?;
            root.join(s.trim().strip_prefix("gitdir:")?.trim())
        };
        let dir = fs::canonicalize(dir).ok()?;
        let common = match fs::read_to_string(dir.join("commondir")) {
            Ok(c) => fs::canonicalize(dir.join(c.trim())).ok()?,
            Err(_) => dir.clone(),
        };
        Some(GitDirs { dir, common })
    }

    /// `ref@commit` for a symbolic HEAD, or the bare commit when detached.
    pub fn head(&self) -> Option<String> {
        let head = fs::read_to_string(self.dir.join("HEAD")).ok()?;
        let head = head.trim();
        let Some(reference) = head.strip_prefix("ref: ") else { return Some(head.to_string()) };
        let commit = fs::read_to_string(self.common.join(reference)).ok().map(|s| s.trim().to_string()).or_else(|| {
            fs::read_to_string(self.common.join("packed-refs"))
                .ok()?
                .lines()
                .find_map(|l| l.strip_suffix(reference).map(|c| c.trim().to_string()))
        });
        Some(format!("{reference}@{}", commit.unwrap_or_default()))
    }

    /// Whether git is mid-operation on this worktree.
    pub fn busy(&self) -> bool {
        ["index.lock", "HEAD.lock"].iter().any(|l| self.dir.join(l).exists())
    }

    /// A multi-step operation git has paused mid-way, typically on conflicts.
    pub fn operation(&self) -> Option<&'static str> {
        [
            ("MERGE_HEAD", "merge"),
            ("CHERRY_PICK_HEAD", "cherry-pick"),
            ("REVERT_HEAD", "revert"),
            ("rebase-merge", "rebase"),
            ("rebase-apply", "rebase"),
        ]
        .into_iter()
        .find(|(f, _)| self.dir.join(f).exists())
        .map(|(_, name)| name)
    }

    /// Cheap change detector for the index.
    pub fn index_stamp(&self) -> Option<(SystemTime, u64)> {
        let m = fs::metadata(self.dir.join("index")).ok()?;
        Some((m.modified().ok()?, m.len()))
    }

    /// Length of HEAD's reflog; new entries are appended past it.
    pub fn reflog_len(&self) -> u64 {
        fs::metadata(self.reflog()).map(|m| m.len()).unwrap_or(0)
    }

    /// Actions (`checkout`, `commit (amend)`, `pull`, ...) logged for HEAD
    /// after byte `from`. `None` when the reflog is missing or was rewritten.
    pub fn reflog_actions(&self, from: u64) -> Option<Vec<String>> {
        let bytes = fs::read(self.reflog()).ok()?;
        let tail = bytes.get(from as usize..)?;
        Some(
            String::from_utf8_lossy(tail)
                .lines()
                .filter_map(|l| Some(l.split_once('\t')?.1.split(':').next()?.trim().to_string()))
                .collect(),
        )
    }

    fn reflog(&self) -> PathBuf {
        self.dir.join("logs").join("HEAD")
    }

    pub fn exclude(&self) -> PathBuf {
        self.common.join("info").join("exclude")
    }

    /// Whether a change at `path` can mean HEAD or the branch it names moved.
    pub fn signals(&self, path: &Path) -> bool {
        path.parent() == Some(&self.dir)
            && matches!(path.file_name().and_then(|n| n.to_str()), Some("HEAD" | "HEAD.lock" | "index.lock"))
            || path == self.common.join("packed-refs")
            || path.starts_with(self.common.join("refs"))
    }

    /// Directories outside `root` that must be watched to see HEAD move.
    pub fn external_watches(&self, root: &Path) -> Vec<(PathBuf, bool)> {
        let mut out = Vec::new();
        if !self.dir.starts_with(root) {
            out.push((self.dir.clone(), false));
        }
        if !self.common.starts_with(root) {
            out.push((self.common.clone(), false));
            out.push((self.common.join("refs"), true));
        }
        out
    }
}

/// Index entries per path (`mode oid stage`, several when unmerged).
pub(crate) type Index = HashMap<String, Vec<String>>;

fn git(root: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let out = Command::new("git").args(args).current_dir(root).output().ok()?;
    out.status.success().then_some(out.stdout)
}

fn nul_split(bytes: &[u8]) -> impl Iterator<Item = String> + '_ {
    bytes.split(|b| *b == 0).filter(|p| !p.is_empty()).map(|p| String::from_utf8_lossy(p).into_owned())
}

pub(crate) fn read_index(root: &Path) -> Option<Index> {
    let mut index = Index::new();
    for line in nul_split(&git(root, &["ls-files", "-s", "-z"])?) {
        let (entry, path) = line.split_once('\t')?;
        index.entry(path.to_string()).or_default().push(entry.to_string());
    }
    Some(index)
}

/// Tracked paths whose working file differs from the index (including
/// unmerged ones). The index's stat cache is fresh for anything git just
/// wrote, so this is cheap and exact for the files that matter here.
pub(crate) fn dirty_paths(root: &Path) -> Option<HashSet<String>> {
    Some(nul_split(&git(root, &["diff-files", "--name-only", "-z"])?).collect())
}

pub(crate) fn unmerged(entries: &[String]) -> bool {
    entries.iter().any(|e| !e.ends_with(" 0"))
}

/// Paths that differ between two `ref@commit` heads, per git.
pub(crate) fn changed_between(root: &Path, from: Option<&str>, to: Option<&str>) -> Option<Vec<String>> {
    let commit = |h: &str| h.rsplit('@').next().unwrap_or(h).to_string();
    let (from, to) = (commit(from?), commit(to?));
    Some(nul_split(&git(root, &["diff", "--name-only", "--no-renames", "-z", &from, &to])?).collect())
}

/// The bytes and exec bit git writes to the worktree for an index entry
/// (`mode oid stage`), with smudge filters and line-ending conversion
/// applied. `None` for anything but regular files.
pub(crate) fn checked_out(root: &Path, path: &str, entry: &str) -> Option<(Vec<u8>, bool)> {
    let mut parts = entry.split(' ');
    let (mode, oid) = (parts.next()?, parts.next()?);
    let exec = match mode {
        "100644" => false,
        "100755" => true,
        _ => return None,
    };
    Some((git(root, &["cat-file", "--filters", &format!("--path={path}"), oid])?, exec))
}
