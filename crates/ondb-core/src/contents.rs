//! Bytes behind text fragments.
//!
//! Memory holds only what isn't durable yet: insertions and blobs created
//! since the last persist. Everything else is read on demand through a
//! [`BlobSource`] (the store) and kept in one process-wide LRU cache with a
//! fixed byte budget, shared by every history in the process. Blobs are
//! content-addressed, so worktrees of the same repository share cached
//! bytes. A history without a source keeps everything in memory.

use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde::{Deserialize, Serialize};

use crate::id::{Oid, OpId};
use crate::op::BlobRef;

/// Insertions at most this large are stored inline in their op.
pub const INLINE_TEXT_MAX: usize = 4096;
const DEFAULT_CACHE_BYTES: usize = 32 << 20;
/// Bookkeeping charged per cached entry, so many tiny entries can't exceed
/// the budget in practice.
const ENTRY_OVERHEAD: usize = 96;

/// `(op, part)`: part distinguishes the files of one import op.
pub type InsertionKey = (OpId, u32);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Insertion {
    Bytes(Arc<[u8]>),
    Blob(BlobRef),
}

impl Insertion {
    pub fn len(&self) -> u64 {
        match self {
            Insertion::Bytes(b) => b.len() as u64,
            Insertion::Blob(r) => r.len,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Where durable bytes come from (typically a read connection to the store).
pub trait BlobSource: Send + Sync {
    fn blob(&self, oid: &Oid) -> Option<Vec<u8>>;
    /// A persisted insertion. Sources that can't serve insertions return
    /// `None`, and histories using them keep insertions in memory.
    fn insertion(&self, _key: &InsertionKey) -> Option<Insertion> {
        None
    }
    fn serves_insertions(&self) -> bool {
        false
    }
}

/// Content-addressed bytes kept outside 0ndb's store, addressed by the same
/// object ids (git's blob ids): typically the repository's own object
/// database, so content git already holds is never copied.
pub trait ObjectStore: Send + Sync {
    fn contains(&self, oid: &Oid) -> bool;
    fn read(&self, oid: &Oid) -> Option<Vec<u8>>;
    /// Makes sure the objects stay available (e.g. reachable from a ref so
    /// git's garbage collection keeps them). `false` means they can't be
    /// relied on and must be stored by 0ndb.
    fn pin(&self, oids: &[Oid]) -> bool;
    /// Drops caches and helper processes while the history is idle.
    fn release(&self) {}
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
enum Key {
    Blob(Oid),
    Insertion(InsertionKey),
}

/// Process-wide LRU over immutable bytes.
#[derive(Default)]
struct Cache {
    map: HashMap<Key, (Arc<[u8]>, u64)>,
    order: BTreeMap<u64, Key>,
    bytes: usize,
    tick: u64,
}

static BUDGET: AtomicUsize = AtomicUsize::new(DEFAULT_CACHE_BYTES);

fn cache() -> std::sync::MutexGuard<'static, Cache> {
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    CACHE.get_or_init(Mutex::default).lock().unwrap_or_else(|p| p.into_inner())
}

/// Sets the byte budget of the process-wide content cache.
pub fn set_cache_budget(bytes: usize) {
    BUDGET.store(bytes, Ordering::Relaxed);
    cache().evict();
}

/// Bytes currently held by the process-wide content cache.
pub fn cache_bytes() -> usize {
    cache().bytes
}

impl Cache {
    fn get(&mut self, key: &Key) -> Option<Arc<[u8]>> {
        self.tick += 1;
        let tick = self.tick;
        let (bytes, t) = self.map.get_mut(key)?;
        self.order.remove(t);
        self.order.insert(tick, *key);
        *t = tick;
        Some(bytes.clone())
    }

    fn put(&mut self, key: Key, data: Arc<[u8]>) {
        self.tick += 1;
        if let Some((old, t)) = self.map.insert(key, (data.clone(), self.tick)) {
            self.order.remove(&t);
            self.bytes -= old.len() + ENTRY_OVERHEAD;
        }
        self.order.insert(self.tick, key);
        self.bytes += data.len() + ENTRY_OVERHEAD;
        self.evict();
    }

    /// Drops least recently used entries until within budget. The newest
    /// entry is never dropped, so a single oversized read still succeeds.
    fn evict(&mut self) {
        let budget = BUDGET.load(Ordering::Relaxed);
        while self.bytes > budget && self.order.len() > 1 {
            let Some((_, victim)) = self.order.pop_first() else { break };
            if let Some((b, _)) = self.map.remove(&victim) {
                self.bytes -= b.len() + ENTRY_OVERHEAD;
            }
        }
    }
}

#[derive(Default, Serialize, Deserialize)]
pub struct Contents {
    /// Insertions not yet known to be durable (all of them without a source
    /// that serves insertions).
    map: HashMap<InsertionKey, Insertion>,
    /// Blobs not yet known to be durable.
    #[serde(skip)]
    pending_blobs: HashMap<Oid, Arc<[u8]>>,
    #[serde(skip)]
    source: Option<Arc<dyn BlobSource>>,
}

impl Clone for Contents {
    fn clone(&self) -> Self {
        Contents { map: self.map.clone(), pending_blobs: self.pending_blobs.clone(), source: self.source.clone() }
    }
}

impl Contents {
    pub fn set_source(&mut self, source: Arc<dyn BlobSource>) {
        self.source = Some(source);
    }

    pub fn insert(&mut self, key: InsertionKey, ins: Insertion) {
        self.map.insert(key, ins);
    }

    /// An insertion held in memory (not yet persisted).
    pub fn get(&self, key: &InsertionKey) -> Option<&Insertion> {
        self.map.get(key)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&InsertionKey, &Insertion)> {
        self.map.iter()
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    /// Makes freshly created or received blob bytes available until they are
    /// persisted.
    pub fn offer_blob(&mut self, oid: Oid, data: Arc<[u8]>) {
        self.pending_blobs.insert(oid, data);
    }

    /// The source now holds these insertions and blobs durably: release them
    /// from memory into the shared, evictable cache.
    pub fn persisted(&mut self, insertions: &[InsertionKey], blobs: &[Oid]) {
        let Some(source) = &self.source else { return };
        let mut c = cache();
        for oid in blobs {
            if let Some(data) = self.pending_blobs.remove(oid) {
                c.put(Key::Blob(*oid), data);
            }
        }
        if source.serves_insertions() {
            for k in insertions {
                if let Some(Insertion::Bytes(b)) = self.map.remove(k) {
                    c.put(Key::Insertion(*k), b);
                }
            }
        }
    }

    /// All bytes of an insertion; `None` if a blob isn't available locally.
    pub fn bytes(&self, key: &InsertionKey) -> Option<Arc<[u8]>> {
        let ins = match self.map.get(key) {
            Some(Insertion::Bytes(b)) => return Some(b.clone()),
            Some(ins) => ins.clone(),
            None => {
                if let Some(b) = cache().get(&Key::Insertion(*key)) {
                    return Some(b);
                }
                let ins = self.source.as_ref()?.insertion(key)?;
                if let Insertion::Bytes(b) = &ins {
                    cache().put(Key::Insertion(*key), b.clone());
                    return Some(b.clone());
                }
                ins
            }
        };
        let Insertion::Blob(r) = ins else { unreachable!() };
        self.blob(&r.oid)
    }

    fn blob(&self, oid: &Oid) -> Option<Arc<[u8]>> {
        if let Some(b) = self.pending_blobs.get(oid) {
            return Some(b.clone());
        }
        if let Some(b) = cache().get(&Key::Blob(*oid)) {
            return Some(b);
        }
        let data: Arc<[u8]> = self.source.as_ref()?.blob(oid)?.into();
        cache().put(Key::Blob(*oid), data.clone());
        Some(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lru_respects_budget_and_recency() {
        let mut c = Cache::default();
        let budget = BUDGET.load(Ordering::Relaxed);
        let chunk = budget / 4;
        let oid = |i: u8| Key::Blob(Oid([i; 20]));
        for i in 0..4 {
            c.put(oid(i), vec![0u8; chunk - ENTRY_OVERHEAD].into());
        }
        assert!(c.get(&oid(0)).is_some());
        c.put(oid(9), vec![0u8; chunk].into());
        assert!(c.bytes <= budget);
        assert!(c.get(&oid(0)).is_some(), "recently used entry survives");
        assert!(c.get(&oid(1)).is_none(), "least recently used entry is evicted");
        assert!(c.get(&oid(9)).is_some());
    }
}
