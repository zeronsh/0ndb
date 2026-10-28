use std::collections::{BTreeMap, HashMap, HashSet};

use ondb_core::{InodeId, Oid};
use ondb_store::MountEntryRow;

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

/// The disk as of the mount's synced version. Changes to it are tracked so
/// they can be persisted incrementally.
#[derive(Default)]
pub struct Shadow {
    by_path: BTreeMap<String, Entry>,
    by_inode: HashMap<InodeId, String>,
    dirty: HashSet<String>,
    removed: HashSet<String>,
}

impl Shadow {
    pub fn from_rows(rows: Vec<MountEntryRow>) -> Shadow {
        let mut s = Shadow::default();
        for r in rows {
            let stat = match (r.mtime_ns, r.size, r.ino) {
                (Some(mtime_ns), Some(size), Some(ino)) => Some(Stat { mtime_ns, size, ino }),
                _ => None,
            };
            let e = Entry { inode: r.inode, kind: Kind::from_code(r.kind), oid: r.oid, exec: r.mode == 1, stat };
            s.by_inode.insert(e.inode, r.path.clone());
            s.by_path.insert(r.path, e);
        }
        s
    }

    pub fn is_empty(&self) -> bool {
        self.by_path.is_empty()
    }

    pub fn get(&self, path: &str) -> Option<&Entry> {
        self.by_path.get(path)
    }

    pub fn path_of(&self, inode: &InodeId) -> Option<&str> {
        self.by_inode.get(inode).map(|s| s.as_str())
    }

    pub fn paths(&self) -> impl Iterator<Item = &String> {
        self.by_path.keys()
    }

    /// Paths strictly under `dir`.
    pub fn under(&self, dir: &str) -> Vec<String> {
        let start = format!("{dir}/");
        self.by_path.range(start.clone()..).take_while(|(p, _)| p.starts_with(&start)).map(|(p, _)| p.clone()).collect()
    }

    pub fn insert(&mut self, path: String, entry: Entry) {
        if let Some(old) = self.by_inode.get(&entry.inode).cloned()
            && old != path
        {
            self.remove(&old);
        }
        if let Some(prev) = self.by_path.get(&path)
            && prev.inode != entry.inode
        {
            self.by_inode.remove(&prev.inode);
        }
        self.by_inode.insert(entry.inode, path.clone());
        self.removed.remove(&path);
        self.dirty.insert(path.clone());
        self.by_path.insert(path, entry);
    }

    pub fn remove(&mut self, path: &str) -> Option<Entry> {
        let e = self.by_path.remove(path)?;
        if self.by_inode.get(&e.inode).is_some_and(|p| p == path) {
            self.by_inode.remove(&e.inode);
        }
        self.dirty.remove(path);
        self.removed.insert(path.to_string());
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
        if let Some(e) = self.by_path.get_mut(path) {
            e.stat = stat;
            self.dirty.insert(path.to_string());
        }
    }

    pub fn is_dir(&self, path: &str) -> bool {
        path.is_empty() || self.by_path.get(path).is_some_and(|e| e.kind == Kind::Dir)
    }

    /// Changes since the last call, as rows to upsert and paths to delete.
    pub fn take_changes(&mut self) -> (Vec<MountEntryRow>, Vec<String>) {
        let upserts = self
            .dirty
            .drain()
            .filter_map(|p| {
                let e = self.by_path.get(&p)?;
                Some(MountEntryRow {
                    path: p,
                    inode: e.inode,
                    kind: e.kind.code(),
                    oid: e.oid,
                    mode: e.exec as u8,
                    mtime_ns: e.stat.map(|s| s.mtime_ns),
                    size: e.stat.map(|s| s.size),
                    ino: e.stat.map(|s| s.ino),
                })
            })
            .collect();
        (upserts, self.removed.drain().collect())
    }
}
