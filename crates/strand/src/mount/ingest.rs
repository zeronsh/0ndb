use std::collections::{BTreeMap, BTreeSet, HashMap};

use strand_core::diff::line_splices;
use strand_core::{
    ActorId, BatchId, Blob, BlobRef, Content, FileMode, FileState, History, ImportEntry, ImportNode, ImportParent, InodeId,
    LineEnding, NodeKind, Op, Txn, Version,
};

use super::MountState;
use super::disk::{
    self, Classified, DiskEntry, Stat, abs, classify, is_under, join, name_of, oid_of, parent_of, probe, symlink_oid,
};
use super::ignore::walker;
use super::shadow::{Entry, Kind, Shadow};
use crate::Error;

pub enum Scope {
    Full,
    Paths(BTreeSet<String>),
}

enum Found {
    Dir,
    File { bytes: Vec<u8>, exec: bool, stat: Stat },
    Symlink { target: String },
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

/// Content op payload for freshly read bytes, plus the blob to attach.
fn content_of(bytes: &[u8]) -> (Content, LineEnding, Option<Blob>) {
    match classify(bytes) {
        Classified::Text { clean, ending } => (Content::Text(clean), ending, None),
        Classified::Binary => {
            let oid = oid_of(bytes);
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
            ops.push(Op::SetContent { inode, content: Content::Text(clean) });
            ops.push(Op::SetLineEnding { inode, ending });
        }
        (Classified::Binary, Some(FileState::Binary { blob: b, .. })) if b.oid == oid_of(bytes) => {}
        (Classified::Binary, _) => {
            let (content, _, b) = content_of(bytes);
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
pub(super) fn shadow_entry_for(h: &History, view: &dyn strand_core::View, inode: InodeId) -> Option<Entry> {
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
        let walk_into = |dir: &str, out: &mut BTreeSet<String>| {
            for e in walker(&abs(&self.root, dir)).build().flatten() {
                if let Ok(rel) = e.path().strip_prefix(&self.root) {
                    out.insert(rel.to_string_lossy().into_owned());
                }
            }
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
        let git_busy = self.settle_git();
        if let Scope::Paths(p) = &scope
            && p.iter().any(|p| name_of(p) == ".gitignore")
        {
            self.ignore = super::Ignore::load(&self.root);
        }
        let cands = self.candidates(scope);
        let root = self.root.clone();

        let mut created: BTreeMap<String, Found> = BTreeMap::new();
        let mut removed: BTreeMap<String, Entry> = BTreeMap::new();
        let mut changed: BTreeMap<String, (Entry, Change)> = BTreeMap::new();
        let mut stat_only: Vec<(String, Stat)> = Vec::new();
        for path in &cands {
            let disk_entry = probe(&root, path);
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
                        DiskEntry::File { stat, exec } => match disk::read_limited(&root, path, self.opts.max_file_size) {
                            Ok(Some(bytes)) => {
                                created.insert(path.clone(), Found::File { bytes, exec, stat });
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
                    match disk::read_limited(&root, path, self.opts.max_file_size) {
                        Ok(Some(bytes)) => {
                            if s.oid == Some(oid_of(&bytes)) {
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
                            if let Ok(Some(bytes)) = disk::read_limited(&root, path, self.opts.max_file_size) {
                                created.insert(path.clone(), Found::File { bytes, exec, stat });
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
        for (path, stat) in stat_only {
            self.shadow.set_stat(&path, Some(stat));
        }

        let head = self.read_git_head();
        let head_moved = head != self.git_head;
        if created.is_empty() && removed.is_empty() && changed.is_empty() && !head_moved {
            self.persist()?;
            return Ok(None);
        }

        // Renames: a removed file whose exact bytes reappear elsewhere keeps
        // its inode (and so its history, anchors and attribution).
        let mut by_oid: HashMap<strand_core::Oid, Vec<String>> = HashMap::new();
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
            if let Found::File { bytes, .. } = f
                && let Some(olds) = by_oid.get_mut(&oid_of(bytes))
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
        let bulk = shadow.is_empty() && removed.is_empty() && ws.read(|h| h.tree().is_empty()) && created.len() > 1;
        let (batch, updates) = ws.commit(actor, Some(parents), |txn| -> Result<Vec<Update>, Error> {
            let mut updates = Vec::new();
            if bulk {
                import(txn, &created, &mut updates)?;
            } else {
                apply_changes(txn, shadow, &created, &removed, &changed, &file_moves, &dir_moves, &mut updates)?;
            }
            if head_moved && let Some(h) = &head {
                txn.push(Op::Meta { key: "git/head".into(), value: Some(h.as_bytes().to_vec()) })?;
            }
            Ok(updates)
        })?;
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
        self.git_head = head;
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

fn import(txn: &mut Txn<'_>, created: &BTreeMap<String, Found>, updates: &mut Vec<Update>) -> Result<(), Error> {
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
            Found::File { bytes, exec, stat } => {
                let (content, line_ending, blob) = content_of(bytes);
                blobs.extend(blob);
                (
                    ImportNode::File { mode: mode(*exec), line_ending, content },
                    Kind::File,
                    Some(oid_of(bytes)),
                    *exec,
                    Some(*stat),
                )
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
            Found::File { bytes, exec, stat } => {
                let (content, line_ending, blob) = content_of(bytes);
                if let Some(b) = blob {
                    txn.attach_blob(b);
                }
                let op = txn.push(Op::CreateFile { parent, name, mode: mode(*exec), line_ending, content })?;
                updates.push(Update::Insert(
                    path.clone(),
                    Entry {
                        inode: InodeId::new(op, 0),
                        kind: Kind::File,
                        oid: Some(oid_of(bytes)),
                        exec: *exec,
                        stat: Some(*stat),
                    },
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
                    let (content, line_ending, blob) = content_of(&bytes);
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
