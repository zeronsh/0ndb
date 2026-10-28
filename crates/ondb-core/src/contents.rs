//! Bytes behind text fragments. Small insertions (typed edits, patches) are
//! held inline; large ones (initial file contents, big pastes) are
//! content-addressed blobs read lazily through a [`BlobSource`] and kept in
//! a bounded LRU cache, so untouched large files cost no memory.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::id::{Oid, OpId};
use crate::op::BlobRef;

/// Insertions at most this large are stored inline in their op.
pub const INLINE_TEXT_MAX: usize = 4096;
const CACHE_BYTES: usize = 64 << 20;

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

/// Where blob bytes come from (typically a read connection to the store).
pub trait BlobSource: Send + Sync {
    fn blob(&self, oid: &Oid) -> Option<Vec<u8>>;
}

#[derive(Default)]
struct Cache {
    map: HashMap<Oid, (Arc<[u8]>, u64)>,
    bytes: usize,
    tick: u64,
}

impl Cache {
    fn get(&mut self, oid: &Oid) -> Option<Arc<[u8]>> {
        self.tick += 1;
        let tick = self.tick;
        self.map.get_mut(oid).map(|(b, t)| {
            *t = tick;
            b.clone()
        })
    }

    fn put(&mut self, oid: Oid, data: Arc<[u8]>) {
        self.tick += 1;
        if let Some((old, _)) = self.map.insert(oid, (data.clone(), self.tick)) {
            self.bytes -= old.len();
        }
        self.bytes += data.len();
        while self.bytes > CACHE_BYTES && self.map.len() > 1 {
            let victim = self.map.iter().filter(|(o, _)| **o != oid).min_by_key(|(_, (_, t))| *t).map(|(o, _)| *o);
            let Some(victim) = victim else { break };
            if let Some((b, _)) = self.map.remove(&victim) {
                self.bytes -= b.len();
            }
        }
    }
}

#[derive(Default, Serialize, Deserialize)]
pub struct Contents {
    map: HashMap<InsertionKey, Insertion>,
    #[serde(skip)]
    source: Option<Arc<dyn BlobSource>>,
    #[serde(skip)]
    cache: Mutex<Cache>,
}

impl Clone for Contents {
    fn clone(&self) -> Self {
        Contents { map: self.map.clone(), source: self.source.clone(), cache: Mutex::default() }
    }
}

impl Contents {
    pub fn set_source(&mut self, source: Arc<dyn BlobSource>) {
        self.source = Some(source);
    }

    pub fn insert(&mut self, key: InsertionKey, ins: Insertion) {
        self.map.insert(key, ins);
    }

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

    /// Makes freshly received blob bytes available without a store round trip.
    pub fn offer_blob(&self, oid: Oid, data: Arc<[u8]>) {
        self.cache.lock().unwrap_or_else(|p| p.into_inner()).put(oid, data);
    }

    /// All bytes of an insertion; `None` if a blob isn't available locally.
    pub fn bytes(&self, key: &InsertionKey) -> Option<Arc<[u8]>> {
        match self.map.get(key)? {
            Insertion::Bytes(b) => Some(b.clone()),
            Insertion::Blob(r) => {
                let mut cache = self.cache.lock().unwrap_or_else(|p| p.into_inner());
                if let Some(b) = cache.get(&r.oid) {
                    return Some(b);
                }
                let data: Arc<[u8]> = self.source.as_ref()?.blob(&r.oid)?.into();
                cache.put(r.oid, data.clone());
                Some(data)
            }
        }
    }
}
