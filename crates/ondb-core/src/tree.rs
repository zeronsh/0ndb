//! File-tree CRDT. Every entry is an inode with last-writer-wins registers
//! for placement (parent + name), liveness, mode and so on. Registers keep
//! their full history so any version (or any "everything except these
//! batches" view) can be reconstructed exactly.

use std::collections::{BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::id::{InodeId, OpId};
use crate::op::{BlobRef, FileMode, LineEnding};
use crate::text::{Text, View};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Lww<T> {
    entries: Vec<(OpId, T)>,
}

impl<T> Default for Lww<T> {
    fn default() -> Self {
        Lww { entries: Vec::new() }
    }
}

impl<T> Lww<T> {
    pub fn new(op: OpId, value: T) -> Self {
        Lww { entries: vec![(op, value)] }
    }

    pub fn set(&mut self, op: OpId, value: T) {
        if let Err(i) = self.entries.binary_search_by_key(&op, |(o, _)| *o) {
            self.entries.insert(i, (op, value));
        }
    }

    pub fn get(&self) -> Option<&T> {
        self.entries.last().map(|(_, v)| v)
    }

    pub fn get_with_op(&self) -> Option<(OpId, &T)> {
        self.entries.last().map(|(o, v)| (*o, v))
    }

    pub fn get_in(&self, view: &dyn View) -> Option<&T> {
        self.nth_in(view, 0).map(|(_, v)| v)
    }

    /// `n`-th most recent value observed by `view`.
    pub fn nth_in(&self, view: &dyn View, n: usize) -> Option<(OpId, &T)> {
        self.entries.iter().rev().filter(|(o, _)| view.observes(*o)).nth(n).map(|(o, v)| (*o, v))
    }

    pub fn history(&self) -> &[(OpId, T)] {
        &self.entries
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Placement {
    pub parent: InodeId,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ContentKind {
    Text,
    Binary(BlobRef),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileNode {
    pub text: Text,
    pub content: Lww<ContentKind>,
    pub mode: Lww<FileMode>,
    pub line_ending: Lww<LineEnding>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeKind {
    Dir,
    File(FileNode),
    Symlink { target: Lww<String> },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Inode {
    pub id: InodeId,
    pub kind: NodeKind,
    pub placement: Lww<Placement>,
    pub alive: Lww<bool>,
}

impl Inode {
    pub fn is_dir(&self) -> bool {
        matches!(self.kind, NodeKind::Dir)
    }

    pub fn file(&self) -> Option<&FileNode> {
        match &self.kind {
            NodeKind::File(f) => Some(f),
            _ => None,
        }
    }

    pub fn file_mut(&mut self) -> Option<&mut FileNode> {
        match &mut self.kind {
            NodeKind::File(f) => Some(f),
            _ => None,
        }
    }
}

/// Where stored inodes are read from when first used (see
/// [`Tree::insert_unloaded`]).
pub trait InodeSource: Send + Sync {
    fn inode(&self, id: &InodeId) -> Option<Inode>;
}

/// An inode, possibly not loaded yet. Unloaded slots cost their key and a
/// pointer, so a large tree's untouched entries stay out of memory.
#[derive(Clone, Default)]
struct Slot(std::sync::OnceLock<Box<Inode>>);

impl Slot {
    fn loaded(inode: Inode) -> Slot {
        Slot(std::sync::OnceLock::from(Box::new(inode)))
    }
}

#[derive(Clone)]
pub struct Tree {
    inodes: HashMap<InodeId, Slot>,
    /// Every inode that has ever been placed under a directory.
    children: HashMap<InodeId, BTreeSet<InodeId>>,
    source: Option<std::sync::Arc<dyn InodeSource>>,
}

impl std::fmt::Debug for Tree {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tree").field("inodes", &self.inodes.len()).field("loaded", &self.loaded_count()).finish()
    }
}

/// Serialized with every inode loaded.
#[derive(Serialize, Deserialize)]
struct TreeRepr {
    inodes: Vec<Inode>,
}

impl Serialize for Tree {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut inodes: Vec<Inode> = self.inodes().cloned().collect();
        inodes.sort_by_key(|i| i.id);
        TreeRepr { inodes }.serialize(s)
    }
}

impl<'de> Deserialize<'de> for Tree {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let mut tree = Tree::new();
        for i in TreeRepr::deserialize(d)?.inodes {
            tree.insert(i);
        }
        Ok(tree)
    }
}

impl Default for Tree {
    fn default() -> Self {
        Self::new()
    }
}

/// Conflict-free display name for the losers of a name collision.
pub fn conflict_name(name: &str, winner_loser_op: OpId) -> String {
    format!("{name}~{}-{}", winner_loser_op.actor.short(), winner_loser_op.ts)
}

impl Tree {
    pub fn new() -> Self {
        let root = Inode { id: InodeId::ROOT, kind: NodeKind::Dir, placement: Lww::default(), alive: Lww::new(OpId::ZERO, true) };
        Tree { inodes: HashMap::from([(InodeId::ROOT, Slot::loaded(root))]), children: HashMap::new(), source: None }
    }

    fn read(source: &Option<std::sync::Arc<dyn InodeSource>>, id: &InodeId) -> Box<Inode> {
        // The row was readable when the history loaded and stays while the
        // inode exists; failing now means the store is broken, and carrying
        // on without the inode would corrupt it.
        Box::new(source.as_ref().and_then(|s| s.inode(id)).unwrap_or_else(|| panic!("0ndb: loading stored inode {id:?} failed")))
    }

    pub fn get(&self, id: &InodeId) -> Option<&Inode> {
        let slot = self.inodes.get(id)?;
        Some(slot.0.get_or_init(|| Self::read(&self.source, id)))
    }

    fn at(&self, id: &InodeId) -> &Inode {
        self.get(id).expect("inode is in the tree")
    }

    pub fn get_mut(&mut self, id: &InodeId) -> Option<&mut Inode> {
        let slot = self.inodes.get_mut(id)?;
        if slot.0.get().is_none() {
            let _ = slot.0.set(Self::read(&self.source, id));
        }
        slot.0.get_mut().map(|b| &mut **b)
    }

    /// Whether the inode exists, without loading it.
    pub fn contains(&self, id: &InodeId) -> bool {
        self.inodes.contains_key(id)
    }

    /// Every inode id, without loading any.
    pub fn ids(&self) -> impl Iterator<Item = &InodeId> {
        self.inodes.keys()
    }

    /// Adds a stored inode without loading it: only its id and the
    /// directories it has been placed under are kept until first use.
    pub fn insert_unloaded(&mut self, id: InodeId, parents: impl IntoIterator<Item = InodeId>) {
        for p in parents {
            self.children.entry(p).or_default().insert(id);
        }
        self.inodes.insert(id, Slot::default());
    }

    pub fn set_source(&mut self, source: std::sync::Arc<dyn InodeSource>) {
        self.source = Some(source);
    }

    pub fn loaded_count(&self) -> usize {
        self.inodes.values().filter(|s| s.0.get().is_some()).count()
    }

    /// Drops loaded inodes not in `keep` (they reload from the source on
    /// next use). Callers must only drop inodes whose state is persisted.
    /// No-op without a source.
    pub fn unload_except(&mut self, keep: &std::collections::HashSet<InodeId>) {
        if self.source.is_none() {
            return;
        }
        for (id, slot) in self.inodes.iter_mut() {
            if !id.is_root() && !keep.contains(id) {
                *slot = Slot::default();
            }
        }
    }

    pub fn len(&self) -> usize {
        self.inodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.inodes.len() <= 1
    }

    /// Every inode, loading each. Prefer [`Tree::ids`] when ids suffice.
    pub fn inodes(&self) -> impl Iterator<Item = &Inode> {
        self.inodes.keys().map(|id| self.at(id))
    }

    pub fn insert(&mut self, inode: Inode) {
        for (_, p) in inode.placement.history() {
            self.children.entry(p.parent).or_default().insert(inode.id);
        }
        self.inodes.insert(inode.id, Slot::loaded(inode));
    }

    pub fn place(&mut self, id: InodeId, op: OpId, placement: Placement) {
        self.children.entry(placement.parent).or_default().insert(id);
        if let Some(inode) = self.get_mut(&id) {
            inode.placement.set(op, placement);
        }
    }

    fn alive_in(&self, view: &dyn View, id: &InodeId) -> bool {
        self.get(id).and_then(|i| i.alive.get_in(view)).copied().unwrap_or(false)
    }

    /// Effective placement after breaking rename cycles. Cycles (two
    /// directories moved into each other concurrently) are broken by
    /// reverting the member whose latest move has the greatest op id to its
    /// previous placement, repeatedly, which every replica computes the same.
    pub fn placement_in<'a>(&'a self, view: &dyn View, id: &InodeId) -> Option<&'a Placement> {
        if id.is_root() {
            return None;
        }
        let mut demoted: HashMap<InodeId, usize> = HashMap::new();
        'retry: loop {
            let mut chain: Vec<InodeId> = Vec::new();
            let mut cur = *id;
            loop {
                if cur.is_root() {
                    let n = demoted.get(id).copied().unwrap_or(0);
                    return self.get(id)?.placement.nth_in(view, n).map(|(_, p)| p);
                }
                if let Some(pos) = chain.iter().position(|c| *c == cur) {
                    let cycle = &chain[pos..];
                    let victim = cycle
                        .iter()
                        .max_by_key(|c| {
                            let n = demoted.get(*c).copied().unwrap_or(0);
                            self.at(c).placement.nth_in(view, n).map(|(o, _)| o)
                        })
                        .copied()?;
                    *demoted.entry(victim).or_default() += 1;
                    continue 'retry;
                }
                chain.push(cur);
                let n = demoted.get(&cur).copied().unwrap_or(0);
                let (_, p) = self.get(&cur)?.placement.nth_in(view, n)?;
                cur = p.parent;
            }
        }
    }

    /// Present = alive, or a dead directory that still holds present
    /// entries (created concurrently with its removal), which keeps them
    /// reachable instead of silently orphaning them.
    pub fn is_present(&self, view: &dyn View, id: &InodeId) -> bool {
        if id.is_root() {
            return true;
        }
        let Some(inode) = self.get(id) else { return false };
        if inode.placement.get_in(view).is_none() {
            return false;
        }
        if self.alive_in(view, id) {
            return true;
        }
        inode.is_dir() && self.child_ids(view, id).iter().any(|c| self.is_present(view, c))
    }

    fn child_ids(&self, view: &dyn View, dir: &InodeId) -> Vec<InodeId> {
        let Some(set) = self.children.get(dir) else { return Vec::new() };
        set.iter().filter(|c| self.placement_in(view, c).is_some_and(|p| p.parent == *dir)).copied().collect()
    }

    /// Present children of a directory with collision-free display names,
    /// sorted by name.
    pub fn list(&self, view: &dyn View, dir: &InodeId) -> Vec<(String, InodeId)> {
        let mut by_name: HashMap<String, Vec<(OpId, InodeId)>> = HashMap::new();
        for c in self.child_ids(view, dir) {
            if !self.is_present(view, &c) {
                continue;
            }
            let inode = self.at(&c);
            if let Some((op, p)) = inode.placement.nth_in(view, 0) {
                by_name.entry(p.name.clone()).or_default().push((op, c));
            }
        }
        let mut out = Vec::new();
        for (name, mut group) in by_name {
            // The most recent placement keeps the name.
            group.sort();
            let winner = group.pop().expect("non-empty group");
            out.push((name.clone(), winner.1));
            for (op, id) in group {
                out.push((conflict_name(&name, op), id));
            }
        }
        out.sort();
        out
    }

    pub fn display_name(&self, view: &dyn View, id: &InodeId) -> Option<String> {
        let p = self.placement_in(view, id)?;
        self.list(view, &p.parent).into_iter().find(|(_, c)| c == id).map(|(n, _)| n)
    }

    pub fn path_of(&self, view: &dyn View, id: &InodeId) -> Option<String> {
        if id.is_root() {
            return Some(String::new());
        }
        let mut parts = Vec::new();
        let mut cur = *id;
        while !cur.is_root() {
            if !self.is_present(view, &cur) {
                return None;
            }
            parts.push(self.display_name(view, &cur)?);
            cur = self.placement_in(view, &cur)?.parent;
            if parts.len() > 4096 {
                return None;
            }
        }
        parts.reverse();
        Some(parts.join("/"))
    }

    pub fn lookup(&self, view: &dyn View, path: &str) -> Option<InodeId> {
        let mut cur = InodeId::ROOT;
        for part in path.split('/').filter(|p| !p.is_empty()) {
            cur = self.list(view, &cur).into_iter().find(|(n, _)| n == part)?.1;
        }
        Some(cur)
    }

    /// Present descendants (depth-first, parents before children).
    pub fn descendants(&self, view: &dyn View, dir: &InodeId) -> Vec<InodeId> {
        let mut out = Vec::new();
        let mut stack = vec![*dir];
        while let Some(d) = stack.pop() {
            for c in self.child_ids(view, &d) {
                out.push(c);
                if self.at(&c).is_dir() {
                    stack.push(c);
                }
            }
        }
        out
    }

    /// Every present entry with its path, in sorted pre-order (parents
    /// before children).
    pub fn walk(&self, view: &dyn View) -> Vec<(String, InodeId)> {
        let mut out = Vec::new();
        self.walk_into(view, &InodeId::ROOT, "", &mut out);
        out
    }

    fn walk_into(&self, view: &dyn View, dir: &InodeId, prefix: &str, out: &mut Vec<(String, InodeId)>) {
        for (name, id) in self.list(view, dir) {
            let path = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
            out.push((path.clone(), id));
            if self.at(&id).is_dir() {
                self.walk_into(view, &id, &path, out);
            }
        }
    }
}

/// An inode as stored durably: everything except its text, whose tree is
/// persisted node by node and referenced by id.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum StoredKind {
    Dir,
    File { content: Lww<ContentKind>, mode: Lww<FileMode>, line_ending: Lww<LineEnding> },
    Symlink { target: Lww<String> },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredInode {
    pub id: InodeId,
    pub kind: StoredKind,
    pub placement: Lww<Placement>,
    pub alive: Lww<bool>,
}

impl Inode {
    pub fn to_stored(&self) -> (StoredInode, Option<&Text>) {
        let (kind, text) = match &self.kind {
            NodeKind::Dir => (StoredKind::Dir, None),
            NodeKind::Symlink { target } => (StoredKind::Symlink { target: target.clone() }, None),
            NodeKind::File(f) => (
                StoredKind::File { content: f.content.clone(), mode: f.mode.clone(), line_ending: f.line_ending.clone() },
                Some(&f.text),
            ),
        };
        (StoredInode { id: self.id, kind, placement: self.placement.clone(), alive: self.alive.clone() }, text)
    }

    pub fn from_stored(s: StoredInode, text: Option<Text>) -> Inode {
        let kind = match s.kind {
            StoredKind::Dir => NodeKind::Dir,
            StoredKind::Symlink { target } => NodeKind::Symlink { target },
            StoredKind::File { content, mode, line_ending } => {
                NodeKind::File(FileNode { text: text.unwrap_or_default(), content, mode, line_ending })
            }
        };
        Inode { id: s.id, kind, placement: s.placement, alive: s.alive }
    }
}
