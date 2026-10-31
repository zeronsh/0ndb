//! Locating a checkout's git metadata. In linked worktrees (and submodules)
//! `.git` is a file pointing at a per-worktree git dir, which may live
//! outside the mount, and refs live in a shared common dir.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

/// The repository's object database as content 0ndb references instead of
/// copying (see `Workspace::set_objects`).
pub(crate) struct GitObjects(pub ondb_git::Objects);

impl ondb_core::ObjectStore for GitObjects {
    fn contains(&self, oid: &ondb_core::Oid) -> bool {
        self.0.contains(&oid.0)
    }
    fn read(&self, oid: &ondb_core::Oid) -> Option<Vec<u8>> {
        self.0.read(&oid.0)
    }
    fn pin(&self, oids: &[ondb_core::Oid]) -> bool {
        self.0.pin(&oids.iter().map(|o| o.0).collect::<Vec<_>>())
    }
    fn release(&self) {
        self.0.release()
    }
}

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

/// One index entry, as stored.
pub(crate) struct RawEntry {
    pub path: Vec<u8>,
    pub mode: u32,
    pub oid: [u8; 20],
    pub stage: u16,
}

/// The index's entries, parsed from git's index file directly (no process
/// per change: editors refresh it constantly), else via `git ls-files`.
pub(crate) fn read_index_raw(root: &Path, dirs: Option<&GitDirs>) -> Option<Vec<RawEntry>> {
    if let Some(entries) = dirs.and_then(|d| fs::read(d.dir.join("index")).ok()).and_then(|b| parse_index(&b)) {
        return Some(entries);
    }
    let mut out = Vec::new();
    for line in nul_split(&git(root, &["ls-files", "-s", "-z"])?) {
        let (entry, path) = line.split_once('\t')?;
        let mut parts = entry.split(' ');
        let mode = u32::from_str_radix(parts.next()?, 8).ok()?;
        let hex = parts.next()?;
        let stage = parts.next()?.parse().ok()?;
        let mut oid = [0u8; 20];
        for (k, o) in oid.iter_mut().enumerate() {
            *o = u8::from_str_radix(hex.get(k * 2..k * 2 + 2)?, 16).ok()?;
        }
        out.push(RawEntry { path: path.as_bytes().to_vec(), mode, oid, stage });
    }
    Some(out)
}

/// The index as `ls-files -s` prints it, per path.
pub(crate) fn index_of(raw: &[RawEntry]) -> Index {
    let mut index = Index::with_capacity(raw.len());
    for e in raw {
        let hex: String = e.oid.iter().map(|x| format!("{x:02x}")).collect();
        index.entry(String::from_utf8_lossy(&e.path).into_owned()).or_default().push(format!("{:06o} {hex} {}", e.mode, e.stage));
    }
    index
}

/// Parses a git index file (versions 2-4, SHA-1). `None` for anything it
/// doesn't fully understand (split or sparse indexes, other hashes,
/// corruption), so the caller asks git instead.
pub(crate) fn parse_index(b: &[u8]) -> Option<Vec<RawEntry>> {
    const OID: usize = 20;
    let u32_at = |i: usize| -> Option<u32> { Some(u32::from_be_bytes(b.get(i..i + 4)?.try_into().ok()?)) };
    if b.get(0..4)? != b"DIRC" || b.len() < 12 + OID {
        return None;
    }
    let version = u32_at(4)?;
    if !(2..=4).contains(&version) {
        return None;
    }
    // The trailing checksum covers everything before it; a mismatch means
    // corruption or another hash (SHA-256 repositories). All zeros means
    // git skipped it (`index.skipHash`).
    {
        use sha1::Digest;
        let (body, sum) = b.split_at(b.len() - OID);
        if sum.iter().any(|x| *x != 0) && sha1::Sha1::digest(body).as_slice() != sum {
            return None;
        }
    }
    let count = u32_at(8)? as usize;
    let mut out: Vec<RawEntry> = Vec::with_capacity(count);
    let mut pos = 12;
    for _ in 0..count {
        let start = pos;
        let mode = u32_at(pos + 24)?;
        let oid: [u8; 20] = b.get(pos + 40..pos + 40 + OID)?.try_into().ok()?;
        let flags = u16::from_be_bytes(b.get(pos + 60..pos + 62)?.try_into().ok()?);
        pos += 62;
        if version >= 3 && flags & 0x4000 != 0 {
            pos += 2;
        }
        let stage = (flags >> 12) & 3;
        let path = if version == 4 {
            // Prefix-compressed: drop N bytes of the previous path, append.
            let mut byte = *b.get(pos)?;
            pos += 1;
            let mut strip = (byte & 0x7f) as usize;
            while byte & 0x80 != 0 {
                byte = *b.get(pos)?;
                pos += 1;
                strip = ((strip + 1) << 7) | (byte & 0x7f) as usize;
            }
            let end = pos + b.get(pos..)?.iter().position(|c| *c == 0)?;
            let prev: &[u8] = out.last().map_or(&[], |e| &e.path);
            let mut path = prev.get(..prev.len().checked_sub(strip)?)?.to_vec();
            path.extend_from_slice(&b[pos..end]);
            pos = end + 1;
            path
        } else {
            let end = pos + b.get(pos..)?.iter().position(|c| *c == 0)?;
            let path = b[pos..end].to_vec();
            // NUL padding to a multiple of 8 bytes from the entry's start.
            pos = start + (end - start + 8) / 8 * 8;
            path
        };
        out.push(RawEntry { path, mode, oid, stage });
    }
    // Extensions: split (`link`) and sparse (`sdir`) indexes hold entries
    // elsewhere, so only git can list them.
    while pos + 8 <= b.len() - OID {
        let sig = b.get(pos..pos + 4)?;
        if sig == b"link" || sig == b"sdir" {
            return None;
        }
        pos += 8 + u32_at(pos + 4)? as usize;
    }
    Some(out)
}

/// Tracked paths whose working file differs from the index (including
/// unmerged ones). The index's stat cache is fresh for anything git just
/// wrote, so this is cheap and exact for the files that matter here.
/// Limited to `only` when that's a handful of paths, so a checkout touching
/// a few files doesn't stat the whole tree again (git matches pathspecs per
/// path, so long lists are slower than a full pass).
pub(crate) fn dirty_paths(root: &Path, only: Option<&BTreeSet<String>>) -> Option<HashSet<String>> {
    let mut args: Vec<String> = ["diff-files", "--name-only", "-z"].map(String::from).to_vec();
    if let Some(only) = only.filter(|o| o.len() <= 64) {
        if only.is_empty() {
            return Some(HashSet::new());
        }
        args.push("--".into());
        args.extend(only.iter().map(|p| format!(":(literal){p}")));
    }
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    Some(nul_split(&git(root, &args)?).collect())
}

pub(crate) fn unmerged(entries: &[String]) -> bool {
    entries.iter().any(|e| !e.ends_with(" 0"))
}

/// The index reduced to what change detection needs, about 20 bytes per
/// path: path hash -> hash of its entries, low bit set when unmerged.
pub(crate) type CompactIndex = HashMap<u64, u64>;

pub(crate) fn path_hash(path: &str) -> u64 {
    let mut h = DefaultHasher::new();
    path.hash(&mut h);
    h.finish()
}

pub(crate) fn compact(raw: &[RawEntry]) -> CompactIndex {
    let mut out = CompactIndex::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        // A path's entries (one per stage) are adjacent.
        let path = &raw[i].path;
        let mut h = DefaultHasher::new();
        let mut unmerged = false;
        while i < raw.len() && raw[i].path == *path {
            (raw[i].mode, raw[i].oid, raw[i].stage).hash(&mut h);
            unmerged |= raw[i].stage != 0;
            i += 1;
        }
        let key = match std::str::from_utf8(path) {
            Ok(p) => path_hash(p),
            Err(_) => path_hash(&String::from_utf8_lossy(path)),
        };
        out.insert(key, (h.finish() & !1) | unmerged as u64);
    }
    out
}

pub(crate) fn compact_unmerged(entry: u64) -> bool {
    entry & 1 == 1
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

#[cfg(test)]
mod tests {
    use super::*;

    fn ls_files(root: &Path) -> Index {
        let mut index = Index::new();
        for line in nul_split(&git(root, &["ls-files", "-s", "-z"]).unwrap()) {
            let (entry, path) = line.split_once('\t').unwrap();
            index.entry(path.to_string()).or_default().push(entry.to_string());
        }
        index
    }

    fn sh(dir: &Path, script: &str) {
        assert!(Command::new("sh").arg("-c").arg(script).current_dir(dir).status().unwrap().success(), "{script}");
    }

    #[test]
    fn parsed_index_matches_git_for_every_version_and_conflicts() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let git = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main";
        sh(
            root,
            &format!(
                "{git} init -q && mkdir -p a/deep/er && echo 1 > a/deep/er/x && echo 2 > a/deep/y && printf 'x' > 'sp ace' && ln -s a link && echo e > exe && chmod +x exe && {git} add -A && {git} commit -qm base"
            ),
        );
        sh(
            root,
            &format!(
                "{git} switch -qc other && echo other > a/deep/y && {git} commit -qam o && {git} switch -q main && echo main > a/deep/y && {git} commit -qam m && ({git} merge -q other >/dev/null 2>&1; true)"
            ),
        );
        let dirs = GitDirs::locate(root).unwrap();
        for version in ["2", "3", "4", "2"] {
            sh(
                root,
                &format!(
                    "git update-index --index-version {version} && git update-index --add --intent-to-add -- 'sp ace' 2>/dev/null; true"
                ),
            );
            let parsed = index_of(&parse_index(&fs::read(dirs.dir.join("index")).unwrap()).expect("parsed"));
            assert_eq!(parsed, ls_files(root), "index version {version}");
            assert!(parsed["a/deep/y"].len() == 3, "conflict stages are kept");
        }
        sh(
            root,
            "git -c index.skipHash=true update-index --index-version 4 && git -c index.skipHash=true update-index --refresh >/dev/null; true",
        );
        assert_eq!(index_of(&read_index_raw(root, Some(&dirs)).unwrap()), ls_files(root));
    }
}
