use std::collections::{BTreeMap, HashMap, HashSet};
use std::ops::Bound;

use ondb_core::{InodeId, Oid};
use ondb_store::{MountEntryRow, MountReader};

use super::disk::Stat;

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    Dir,
    File,
    Symlink,
}

impl Kind {
    fn code(self) -> u8 {
        match self {
            Kind::Dir => 0,
            Kind::File => 1,
            Kind::Symlink => 2,
        }
    }

    fn from_code(c: u8) -> Kind {
        match c {
            0 => Kind::Dir,
            2 => Kind::Symlink,
            _ => Kind::File,
        }
    }
}

/// What the mount believes is on disk for one path: the inode it
/// materializes, the content identity of the exact on-disk bytes, and the
/// stat seen when that was last verified.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub inode: InodeId,
    pub kind: Kind,
    pub oid: Option<Oid>,
    pub exec: bool,
    pub stat: Option<Stat>,
}

/// The disk as of the mount's synced version. Persisted entries stay in the
/// store and are read on demand (memory doesn't grow with the tree); changes
/// not yet persisted live in an overlay until `persisted`. Full passes load
/// one sorted window of entries at a time (`window`).
#[derive(Default)]
pub struct Shadow {
    /// `None` while hibernating (or before the first mount persisted).
    reader: Option<MountReader>,
    /// Unpersisted changes: `Some` upserts, `None` removals.
    overlay: BTreeMap<String, Option<Entry>>,
    /// Where overlaid inodes now are (`None`: gone or moved away).
    overlay_inode: HashMap<InodeId, Option<String>>,
    /// Persisted entries of the current window, and its bounds.
    window: BTreeMap<String, Entry>,
    window_range: Option<(String, String)>,
}

fn entry_of(r: &MountEntryRow) -> Entry {
    let stat = match (r.mtime_ns, r.size, r.ino) {
        (Some(mtime_ns), Some(size), Some(ino)) => Some(Stat { mtime_ns, size, ino }),
        _ => None,
    };
    Entry { inode: r.inode, kind: Kind::from_code(r.kind), oid: r.oid, exec: r.mode == 1, stat }
}

fn warn<T>(r: Result<T, ondb_store::StoreError>) -> T {
    // Treating an unreadable entry as absent would re-ingest the file as new
    // (a duplicate); the store is broken if this fails.
    r.unwrap_or_else(|e| panic!("0ndb: reading mount entries failed: {e}"))
}

impl Shadow {
    pub fn open(reader: MountReader) -> Shadow {
        Shadow { reader: Some(reader), ..Shadow::default() }
    }

    /// Drops everything held in memory (the overlay must be persisted).
    pub fn release(&mut self) {
        debug_assert!(self.overlay.is_empty());
        *self = Shadow::default();
    }

    fn stored(&self, path: &str) -> Option<Entry> {
        if let Some((lo, hi)) = &self.window_range
            && lo.as_str() <= path
            && path <= hi.as_str()
        {
            return self.window.get(path).cloned();
        }
        warn(self.reader.as_ref().map_or(Ok(None), |r| r.get(path))).map(|r| entry_of(&r))
    }

    /// Loads the persisted entries with `lo <= path <= hi` so a pass over
    /// that sorted range needs no queries; replaces the previous window.
    pub fn window(&mut self, lo: &str, hi: &str) {
        self.clear_window();
        let Some(reader) = &self.reader else { return };
        self.window = warn(reader.range(lo, hi)).iter().map(|r| (r.path.clone(), entry_of(r))).collect();
        self.window_range = Some((lo.to_string(), hi.to_string()));
    }

    pub fn clear_window(&mut self) {
        self.window = BTreeMap::new();
        self.window_range = None;
    }

    pub fn is_empty(&self) -> bool {
        if self.overlay.values().any(Option::is_some) {
            return false;
        }
        let Some(reader) = &self.reader else { return true };
        let removed = self.overlay.values().filter(|e| e.is_none()).count() as u64;
        if removed == 0 {
            return !warn(reader.any());
        }
        warn(reader.count()) <= removed
    }

    pub fn get(&self, path: &str) -> Option<Entry> {
        match self.overlay.get(path) {
            Some(e) => e.clone(),
            None => self.stored(path),
        }
    }

    pub fn path_of(&self, inode: &InodeId) -> Option<String> {
        if let Some(p) = self.overlay_inode.get(inode) {
            return p.clone();
        }
        let row = warn(self.reader.as_ref().map_or(Ok(None), |r| r.by_inode(inode)))?;
        // The stored row may since have been removed or replaced.
        match self.overlay.get(&row.path) {
            Some(Some(e)) if e.inode == *inode => Some(row.path),
            Some(_) => None,
            None => Some(row.path),
        }
    }

    /// Every entry, persisted and not, in path order (transient: for
    /// whole-tree passes).
    pub fn entries(&self) -> Vec<(String, Entry)> {
        let mut out = Vec::new();
        let mut over = self.overlay.iter().peekable();
        let mut emit_until = |limit: Option<&str>, out: &mut Vec<(String, Entry)>| {
            while let Some((p, _)) = over.peek() {
                if limit.is_some_and(|l| p.as_str() >= l) {
                    break;
                }
                let (p, e) = over.next().expect("peeked");
                if let Some(e) = e {
                    out.push((p.clone(), e.clone()));
                }
            }
        };
        if let Some(reader) = &self.reader {
            warn(reader.for_each(|r| {
                emit_until(Some(&r.path), &mut out);
                if !self.overlay.contains_key(&r.path) {
                    let e = entry_of(&r);
                    out.push((r.path, e));
                }
            }));
        }
        emit_until(None, &mut out);
        out
    }

    pub fn paths(&self) -> Vec<String> {
        self.entries().into_iter().map(|(p, _)| p).collect()
    }

    /// Every inode the shadow places on disk.
    pub fn inodes(&self) -> HashSet<InodeId> {
        self.entries().into_iter().map(|(_, e)| e.inode).collect()
    }

    /// Paths strictly under `dir`.
    pub fn under(&self, dir: &str) -> Vec<String> {
        let start = format!("{dir}/");
        let mut out: std::collections::BTreeSet<String> =
            warn(self.reader.as_ref().map_or(Ok(Vec::new()), |r| r.under(dir))).into_iter().collect();
        for (p, e) in self.overlay.range::<str, _>((Bound::Included(start.as_str()), Bound::Unbounded)) {
            if !p.starts_with(&start) {
                break;
            }
            if e.is_some() {
                out.insert(p.clone());
            } else {
                out.remove(p);
            }
        }
        out.into_iter().collect()
    }

    pub fn insert(&mut self, path: String, entry: Entry) {
        if let Some(old) = self.path_of(&entry.inode)
            && old != path
        {
            self.remove(&old);
        }
        if let Some(prev) = self.get(&path)
            && prev.inode != entry.inode
        {
            self.overlay_inode.insert(prev.inode, None);
        }
        self.overlay_inode.insert(entry.inode, Some(path.clone()));
        self.overlay.insert(path, Some(entry));
    }

    pub fn remove(&mut self, path: &str) -> Option<Entry> {
        let e = self.get(path)?;
        if self.path_of(&e.inode).as_deref() == Some(path) {
            self.overlay_inode.insert(e.inode, None);
        }
        self.overlay.insert(path.to_string(), None);
        Some(e)
    }

    /// Moves a path and everything under it.
    pub fn rename_tree(&mut self, from: &str, to: &str) {
        let mut moved = vec![from.to_string()];
        moved.extend(self.under(from));
        let entries: Vec<(String, Entry)> = moved.iter().filter_map(|p| self.remove(p).map(|e| (p.clone(), e))).collect();
        for (p, e) in entries {
            let suffix = &p[from.len()..];
            self.insert(format!("{to}{suffix}"), e);
        }
    }

    pub fn set_stat(&mut self, path: &str, stat: Option<Stat>) {
        if let Some(mut e) = self.get(path) {
            e.stat = stat;
            self.overlay.insert(path.to_string(), Some(e));
        }
    }

    pub fn is_dir(&self, path: &str) -> bool {
        path.is_empty() || self.get(path).is_some_and(|e| e.kind == Kind::Dir)
    }

    /// Unpersisted changes, as rows to upsert and paths to delete. They stay
    /// in the overlay until `persisted` confirms they were written.
    pub fn changes(&self) -> (Vec<MountEntryRow>, Vec<String>) {
        let mut upserts = Vec::new();
        let mut removals = Vec::new();
        for (p, e) in &self.overlay {
            match e {
                Some(e) => upserts.push(MountEntryRow {
                    path: p.clone(),
                    inode: e.inode,
                    kind: e.kind.code(),
                    oid: e.oid,
                    mode: e.exec as u8,
                    mtime_ns: e.stat.map(|s| s.mtime_ns),
                    size: e.stat.map(|s| s.size),
                    ino: e.stat.map(|s| s.ino),
                }),
                None => removals.push(p.clone()),
            }
        }
        (upserts, removals)
    }

    /// The overlay was written; reads go to the store again.
    pub fn persisted(&mut self) {
        let overlay = std::mem::take(&mut self.overlay);
        self.overlay_inode = HashMap::new();
        // Keep the window equal to the store.
        if let Some((lo, hi)) = &self.window_range {
            for (p, e) in overlay {
                if lo.as_str() <= p.as_str() && p.as_str() <= hi.as_str() {
                    match e {
                        Some(e) => self.window.insert(p, e),
                        None => self.window.remove(&p),
                    };
                }
            }
        }
    }

    /// The store connection, when the shadow was released.
    pub fn attach(&mut self, reader: MountReader) {
        self.reader = Some(reader);
    }
}
