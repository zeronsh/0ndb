use std::collections::BTreeSet;
use std::fs;

use strand_core::{FileState, History, InodeId, NodeKind, Version, View};

use super::MountState;
use super::disk::{self, DiskEntry, TEMP_PREFIX, abs, oid_of, parent_of, probe, symlink_oid};
use super::ingest::{Scope, shadow_entry_for};
use super::shadow::{Entry, Kind};
use crate::Error;

enum Payload {
    Text(Vec<u8>),
    Blob(strand_core::Oid),
    Link(String),
    None,
}

struct Desired {
    inode: InodeId,
    /// `None` when the entry should not exist on disk.
    path: Option<String>,
    entry: Option<Entry>,
    payload: Payload,
}

fn payload_for(h: &History, view: &dyn View, inode: InodeId) -> Payload {
    match h.inode(&inode).map(|i| &i.kind) {
        Some(NodeKind::File(_)) => match h.file_state(view, &inode) {
            Some(FileState::Text { bytes, ending, .. }) => Payload::Text(disk::smudge(&bytes, ending)),
            Some(FileState::Binary { blob, .. }) => Payload::Blob(blob.oid),
            None => Payload::None,
        },
        Some(NodeKind::Symlink { .. }) => h.symlink_target(view, &inode).map(Payload::Link).unwrap_or(Payload::None),
        _ => Payload::None,
    }
}

fn depth(p: &Option<String>) -> usize {
    p.as_deref().map(|p| p.matches('/').count() + 1).unwrap_or(0)
}

impl MountState {
    pub(super) fn materialize(&mut self) -> Result<(), Error> {
        self.materialize_inner(false)
    }

    /// Materializes every entry (first mount of an existing history).
    pub(super) fn materialize_all(&mut self) -> Result<(), Error> {
        self.materialize_inner(true)
    }

    fn plan(&self, all: bool) -> Result<(Version, Vec<Desired>), Error> {
        let synced = self.record.synced_version.clone();
        self.ws.with(|ctx| {
            let heads = ctx.history().heads().clone();
            let inodes: Vec<InodeId> = if all {
                ctx.history().tree().inodes().map(|i| i.id).filter(|i| !i.is_root()).collect()
            } else {
                if heads == synced {
                    return Ok((heads, Vec::new()));
                }
                let diff = ctx.history().dag().difference(&heads, &synced);
                ctx.touched_by(diff)?.into_iter().collect()
            };
            let h = ctx.history();
            let view = h.current();
            let mut out: Vec<Desired> = inodes
                .into_iter()
                .filter(|i| !i.is_root())
                .map(|inode| {
                    let path = if h.tree().is_present(&view, &inode) { h.tree().path_of(&view, &inode) } else { None };
                    match &path {
                        Some(_) => Desired {
                            inode,
                            entry: shadow_entry_for(h, &view, inode),
                            payload: payload_for(h, &view, inode),
                            path,
                        },
                        None => Desired { inode, path: None, entry: None, payload: Payload::None },
                    }
                })
                .collect();
            out.sort_by(|a, b| depth(&a.path).cmp(&depth(&b.path)).then_with(|| a.path.cmp(&b.path)));
            Ok((heads, out))
        })
    }

    /// Whether the disk at `path` still holds what the shadow says.
    fn disk_matches(&mut self, path: &str) -> bool {
        let entry = self.shadow.get(path).cloned();
        match (entry, probe(&self.root, path)) {
            (None, DiskEntry::Missing) => true,
            (None, _) => false,
            (Some(e), d) => match (e.kind, d) {
                (Kind::Dir, DiskEntry::Dir) => true,
                (Kind::File, DiskEntry::File { stat, exec }) => {
                    if e.stat == Some(stat) && e.exec == exec {
                        return true;
                    }
                    let same = disk::read_limited(&self.root, path, self.opts.max_file_size)
                        .ok()
                        .flatten()
                        .is_some_and(|b| Some(oid_of(&b)) == e.oid)
                        && e.exec == exec;
                    if same {
                        self.shadow.set_stat(path, Some(stat));
                    }
                    same
                }
                (Kind::Symlink, DiskEntry::Symlink { target }) => e.oid == Some(symlink_oid(&target)),
                _ => false,
            },
        }
    }

    fn materialize_inner(&mut self, all: bool) -> Result<(), Error> {
        for _ in 0..8 {
            let (heads, plan) = self.plan(all)?;
            if plan.is_empty() {
                self.record.synced_version = heads;
                return self.persist();
            }
            // Never overwrite a change that hasn't been ingested yet: ingest
            // it first (it merges through the CRDT) and plan again.
            let mut stale = BTreeSet::new();
            for d in &plan {
                let current = self.shadow.path_of(&d.inode).map(str::to_string);
                let unchanged = current == d.path
                    && match (&d.path, &d.entry) {
                        (Some(p), Some(want)) => {
                            self.shadow.get(p).is_some_and(|e| e.kind == want.kind && e.oid == want.oid && e.exec == want.exec)
                        }
                        _ => true,
                    };
                if unchanged {
                    continue;
                }
                for p in current.iter().chain(d.path.iter()) {
                    if d.entry.as_ref().is_some_and(|e| e.kind == Kind::Dir)
                        && self.shadow.get(p).is_none()
                        && matches!(probe(&self.root, p), DiskEntry::Dir)
                    {
                        continue;
                    }
                    if !self.disk_matches(p) {
                        stale.insert(p.clone());
                    }
                }
            }
            if !stale.is_empty() {
                if self.reconcile(Scope::Paths(stale))?.is_none() {
                    // Nothing ingestable (e.g. ignored occupant): proceed.
                    return self.apply(heads, plan);
                }
                continue;
            }
            return self.apply(heads, plan);
        }
        Err(Error::Invalid("disk kept changing during materialization".into()))
    }

    fn apply(&mut self, heads: Version, plan: Vec<Desired>) -> Result<(), Error> {
        let root = self.root.clone();
        // 1. Removals, deepest first.
        let mut removals: Vec<String> =
            plan.iter().filter(|d| d.path.is_none()).filter_map(|d| self.shadow.path_of(&d.inode).map(str::to_string)).collect();
        removals.sort_by_key(|p| std::cmp::Reverse(p.matches('/').count()));
        for p in removals {
            disk::remove(&root, &p)?;
            self.shadow.remove(&p);
        }
        // 2. Moves, parents first. A moved directory carries its children,
        //    so each child's current path is re-read.
        let mut aside = 0usize;
        for d in plan.iter().filter(|d| d.path.is_some()) {
            let want = d.path.as_deref().unwrap();
            let Some(old) = self.shadow.path_of(&d.inode).map(str::to_string) else { continue };
            if old == want {
                continue;
            }
            if self.shadow.get(want).is_some() || !matches!(probe(&root, want), DiskEntry::Missing) {
                aside += 1;
                let tmp = format!("{TEMP_PREFIX}aside-{}-{aside}", std::process::id());
                fs::rename(abs(&root, want), abs(&root, &tmp))?;
                self.shadow.rename_tree(want, &tmp);
            }
            fs::create_dir_all(abs(&root, parent_of(want)))?;
            fs::rename(abs(&root, &old), abs(&root, want))?;
            self.shadow.rename_tree(&old, want);
        }
        // 3. Creation and content, parents first.
        for d in &plan {
            let (Some(path), Some(want)) = (&d.path, &d.entry) else { continue };
            let have = self.shadow.get(path).cloned();
            match want.kind {
                Kind::Dir => {
                    if have.as_ref().is_none_or(|h| h.kind != Kind::Dir) {
                        if have.is_some() {
                            disk::remove(&root, path)?;
                        }
                        fs::create_dir_all(abs(&root, path))?;
                        self.shadow.insert(path.clone(), Entry { stat: None, ..want.clone() });
                    }
                }
                Kind::File => {
                    let same_content = have.as_ref().is_some_and(|h| h.kind == Kind::File && h.oid == want.oid);
                    if same_content {
                        if have.as_ref().is_some_and(|h| h.exec != want.exec) {
                            let stat = disk::set_exec(&root, path, want.exec)?;
                            self.shadow.insert(path.clone(), Entry { stat: Some(stat), ..want.clone() });
                        } else if have.as_ref().is_some_and(|h| h.inode != want.inode) {
                            self.shadow.insert(path.clone(), Entry { stat: have.and_then(|h| h.stat), ..want.clone() });
                        }
                        continue;
                    }
                    let bytes = match &d.payload {
                        Payload::Text(b) => b.clone(),
                        Payload::Blob(oid) => match self.ws.blob(oid)? {
                            Some(b) => b,
                            None => {
                                tracing::warn!(path, "binary content not available locally yet");
                                continue;
                            }
                        },
                        _ => continue,
                    };
                    let stat = disk::write_atomic(&root, path, &bytes, want.exec)?;
                    self.shadow.insert(path.clone(), Entry { stat: Some(stat), oid: Some(oid_of(&bytes)), ..want.clone() });
                }
                Kind::Symlink => {
                    if have.as_ref().is_some_and(|h| h.kind == Kind::Symlink && h.oid == want.oid) {
                        continue;
                    }
                    if let Payload::Link(target) = &d.payload {
                        disk::write_symlink(&root, path, target)?;
                        self.shadow.insert(path.clone(), want.clone());
                    }
                }
            }
        }
        self.record.synced_version = heads;
        self.persist()
    }
}
