use std::collections::{BTreeMap, BTreeSet, HashMap};

use ondb_core::diff::line_splices;
use ondb_core::{
    ActorId, BatchId, Blob, BlobRef, Content, FileMode, FileState, History, ImportEntry, ImportNode, ImportParent, InodeId,
    LineEnding, NodeKind, Op, Txn, Version,
};

use super::MountState;
use super::disk::{
    self, Classified, DiskEntry, Stat, abs, classify, is_under, join, name_of, oid_of, parent_of, probe, symlink_oid,
};
use super::git;
use super::ignore::walker;
use super::shadow::{Entry, Kind, Shadow};
use crate::Error;

/// Content held in memory per adoption batch.
const ADOPT_CHUNK_BYTES: usize = 32 << 20;

pub enum Scope {
    Full,
    Paths(BTreeSet<String>),
}

enum Found {
    Dir,
    /// `oid` is the blob id of `bytes`, computed once when read.
    File {
        bytes: Vec<u8>,
        oid: ondb_core::Oid,
        exec: bool,
        stat: Stat,
    },
    Symlink {
        target: String,
    },
}

/// Threads walking a tree for a full pass.
const WALK_THREADS: usize = 6;

/// Paths probed per window; their files are then read and hashed in parallel.
const WINDOW_PATHS: usize = 2048;
/// Upper bound on the bytes a window reads at once.
const WINDOW_BYTES: i64 = 32 << 20;

type Read = std::io::Result<Option<(Vec<u8>, ondb_core::Oid)>>;

/// `lstat`s `paths` across a few threads.
fn probe_parallel(root: &std::path::Path, paths: &[String]) -> Vec<DiskEntry> {
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(8);
    if paths.len() < 256 || threads == 1 {
        return paths.iter().map(|p| probe(root, p)).collect();
    }
    let per = paths.len().div_ceil(threads);
    std::thread::scope(|s| {
        let parts: Vec<_> =
            paths.chunks(per).map(|c| s.spawn(move || c.iter().map(|p| probe(root, p)).collect::<Vec<_>>())).collect();
        parts.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
    })
}

fn with_oid(bytes: Vec<u8>) -> (Vec<u8>, ondb_core::Oid) {
    let oid = oid_of(&bytes);
    (bytes, oid)
}

/// Reads and hashes `paths` across a few threads (file reads and hashing
/// dominate adopting and rescanning large trees).
fn read_parallel(root: &std::path::Path, paths: &[&str], max: u64) -> Vec<Read> {
    let read = |p: &str| -> Read { Ok(disk::read_limited(root, p, max)?.map(with_oid)) };
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(8);
    if paths.len() < 16 || threads == 1 {
        return paths.iter().map(|p| read(p)).collect();
    }
    let per = paths.len().div_ceil(threads);
    std::thread::scope(|s| {
        let parts: Vec<_> = paths.chunks(per).map(|c| s.spawn(move || c.iter().map(|p| read(p)).collect::<Vec<_>>())).collect();
        parts.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
    })
}

/// Whether git wrote a path in the current window.
enum Verdict {
    Git,
    Edit,
    /// Git wrote these bytes (and exec bit), then someone edited them.
    Split(Vec<u8>, bool),
}

enum Change {
    Edit { bytes: Vec<u8>, exec: bool, stat: Stat },
    Exec { exec: bool, stat: Stat },
    Link { target: String },
}

enum Update {
    Insert(String, Entry),
    Remove(String),
    RenameTree(String, String),
}

fn mode(exec: bool) -> FileMode {
    if exec { FileMode::Executable } else { FileMode::Regular }
}

/// Whether the repository's object database holds a blob (see
/// `Workspace::set_objects`); such content is referenced, never copied.
type Held<'a> = &'a dyn Fn(&ondb_core::Oid) -> bool;

/// Content op payload for freshly read bytes, plus the blob to attach.
/// `oid` is the blob id of `bytes`.
fn content_of(bytes: &[u8], oid: ondb_core::Oid, held: Held<'_>) -> (Content, LineEnding, Option<Blob>) {
    match classify(bytes) {
        Classified::Text { clean, ending } => {
            // Normalizing only ever drops bytes; same length, same bytes.
            let same = clean.len() == bytes.len();
            // Small text git already holds is referenced like a large file,
            // so adopting a checkout copies nothing git has.
            if !clean.is_empty() && clean.len() <= ondb_core::INLINE_TEXT_MAX {
                let oid = if same { oid } else { oid_of(&clean) };
                if held(&oid) {
                    return (
                        Content::TextBlob(BlobRef { oid, len: clean.len() as u64 }),
                        ending,
                        Some(Blob { oid, data: clean }),
                    );
                }
            }
            let (content, blob) = Content::text_hashed(clean, same.then_some(oid));
            (content, ending, blob)
        }
        Classified::Binary => {
            (Content::Binary(BlobRef { oid, len: bytes.len() as u64 }), LineEnding::Lf, Some(Blob { oid, data: bytes.to_vec() }))
        }
    }
}

/// Ops that turn `inode`'s state (as seen by the txn) into `bytes`.
fn edit_ops(txn: &Txn<'_>, inode: InodeId, bytes: &[u8], exec: Option<bool>) -> (Vec<Op>, Option<Blob>) {
    let state = {
        let view = txn.view();
        txn.history().file_state(&view, &inode)
    };
    let mut ops = Vec::new();
    let mut blob = None;
    let current_mode = match &state {
        Some(FileState::Text { mode, .. } | FileState::Binary { mode, .. }) => *mode,
        None => FileMode::Regular,
    };
    match (classify(bytes), state) {
        (Classified::Text { clean, ending }, Some(FileState::Text { bytes: old, ending: old_ending, .. })) => {
            let (text, splices) = line_splices(&old, &clean);
            if !splices.is_empty() {
                ops.push(Op::EditText { inode, text, splices });
            }
            if ending != old_ending {
                ops.push(Op::SetLineEnding { inode, ending });
            }
        }
        (Classified::Text { clean, ending }, _) => {
            let (content, b) = Content::text(clean);
            blob = b;
            ops.push(Op::SetContent { inode, content });
            ops.push(Op::SetLineEnding { inode, ending });
        }
        (Classified::Binary, Some(FileState::Binary { blob: b, .. })) if b.oid == oid_of(bytes) => {}
        (Classified::Binary, _) => {
            let (content, _, b) = content_of(bytes, oid_of(bytes), &|_| false);
            ops.push(Op::SetContent { inode, content });
            blob = b;
        }
    }
    if let Some(exec) = exec
        && mode(exec) != current_mode
    {
        ops.push(Op::SetMode { inode, mode: mode(exec) });
    }
    (ops, blob)
}

/// Shadow entry for an inode as materialized at `view`.
pub(super) fn shadow_entry_for(h: &History, view: &dyn ondb_core::View, inode: InodeId) -> Option<Entry> {
    let node = h.inode(&inode)?;
    Some(match &node.kind {
        NodeKind::Dir => Entry { inode, kind: Kind::Dir, oid: None, exec: false, stat: None },
        NodeKind::Symlink { .. } => {
            let target = h.symlink_target(view, &inode)?;
            Entry { inode, kind: Kind::Symlink, oid: Some(symlink_oid(&target)), exec: false, stat: None }
        }
        NodeKind::File(_) => match h.file_state(view, &inode)? {
            FileState::Text { bytes, ending, mode } => Entry {
                inode,
                kind: Kind::File,
                oid: Some(oid_of(&disk::smudge(&bytes, ending))),
                exec: mode == FileMode::Executable,
                stat: None,
            },
            FileState::Binary { blob, mode } => {
                Entry { inode, kind: Kind::File, oid: Some(blob.oid), exec: mode == FileMode::Executable, stat: None }
            }
        },
    })
}

impl MountState {
    /// First mount of a directory: pair what's on disk with what the history
    /// already holds so neither side is mistaken for a deletion.
    pub(super) fn adopt(&mut self) -> Result<(), Error> {
        let root = self.root.clone();
        let synced = self.record.synced_version.clone();
        let mut paths = Vec::new();
        for e in walker(&root).build().flatten() {
            if let Ok(rel) = e.path().strip_prefix(&root) {
                let rel = rel.to_string_lossy().into_owned();
                if !rel.is_empty() {
                    paths.push(rel);
                }
            }
        }
        let entries: Vec<(String, Entry)> = self.ws.read(|h| {
            let ex = h.exclusions_for(&synced);
            let view = h.excluding(&ex);
            paths.iter().filter_map(|p| Some((p.clone(), shadow_entry_for(h, &view, h.tree().lookup(&view, p)?)?))).collect()
        });
        for (path, mut entry) in entries {
            let matches_kind = matches!(
                (probe(&root, &path), entry.kind),
                (DiskEntry::Dir, Kind::Dir) | (DiskEntry::File { .. }, Kind::File) | (DiskEntry::Symlink { .. }, Kind::Symlink)
            );
            if matches_kind {
                // Unknown stat forces a content comparison on the first pass.
                entry.stat = None;
                self.shadow.insert(path, entry);
            }
        }
        Ok(())
    }

    /// Drops cached entries whose inodes the history doesn't know (e.g. the
    /// store was rebuilt), so they're treated as new rather than corrupting.
    pub(super) fn validate_shadow(&mut self) {
        let stale: Vec<String> = self
            .ws
            .read(|h| self.shadow.paths().filter(|p| h.inode(&self.shadow.get(p).unwrap().inode).is_none()).cloned().collect());
        for p in stale {
            self.shadow.remove(&p);
        }
    }

    fn candidates(&self, scope: Scope) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        // Walked in parallel: on large trees the walk is a pass's largest
        // fixed cost.
        let walk_into = |dir: &str, out: &mut BTreeSet<String>| {
            let found = std::sync::Mutex::new(Vec::new());
            walker(&abs(&self.root, dir)).threads(WALK_THREADS).build_parallel().run(|| {
                let found = &found;
                let root = &self.root;
                Box::new(move |e| {
                    if let Ok(e) = e
                        && let Ok(rel) = e.path().strip_prefix(root)
                    {
                        found.lock().unwrap_or_else(|p| p.into_inner()).push(rel.to_string_lossy().into_owned());
                    }
                    ignore::WalkState::Continue
                })
            });
            out.extend(found.into_inner().unwrap_or_else(|p| p.into_inner()));
        };
        match scope {
            Scope::Full => {
                out.extend(self.shadow.paths().cloned());
                walk_into("", &mut out);
            }
            Scope::Paths(paths) => {
                for p in paths {
                    if p.is_empty() || disk::is_internal(&p) {
                        continue;
                    }
                    if matches!(probe(&self.root, &p), DiskEntry::Dir) {
                        walk_into(&p, &mut out);
                    }
                    out.extend(self.shadow.under(&p));
                    out.insert(p);
                }
            }
        }
        // New entries need their (possibly also new) parent directories.
        let extra: Vec<String> = out
            .iter()
            .flat_map(|p| {
                let mut ancestors = Vec::new();
                let mut cur = parent_of(p);
                while !cur.is_empty() && self.shadow.get(cur).is_none() {
                    ancestors.push(cur.to_string());
                    cur = parent_of(cur);
                }
                ancestors
            })
            .collect();
        out.extend(extra);
        out.remove("");
        out
    }

    /// Compares disk with the shadow for `scope` and records the difference
    /// as one batch by the ingestion actor, parented on the synced version.
    pub(super) fn reconcile(&mut self, scope: Scope) -> Result<Option<BatchId>, Error> {
        let out = self.reconcile_pass(scope)?;
        // Content referenced in git's objects is pinned in bulk, once per
        // pass rather than once per batch.
        if self.objects.is_some() {
            let t = std::time::Instant::now();
            self.ws.flush_pins()?;
            crate::timing::add("flush_pins", t.elapsed());
        }
        Ok(out)
    }

    fn reconcile_pass(&mut self, scope: Scope) -> Result<Option<BatchId>, Error> {
        self.wake()?;
        let git_busy = self.settle_git();
        if let Scope::Paths(p) = &scope
            && p.iter().any(|p| name_of(p) == ".gitignore")
        {
            self.ignore = super::Ignore::load(&self.root, self.git.as_ref());
            self.ignore_changed = true;
        }
        // Did git write files in this window? A HEAD move whose new reflog
        // entries are all commits didn't (the files being committed are
        // someone's edits); any other HEAD move (checkout, pull, reset,
        // rebase, merge) did, as does a paused merge/cherry-pick/revert/
        // rebase that rewrote the index. Git's writes are captured in one
        // full pass (no young-file deferral) so they land in one batch
        // marked as git's, never split into pieces that look like edits.
        let head = self.read_git_head();
        let head_moved = head != self.git_head;
        let (operation, git_wrote) = match &self.git {
            None => (None, false),
            Some(g) => {
                let commits_only =
                    g.reflog_actions(self.reflog_pos).is_some_and(|a| !a.is_empty() && a.iter().all(|x| x.starts_with("commit")));
                let operation = g.operation();
                let index_moved = g.index_stamp() != self.index_stamp;
                (operation, (head_moved && !commits_only) || (operation.is_some() && index_moved))
            }
        };
        let scope = if git_wrote { Scope::Full } else { scope };
        let defer_young = self.settling && !git_wrote;
        let t = std::time::Instant::now();
        let cands = self.candidates(scope);
        crate::timing::add("candidates", t.elapsed());
        let root = self.root.clone();

        let mut created: BTreeMap<String, Found> = BTreeMap::new();
        let mut removed: BTreeMap<String, Entry> = BTreeMap::new();
        let mut changed: BTreeMap<String, (Entry, Change)> = BTreeMap::new();
        let mut stat_only: Vec<(String, Stat)> = Vec::new();
        let young_before = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default()
            - self.opts.settle)
            .as_nanos() as i64;
        // Adopting a directory reads every file; commit in bounded chunks so
        // a large repository never has to fit in memory at once. Paths come
        // in order, so each chunk's directories exist before the next.
        let adopting = self.shadow.is_empty() && !git_wrote;
        let t_scan = std::time::Instant::now();
        let mut chunk_bytes = 0usize;
        let cands: Vec<String> = cands.into_iter().collect();
        let max = self.opts.max_file_size;
        let mut start = 0;
        while start < cands.len() {
            // Probe a window, then read and hash the files it needs in parallel.
            let ahead = &cands[start..(start + WINDOW_PATHS).min(cands.len())];
            let mut probed = probe_parallel(&root, ahead).into_iter();
            let mut probes = Vec::new();
            let (mut wanted, mut want_bytes) = (Vec::new(), 0i64);
            while start + probes.len() < cands.len() && probes.len() < WINDOW_PATHS && want_bytes < WINDOW_BYTES {
                let path = &cands[start + probes.len()];
                let d = probed.next().unwrap_or_else(|| probe(&root, path));
                if let DiskEntry::File { stat, exec } = &d
                    && !(defer_young && stat.mtime_ns > young_before)
                    && match self.shadow.get(path) {
                        None => !self.ignore.is_ignored(path, false),
                        Some(s) => s.kind != Kind::File || s.stat != Some(*stat) || s.exec != *exec,
                    }
                {
                    wanted.push(path.as_str());
                    want_bytes += stat.size;
                }
                probes.push(d);
            }
            let t_read = std::time::Instant::now();
            let mut reads: HashMap<&str, Read> = wanted.iter().copied().zip(read_parallel(&root, &wanted, max)).collect();
            crate::timing::add("read", t_read.elapsed());
            let window = &cands[start..start + probes.len()];
            start += probes.len();
            for (path, disk_entry) in window.iter().zip(probes) {
                let mut read = |p: &str| reads.remove(p).unwrap_or_else(|| Ok(disk::read_limited(&root, p, max)?.map(with_oid)));
                if adopting && chunk_bytes >= ADOPT_CHUNK_BYTES {
                    self.commit_pass(std::mem::take(&mut created), BTreeMap::new(), BTreeMap::new(), None, git_busy)?;
                    chunk_bytes = 0;
                }
                if defer_young
                    && let DiskEntry::File { stat, .. } = &disk_entry
                    && stat.mtime_ns > young_before
                {
                    self.deferred.insert(path.clone());
                    continue;
                }
                let shadow = self.shadow.get(path).cloned();
                let parent_ok = |created: &BTreeMap<String, Found>| {
                    let p = parent_of(path);
                    p.is_empty() || self.shadow.is_dir(p) || matches!(created.get(p), Some(Found::Dir))
                };
                match (shadow, disk_entry) {
                    (None, DiskEntry::Missing | DiskEntry::Other) => {}
                    (None, d) => {
                        if self.ignore.is_ignored(path, d == DiskEntry::Dir) || !parent_ok(&created) {
                            continue;
                        }
                        match d {
                            DiskEntry::Dir => {
                                created.insert(path.clone(), Found::Dir);
                            }
                            DiskEntry::File { stat, exec } => match read(path) {
                                Ok(Some((bytes, oid))) => {
                                    chunk_bytes += bytes.len();
                                    created.insert(path.clone(), Found::File { bytes, oid, exec, stat });
                                }
                                Ok(None) => tracing::warn!(path, "file exceeds the size limit; not tracked"),
                                Err(e) => tracing::warn!(path, error = %e, "unreadable file skipped"),
                            },
                            DiskEntry::Symlink { target } => {
                                created.insert(path.clone(), Found::Symlink { target });
                            }
                            DiskEntry::Missing | DiskEntry::Other => {}
                        }
                    }
                    (Some(s), DiskEntry::Missing | DiskEntry::Other) => {
                        removed.insert(path.clone(), s);
                    }
                    (Some(s), DiskEntry::Dir) if s.kind == Kind::Dir => {}
                    (Some(s), DiskEntry::File { stat, exec }) if s.kind == Kind::File => {
                        if s.stat == Some(stat) && s.exec == exec {
                            continue;
                        }
                        match read(path) {
                            Ok(Some((bytes, oid))) => {
                                if s.oid == Some(oid) {
                                    if s.exec == exec {
                                        stat_only.push((path.clone(), stat));
                                    } else {
                                        changed.insert(path.clone(), (s, Change::Exec { exec, stat }));
                                    }
                                } else {
                                    changed.insert(path.clone(), (s, Change::Edit { bytes, exec, stat }));
                                }
                            }
                            Ok(None) => tracing::warn!(path, "file grew past the size limit; changes not tracked"),
                            Err(e) => tracing::warn!(path, error = %e, "unreadable file skipped"),
                        }
                    }
                    (Some(s), DiskEntry::Symlink { target }) if s.kind == Kind::Symlink => {
                        if s.oid != Some(symlink_oid(&target)) {
                            changed.insert(path.clone(), (s, Change::Link { target }));
                        }
                    }
                    (Some(s), d) => {
                        // Kind changed (file <-> dir <-> symlink): replace.
                        removed.insert(path.clone(), s);
                        match d {
                            DiskEntry::Dir => {
                                created.insert(path.clone(), Found::Dir);
                            }
                            DiskEntry::File { stat, exec } => {
                                if let Ok(Some((bytes, oid))) = read(path) {
                                    created.insert(path.clone(), Found::File { bytes, oid, exec, stat });
                                }
                            }
                            DiskEntry::Symlink { target } => {
                                created.insert(path.clone(), Found::Symlink { target });
                            }
                            DiskEntry::Missing | DiskEntry::Other => {}
                        }
                    }
                }
            }
        }
        for (path, stat) in stat_only {
            self.shadow.set_stat(&path, Some(stat));
        }
        crate::timing::add("scan", t_scan.elapsed());

        if !git_wrote {
            // A commit moved HEAD without writing files: note it on its own.
            let marker = head.clone().filter(|_| head_moved).map(|to| Op::GitCheckout { from: self.git_head.clone(), to });
            self.git_head = head;
            self.snapshot_git();
            let edits = self.commit_pass(created, removed, changed, None, git_busy)?;
            let moved = match marker {
                Some(m) => self.commit_pass(BTreeMap::new(), BTreeMap::new(), BTreeMap::new(), Some(m), git_busy)?,
                None => None,
            };
            return Ok(moved.or(edits));
        }
        // Which paths did git write? Those whose index entry changed in this
        // window (except conflicts being resolved, which are someone's work).
        // With no baseline index (first pass after remounting), those git's
        // diff between the two commits names. A written file that no longer
        // matches its index entry was edited right after: git's version and
        // the edit are recorded separately. Without git's view at all,
        // everything is git's.
        let t = std::time::Instant::now();
        let raw = git::read_index_raw(&root, self.git.as_ref());
        let new_index = raw.as_deref().map(git::index_of);
        crate::timing::add("git.read_index", t.elapsed());
        let new_compact = raw.as_deref().map(git::compact);
        let written: Option<BTreeSet<String>> = match (&self.git_index, &new_compact) {
            (Some(old), Some(new)) => Some(
                created
                    .keys()
                    .chain(removed.keys())
                    .chain(changed.keys())
                    .filter(|p| {
                        let h = git::path_hash(p);
                        let before = old.get(&h);
                        before != new.get(&h) && !before.is_some_and(|e| git::compact_unmerged(*e))
                    })
                    .cloned()
                    .collect(),
            ),
            _ => git::changed_between(&root, self.git_head.as_deref(), head.as_deref()).map(|v| v.into_iter().collect()),
        };
        // Only written paths are ever checked against the worktree.
        let t = std::time::Instant::now();
        let dirty = git::dirty_paths(&root, written.as_ref());
        crate::timing::add("git.dirty_paths", t.elapsed());
        let verdict = |p: &String, dir: bool| -> Verdict {
            let Some(w) = &written else { return Verdict::Git };
            if dir {
                let under = w.range(format!("{p}/")..).next().is_some_and(|q| is_under(q, p));
                return if under { Verdict::Git } else { Verdict::Edit };
            }
            if !w.contains(p) {
                return Verdict::Edit;
            }
            let entry = new_index.as_ref().and_then(|n| n.get(p));
            if entry.is_some_and(|e| git::unmerged(e)) || dirty.as_ref().is_none_or(|d| !d.contains(p)) {
                return Verdict::Git;
            }
            match entry.and_then(|e| git::checked_out(&root, p, &e[0])) {
                Some((bytes, exec)) => Verdict::Split(bytes, exec),
                None => Verdict::Edit,
            }
        };
        let (mut co_created, mut co_removed, mut co_changed) = (BTreeMap::new(), BTreeMap::new(), BTreeMap::new());
        let mut followups: Vec<(String, Vec<u8>, bool, disk::Stat)> = Vec::new();
        for (p, f) in std::mem::take(&mut created) {
            match (verdict(&p, matches!(f, Found::Dir)), f) {
                (Verdict::Git, f) => {
                    co_created.insert(p, f);
                }
                (Verdict::Split(git_bytes, git_exec), Found::File { bytes, exec, stat, .. }) => {
                    followups.push((p.clone(), bytes, exec, stat));
                    let oid = oid_of(&git_bytes);
                    co_created.insert(p, Found::File { bytes: git_bytes, oid, exec: git_exec, stat });
                }
                (_, f) => {
                    created.insert(p, f);
                }
            }
        }
        for (p, e) in std::mem::take(&mut removed) {
            if matches!(verdict(&p, e.kind == Kind::Dir), Verdict::Git) {
                co_removed.insert(p, e);
            } else {
                removed.insert(p, e);
            }
        }
        for (p, (e, c)) in std::mem::take(&mut changed) {
            match (verdict(&p, false), c) {
                (Verdict::Git, c) => {
                    co_changed.insert(p, (e, c));
                }
                (Verdict::Split(git_bytes, git_exec), Change::Edit { bytes, exec, stat }) => {
                    followups.push((p.clone(), bytes, exec, stat));
                    co_changed.insert(p, (e, Change::Edit { bytes: git_bytes, exec: git_exec, stat }));
                }
                (_, c) => {
                    changed.insert(p, (e, c));
                }
            }
        }
        let marker = match &head {
            Some(to) if head_moved => Some(Op::GitCheckout { from: self.git_head.clone(), to: to.clone() }),
            _ if co_created.is_empty() && co_removed.is_empty() && co_changed.is_empty() => None,
            _ => Some(Op::GitWrite { operation: operation.unwrap_or("git").to_string(), head: head.clone() }),
        };
        self.git_head = head;
        drop(new_index);
        self.adopt_git_index(new_compact);
        let by_git = self.commit_pass(co_created, co_removed, co_changed, marker, git_busy)?;
        for (p, bytes, exec, stat) in followups {
            if let Some(e) = self.shadow.get(&p).cloned() {
                changed.insert(p, (e, Change::Edit { bytes, exec, stat }));
            }
        }
        let edits = self.commit_pass(created, removed, changed, None, git_busy)?;
        Ok(edits.or(by_git))
    }

    /// Records one set of disk changes as a batch by the ingestion actor,
    /// parented on the synced version. `marker` marks it as git's doing.
    fn commit_pass(
        &mut self,
        created: BTreeMap<String, Found>,
        removed: BTreeMap<String, Entry>,
        changed: BTreeMap<String, (Entry, Change)>,
        marker: Option<Op>,
        git_busy: bool,
    ) -> Result<Option<BatchId>, Error> {
        if created.is_empty() && removed.is_empty() && changed.is_empty() && marker.is_none() {
            self.persist()?;
            return Ok(None);
        }
        // Renames: a removed file whose exact bytes reappear elsewhere keeps
        // its inode (and so its history, anchors and attribution).
        let mut by_oid: HashMap<ondb_core::Oid, Vec<String>> = HashMap::new();
        for (p, e) in &removed {
            if e.kind == Kind::File
                && let Some(oid) = e.oid
                && !created.contains_key(p)
            {
                by_oid.entry(oid).or_default().push(p.clone());
            }
        }
        let mut file_moves: BTreeMap<String, String> = BTreeMap::new(); // new -> old
        for (p, f) in &created {
            if let Found::File { oid, .. } = f
                && let Some(olds) = by_oid.get_mut(oid)
                && !olds.is_empty()
            {
                file_moves.insert(p.clone(), olds.remove(0));
            }
        }
        let dir_moves = self.detect_dir_moves(&created, &removed, &file_moves);
        // Moves inside a moved directory ride along with it.
        file_moves.retain(|new, _| !dir_moves.iter().any(|(_, to)| is_under(new, to)));

        let ws = self.ws.clone();
        let parents = self.record.synced_version.clone();
        let actor = self.record.ingestion_actor;
        let shadow = &self.shadow;
        let objects = self.objects.clone();
        let held = |oid: &ondb_core::Oid| objects.as_ref().is_some_and(|o| o.0.contains(&oid.0));
        let bulk = shadow.is_empty() && removed.is_empty() && ws.read(|h| h.tree().is_empty()) && created.len() > 1;
        let t_commit = std::time::Instant::now();
        let (batch, updates) = ws.commit(actor, Some(parents), |txn| -> Result<Vec<Update>, Error> {
            let t_ops = std::time::Instant::now();
            let mut updates = Vec::new();
            if let Some(op) = marker {
                txn.push(op)?;
            }
            if bulk {
                import(txn, &created, &held, &mut updates)?;
            } else {
                apply_changes(txn, shadow, &created, &removed, &changed, &file_moves, &dir_moves, &held, &mut updates)?;
            }
            crate::timing::add("ops", t_ops.elapsed());

            Ok(updates)
        })?;
        crate::timing::add("ws.commit", t_commit.elapsed());
        for u in updates {
            match u {
                Update::Insert(p, e) => self.shadow.insert(p, e),
                Update::Remove(p) => {
                    for c in self.shadow.under(&p) {
                        self.shadow.remove(&c);
                    }
                    self.shadow.remove(&p);
                }
                Update::RenameTree(from, to) => self.shadow.rename_tree(&from, &to),
            }
        }
        if let Some(id) = batch {
            // The disk now reflects exactly this batch's causal past.
            self.record.synced_version = Version::single(id);
            tracing::debug!(batch = ?id, git_busy, "ingested disk changes");
        }
        self.persist()?;
        Ok(batch)
    }

    /// Directory renames: a removed directory all of whose files reappear
    /// under a created directory with the same relative paths.
    fn detect_dir_moves(
        &self,
        created: &BTreeMap<String, Found>,
        removed: &BTreeMap<String, Entry>,
        file_moves: &BTreeMap<String, String>,
    ) -> Vec<(String, String)> {
        let mut votes: BTreeSet<(String, String)> = BTreeSet::new();
        for (new, old) in file_moves {
            let (mut n, mut o) = (parent_of(new), parent_of(old));
            while !n.is_empty() && !o.is_empty() && name_of(n) == name_of(o) {
                if matches!(created.get(n), Some(Found::Dir)) && removed.get(o).is_some_and(|e| e.kind == Kind::Dir) {
                    votes.insert((o.to_string(), n.to_string()));
                }
                n = parent_of(n);
                o = parent_of(o);
            }
            if !n.is_empty()
                && !o.is_empty()
                && matches!(created.get(n), Some(Found::Dir))
                && removed.get(o).is_some_and(|e| e.kind == Kind::Dir)
            {
                votes.insert((o.to_string(), n.to_string()));
            }
        }
        let moved_to: HashMap<&str, &str> = file_moves.iter().map(|(n, o)| (o.as_str(), n.as_str())).collect();
        let accepted: Vec<(String, String)> = votes
            .into_iter()
            .filter(|(from, to)| {
                self.shadow.under(from).iter().all(|p| match self.shadow.get(p).map(|e| e.kind) {
                    Some(Kind::File) => moved_to.get(p.as_str()) == Some(&format!("{to}{}", &p[from.len()..]).as_str()),
                    _ => true,
                })
            })
            .collect();
        // Keep only outermost moves.
        accepted.iter().filter(|(from, _)| !accepted.iter().any(|(f2, _)| is_under(from, f2))).cloned().collect()
    }
}

fn import(txn: &mut Txn<'_>, created: &BTreeMap<String, Found>, held: Held<'_>, updates: &mut Vec<Update>) -> Result<(), Error> {
    let mut index: HashMap<&str, u32> = HashMap::new();
    let mut entries = Vec::new();
    let mut blobs = Vec::new();
    let mut shadow_entries = Vec::new();
    for (path, found) in created {
        let parent = match parent_of(path) {
            "" => ImportParent::Existing(InodeId::ROOT),
            p => match index.get(p) {
                Some(i) => ImportParent::Entry(*i),
                None => continue,
            },
        };
        let (node, kind, oid, exec, stat) = match found {
            Found::Dir => (ImportNode::Dir, Kind::Dir, None, false, None),
            Found::Symlink { target } => {
                (ImportNode::Symlink { target: target.clone() }, Kind::Symlink, Some(symlink_oid(target)), false, None)
            }
            Found::File { bytes, oid, exec, stat } => {
                let (content, line_ending, blob) = content_of(bytes, *oid, held);
                blobs.extend(blob);
                (ImportNode::File { mode: mode(*exec), line_ending, content }, Kind::File, Some(*oid), *exec, Some(*stat))
            }
        };
        let i = entries.len() as u32;
        if matches!(node, ImportNode::Dir) {
            index.insert(path.as_str(), i);
        }
        entries.push(ImportEntry { parent, name: name_of(path).to_string(), node });
        shadow_entries.push((path.clone(), i, kind, oid, exec, stat));
    }
    for b in blobs {
        txn.attach_blob(b);
    }
    let op = txn.push(Op::Import { entries })?;
    for (path, i, kind, oid, exec, stat) in shadow_entries {
        updates.push(Update::Insert(path, Entry { inode: InodeId::new(op, i), kind, oid, exec, stat }));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn apply_changes(
    txn: &mut Txn<'_>,
    shadow: &Shadow,
    created: &BTreeMap<String, Found>,
    removed: &BTreeMap<String, Entry>,
    changed: &BTreeMap<String, (Entry, Change)>,
    file_moves: &BTreeMap<String, String>,
    dir_moves: &[(String, String)],
    held: Held<'_>,
    updates: &mut Vec<Update>,
) -> Result<(), Error> {
    // Directory inodes created or moved by this batch, by destination path.
    let mut placed: HashMap<String, InodeId> = HashMap::new();
    let resolve = |path: &str, placed: &HashMap<String, InodeId>| -> Option<InodeId> {
        if path.is_empty() {
            return Some(InodeId::ROOT);
        }
        if let Some(i) = placed.get(path) {
            return Some(*i);
        }
        for (from, to) in dir_moves {
            if path == to || is_under(path, to) {
                return shadow.get(&format!("{from}{}", &path[to.len()..])).map(|e| e.inode);
            }
        }
        shadow.get(path).filter(|e| e.kind == Kind::Dir).map(|e| e.inode)
    };

    // 1. Directory moves and new directories, shallowest destination first.
    let mut dir_targets: Vec<(&str, Option<&str>)> = created
        .iter()
        .filter(|(p, f)| matches!(f, Found::Dir) && !dir_moves.iter().any(|(_, to)| *p == to || is_under(p, to)))
        .map(|(p, _)| (p.as_str(), None))
        .collect();
    dir_targets.extend(dir_moves.iter().map(|(from, to)| (to.as_str(), Some(from.as_str()))));
    dir_targets.sort_by_key(|(p, _)| (p.matches('/').count(), p.to_string()));
    for (path, from) in dir_targets {
        let Some(parent) = resolve(parent_of(path), &placed) else { continue };
        let name = name_of(path).to_string();
        match from {
            Some(from) => {
                let inode = shadow.get(from).expect("moved dir is shadowed").inode;
                txn.push(Op::Rename { inode, parent, name })?;
                placed.insert(path.to_string(), inode);
                updates.push(Update::RenameTree(from.to_string(), path.to_string()));
            }
            None => {
                let op = txn.push(Op::CreateDir { parent, name })?;
                let inode = InodeId::new(op, 0);
                placed.insert(path.to_string(), inode);
                updates
                    .push(Update::Insert(path.to_string(), Entry { inode, kind: Kind::Dir, oid: None, exec: false, stat: None }));
            }
        }
    }

    // 2. File moves.
    for (new, old) in file_moves {
        let Some(parent) = resolve(parent_of(new), &placed) else { continue };
        let entry = shadow.get(old).expect("moved file is shadowed").clone();
        txn.push(Op::Rename { inode: entry.inode, parent, name: name_of(new).to_string() })?;
        let stat = match created.get(new) {
            Some(Found::File { stat, .. }) => Some(*stat),
            _ => None,
        };
        updates.push(Update::Remove(old.clone()));
        updates.push(Update::Insert(new.clone(), Entry { stat, ..entry }));
        if let Some(Found::File { bytes, exec, .. }) = created.get(new)
            && entry.exec != *exec
        {
            let (ops, _) = edit_ops(txn, entry.inode, bytes, Some(*exec));
            for op in ops {
                txn.push(op)?;
            }
        }
    }

    // 3. Removals not explained by a move; a removed directory covers its
    // descendants.
    let moved_from: BTreeSet<&str> = file_moves.values().map(|s| s.as_str()).collect();
    for (path, entry) in removed {
        if moved_from.contains(path.as_str())
            || dir_moves.iter().any(|(from, _)| path == from || is_under(path, from))
            || removed.keys().any(|other| is_under(path, other) && !moved_from.contains(other.as_str()))
        {
            continue;
        }
        txn.push(Op::Remove { inode: entry.inode })?;
        updates.push(Update::Remove(path.clone()));
    }

    // 4. New files and symlinks.
    for (path, found) in created {
        if file_moves.contains_key(path) || dir_moves.iter().any(|(_, to)| path == to || is_under(path, to)) {
            continue;
        }
        let Some(parent) = resolve(parent_of(path), &placed) else { continue };
        let name = name_of(path).to_string();
        match found {
            Found::Dir => {}
            Found::File { bytes, oid, exec, stat } => {
                let (content, line_ending, blob) = content_of(bytes, *oid, held);
                if let Some(b) = blob {
                    txn.attach_blob(b);
                }
                let op = txn.push(Op::CreateFile { parent, name, mode: mode(*exec), line_ending, content })?;
                updates.push(Update::Insert(
                    path.clone(),
                    Entry { inode: InodeId::new(op, 0), kind: Kind::File, oid: Some(*oid), exec: *exec, stat: Some(*stat) },
                ));
            }
            Found::Symlink { target } => {
                let op = txn.push(Op::CreateSymlink { parent, name, target: target.clone() })?;
                updates.push(Update::Insert(
                    path.clone(),
                    Entry {
                        inode: InodeId::new(op, 0),
                        kind: Kind::Symlink,
                        oid: Some(symlink_oid(target)),
                        exec: false,
                        stat: None,
                    },
                ));
            }
        }
    }

    // 5. Content, mode and link changes in place.
    for (path, (entry, change)) in changed {
        match change {
            Change::Edit { bytes, exec, stat } => {
                let (ops, blob) = edit_ops(txn, entry.inode, bytes, Some(*exec));
                if let Some(b) = blob {
                    txn.attach_blob(b);
                }
                for op in ops {
                    txn.push(op)?;
                }
                updates.push(Update::Insert(
                    path.clone(),
                    Entry { oid: Some(oid_of(bytes)), exec: *exec, stat: Some(*stat), ..entry.clone() },
                ));
            }
            Change::Exec { exec, stat } => {
                txn.push(Op::SetMode { inode: entry.inode, mode: mode(*exec) })?;
                updates.push(Update::Insert(path.clone(), Entry { exec: *exec, stat: Some(*stat), ..entry.clone() }));
            }
            Change::Link { target } => {
                txn.push(Op::SetSymlinkTarget { inode: entry.inode, target: target.clone() })?;
                updates.push(Update::Insert(path.clone(), Entry { oid: Some(symlink_oid(target)), ..entry.clone() }));
            }
        }
    }
    Ok(())
}

impl MountState {
    /// An edit tool writing a file as `actor`. The change is recorded under
    /// that actor, then materialized; the watcher sees disk already matching.
    pub(super) fn tool_write(
        &mut self,
        actor: ActorId,
        path: &str,
        bytes: Vec<u8>,
        exec: Option<bool>,
    ) -> Result<Option<BatchId>, Error> {
        self.wake()?;
        let path = normalize(path)?;
        self.materialize()?;
        let (batch, _) = self.ws.commit(actor, None, |txn| -> Result<(), Error> {
            let existing = {
                let view = txn.view();
                txn.history().tree().lookup(&view, &path)
            };
            match existing {
                Some(inode) if txn.history().inode(&inode).is_some_and(|i| i.file().is_some()) => {
                    let (ops, blob) = edit_ops(txn, inode, &bytes, exec);
                    if let Some(b) = blob {
                        txn.attach_blob(b);
                    }
                    for op in ops {
                        txn.push(op)?;
                    }
                }
                Some(_) => return Err(Error::Invalid(format!("{path} exists and is not a file"))),
                None => {
                    let parent = ensure_dirs(txn, parent_of(&path))?;
                    let (content, line_ending, blob) = content_of(&bytes, oid_of(&bytes), &|_| false);
                    if let Some(b) = blob {
                        txn.attach_blob(b);
                    }
                    let mode = mode(exec.unwrap_or(false));
                    txn.push(Op::CreateFile { parent, name: name_of(&path).to_string(), mode, line_ending, content })?;
                }
            }
            Ok(())
        })?;
        self.materialize()?;
        Ok(batch)
    }

    pub(super) fn tool_remove(&mut self, actor: ActorId, path: &str) -> Result<Option<BatchId>, Error> {
        self.wake()?;
        let path = normalize(path)?;
        self.materialize()?;
        let (batch, _) = self.ws.commit(actor, None, |txn| -> Result<(), Error> {
            let inode = {
                let view = txn.view();
                txn.history().tree().lookup(&view, &path)
            };
            let inode = inode.ok_or_else(|| Error::Invalid(format!("{path} does not exist")))?;
            txn.push(Op::Remove { inode })?;
            Ok(())
        })?;
        self.materialize()?;
        Ok(batch)
    }

    pub(super) fn tool_rename(&mut self, actor: ActorId, from: &str, to: &str) -> Result<Option<BatchId>, Error> {
        self.wake()?;
        let (from, to) = (normalize(from)?, normalize(to)?);
        self.materialize()?;
        let (batch, _) = self.ws.commit(actor, None, |txn| -> Result<(), Error> {
            let (inode, occupied) = {
                let view = txn.view();
                let tree = txn.history().tree();
                (tree.lookup(&view, &from), tree.lookup(&view, &to).is_some())
            };
            let inode = inode.ok_or_else(|| Error::Invalid(format!("{from} does not exist")))?;
            if occupied {
                return Err(Error::Invalid(format!("{to} already exists")));
            }
            let parent = ensure_dirs(txn, parent_of(&to))?;
            txn.push(Op::Rename { inode, parent, name: name_of(&to).to_string() })?;
            Ok(())
        })?;
        self.materialize()?;
        Ok(batch)
    }
}

fn normalize(path: &str) -> Result<String, Error> {
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty() && *p != ".").collect();
    if parts.is_empty() || parts.contains(&"..") || disk::is_internal(path) {
        return Err(Error::Invalid(format!("invalid worktree path {path:?}")));
    }
    Ok(parts.join("/"))
}

/// Resolves (creating as needed) the directory at `path`.
fn ensure_dirs(txn: &mut Txn<'_>, path: &str) -> Result<InodeId, Error> {
    let mut cur = InodeId::ROOT;
    let mut prefix = String::new();
    for part in path.split('/').filter(|p| !p.is_empty()) {
        prefix = join(&prefix, part);
        let found = {
            let view = txn.view();
            txn.history().tree().lookup(&view, &prefix)
        };
        cur = match found {
            Some(i) if txn.history().inode(&i).is_some_and(|n| n.is_dir()) => i,
            Some(_) => return Err(Error::Invalid(format!("{prefix} is not a directory"))),
            None => InodeId::new(txn.push(Op::CreateDir { parent: cur, name: part.to_string() })?, 0),
        };
    }
    Ok(cur)
}
