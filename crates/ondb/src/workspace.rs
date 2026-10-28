//! A workspace is one history held in memory, backed by a store, and shared
//! between the mount thread, attribution recorder and sync layer.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use crossbeam_channel::{Receiver, Sender, unbounded};
use ondb_core::{ActorId, Batch, BatchId, History, HistoryId, InodeId, IntegrateError, Integrated, Oid, Op, Txn, Version};
use ondb_store::{HistoryKey, Origin, Store};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::Error;

/// What changed in one batch, kept for fast reporting and attribution.
#[derive(Clone, Debug)]
pub struct BatchSummary {
    pub id: BatchId,
    pub actor: ActorId,
    pub wall_ms: u64,
    pub touched: Arc<[InodeId]>,
    pub meta_keys: Arc<[String]>,
}

impl BatchSummary {
    fn of(batch: &Batch) -> Self {
        let meta_keys: Vec<String> = batch
            .ops
            .iter()
            .filter_map(|op| match op {
                Op::Meta { key, .. } => Some(key.clone()),
                _ => None,
            })
            .collect();
        BatchSummary {
            id: batch.id(),
            actor: batch.header.actor,
            wall_ms: batch.header.wall_ms,
            touched: batch.touched().into(),
            meta_keys: meta_keys.into(),
        }
    }

    /// Batches that only write annotations (registry, scope records).
    pub fn is_annotation_only(&self) -> bool {
        self.touched.is_empty()
    }
}

#[derive(Clone, Debug)]
pub struct Committed {
    pub batch: BatchId,
    pub actor: ActorId,
    pub origin: Origin,
    pub touched: Arc<[InodeId]>,
    pub heads: Version,
}

#[derive(Clone, Debug)]
pub enum Event {
    Committed(Committed),
    /// In-memory state was rebuilt from storage (after a rejected batch).
    Reloaded,
}

#[derive(Clone, Debug, Default)]
pub struct IntegrateReport {
    pub applied: Vec<BatchId>,
    pub duplicates: Vec<BatchId>,
    /// Waiting for parents that haven't arrived.
    pub waiting: Vec<BatchId>,
    pub rejected: Vec<(BatchId, String)>,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ActorKind {
    Human,
    Agent,
    Ingestion,
    System,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActorInfo {
    pub name: String,
    pub kind: ActorKind,
    pub replica: Uuid,
    pub created_ms: u64,
}

pub fn actor_key(actor: &ActorId) -> String {
    format!("actor/{}", actor.0)
}

struct Inner {
    store: Store,
    key: HistoryKey,
    history: History,
    summaries: HashMap<BatchId, BatchSummary>,
    /// Remote batches waiting for parents, by id.
    waiting: HashMap<BatchId, Batch>,
    rejected: HashSet<BatchId>,
    replica: Uuid,
}

impl Inner {
    fn summary(&mut self, id: &BatchId) -> Result<BatchSummary, Error> {
        if let Some(s) = self.summaries.get(id) {
            return Ok(s.clone());
        }
        let batch = self.store.batch(self.key, id)?.ok_or_else(|| Error::Invalid(format!("unknown batch {id:?}")))?;
        let s = BatchSummary::of(&batch);
        self.summaries.insert(*id, s.clone());
        Ok(s)
    }

    /// Writes the batch and the state it changed in one transaction. If
    /// that fails, memory is rebuilt from storage so the two never diverge.
    fn persist(&mut self, batch: &Batch, origin: Origin) -> Result<(), Error> {
        if let Err(e) = self.store.append(self.key, batch, origin, &mut self.history) {
            let id = self.history.id();
            if let Ok((_, h)) = self.store.load(id) {
                self.history = h;
            }
            return Err(e.into());
        }
        self.summaries.insert(batch.id(), BatchSummary::of(batch));
        Ok(())
    }
}

/// Read access handed to closures that need a consistent snapshot.
pub struct ReadCtx<'a> {
    inner: &'a mut Inner,
}

impl ReadCtx<'_> {
    pub fn history(&self) -> &History {
        &self.inner.history
    }

    pub fn summary(&mut self, id: &BatchId) -> Result<BatchSummary, Error> {
        self.inner.summary(id)
    }

    /// Inodes touched by any batch in `ids`, plus descendants of touched
    /// directories (at the current state).
    pub fn touched_by(&mut self, ids: impl IntoIterator<Item = BatchId>) -> Result<HashSet<InodeId>, Error> {
        let mut out = HashSet::new();
        for id in ids {
            out.extend(self.inner.summary(&id)?.touched.iter().copied());
        }
        let h = &self.inner.history;
        let view = h.current();
        let dirs: Vec<InodeId> = out.iter().filter(|i| h.inode(i).is_some_and(|n| n.is_dir())).copied().collect();
        for d in dirs {
            out.extend(h.tree().descendants(&view, &d));
        }
        Ok(out)
    }

    pub fn store(&mut self) -> (&mut Store, HistoryKey) {
        (&mut self.inner.store, self.inner.key)
    }

    pub fn blob(&self, oid: &Oid) -> Result<Option<Vec<u8>>, Error> {
        Ok(self.inner.store.blob(oid)?)
    }
}

#[derive(Clone)]
pub struct Workspace {
    inner: Arc<Mutex<Inner>>,
    subscribers: Arc<Mutex<Vec<Sender<Event>>>>,
    id: HistoryId,
}

impl Workspace {
    /// Opens the store at `path`. Uses the given history, the store's only
    /// history, or creates a new one.
    pub fn open(path: impl AsRef<Path>, history: Option<HistoryId>) -> Result<Self, Error> {
        Self::from_store(Store::open(path)?, history)
    }

    pub fn in_memory(history: Option<HistoryId>) -> Result<Self, Error> {
        Self::from_store(Store::open_in_memory()?, history)
    }

    fn from_store(mut store: Store, history: Option<HistoryId>) -> Result<Self, Error> {
        let id = match history {
            Some(id) => id,
            None => match store.histories()?.as_slice() {
                [] => HistoryId::random(),
                [only] => *only,
                _ => return Err(Error::Invalid("store holds several histories; pick one".into())),
            },
        };
        store.create_history(id)?;
        let (key, history) = store.load(id)?;
        let replica = match store.local_get("replica")? {
            Some(b) => Uuid::from_slice(&b).map_err(|e| Error::Invalid(e.to_string()))?,
            None => {
                let r = Uuid::new_v4();
                store.local_set("replica", r.as_bytes())?;
                r
            }
        };
        let inner =
            Inner { store, key, history, summaries: HashMap::new(), waiting: HashMap::new(), rejected: HashSet::new(), replica };
        Ok(Workspace { inner: Arc::new(Mutex::new(inner)), subscribers: Arc::new(Mutex::new(Vec::new())), id })
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn id(&self) -> HistoryId {
        self.id
    }

    pub fn replica(&self) -> Uuid {
        self.lock().replica
    }

    pub fn heads(&self) -> Version {
        self.lock().history.heads().clone()
    }

    pub fn subscribe(&self) -> Receiver<Event> {
        let (tx, rx) = unbounded();
        self.subscribers.lock().unwrap_or_else(|p| p.into_inner()).push(tx);
        rx
    }

    fn emit(&self, events: Vec<Event>) {
        if events.is_empty() {
            return;
        }
        let mut subs = self.subscribers.lock().unwrap_or_else(|p| p.into_inner());
        subs.retain(|s| events.iter().all(|e| s.send(e.clone()).is_ok()));
    }

    pub fn read<R>(&self, f: impl FnOnce(&History) -> R) -> R {
        f(&self.lock().history)
    }

    /// Consistent read with access to batch summaries, blobs and the store.
    pub fn with<R>(&self, f: impl FnOnce(&mut ReadCtx<'_>) -> R) -> R {
        let mut guard = self.lock();
        f(&mut ReadCtx { inner: &mut guard })
    }

    /// Authors one batch as `actor` on top of `parents` (default: heads),
    /// persists it, and notifies subscribers. Returns `None` if `f` pushed
    /// nothing.
    pub fn commit<R>(
        &self,
        actor: ActorId,
        parents: Option<Version>,
        f: impl FnOnce(&mut Txn<'_>) -> Result<R, Error>,
    ) -> Result<(Option<BatchId>, R), Error> {
        let (event, out) = {
            let mut guard = self.lock();
            let inner = &mut *guard;
            let (batch, result) = inner.history.transact(actor, parents, f)?;
            let event = match &batch {
                Some(b) => {
                    inner.persist(b, Origin::Local)?;
                    Some(Event::Committed(Committed {
                        batch: b.id(),
                        actor,
                        origin: Origin::Local,
                        touched: b.touched().into(),
                        heads: inner.history.heads().clone(),
                    }))
                }
                None => None,
            };
            (event, result.map(|r| (batch.map(|b| b.id()), r)))
        };
        self.emit(event.into_iter().collect());
        out
    }

    /// Applies remote batches in causal order, buffering any whose parents
    /// are still missing. A batch that is admitted causally but fails to
    /// apply is rejected and the in-memory state is rebuilt from storage.
    pub fn integrate(&self, batches: Vec<Batch>) -> Result<IntegrateReport, Error> {
        let mut report = IntegrateReport::default();
        let mut events = Vec::new();
        {
            let mut guard = self.lock();
            let inner = &mut *guard;
            for b in batches {
                let id = b.id();
                if inner.rejected.contains(&id) {
                    report.rejected.push((id, "previously rejected".into()));
                } else if inner.history.dag().contains_batch_id(&id) {
                    report.duplicates.push(id);
                } else {
                    inner.waiting.insert(id, b);
                }
            }
            loop {
                let mut ready: Vec<BatchId> = inner
                    .waiting
                    .values()
                    .filter(|b| inner.history.dag().missing_parents(&b.header.parents).is_empty())
                    .map(|b| b.id())
                    .collect();
                if ready.is_empty() {
                    break;
                }
                ready.sort_by_key(|id| (inner.waiting[id].header.start, id.actor));
                for id in ready {
                    let batch = inner.waiting.remove(&id).expect("ready batch");
                    match inner.history.integrate(&batch) {
                        Ok(Integrated::Duplicate) => report.duplicates.push(id),
                        Ok(Integrated::Applied { touched }) => {
                            inner.persist(&batch, Origin::Remote)?;
                            report.applied.push(id);
                            events.push(Event::Committed(Committed {
                                batch: id,
                                actor: batch.header.actor,
                                origin: Origin::Remote,
                                touched: touched.into(),
                                heads: inner.history.heads().clone(),
                            }));
                        }
                        Err(IntegrateError::Op { error, .. }) => {
                            tracing::warn!(batch = ?id, %error, "rejecting batch that does not apply; reloading");
                            inner.rejected.insert(id);
                            report.rejected.push((id, error.to_string()));
                            let (_, reloaded) = inner.store.load(self.id)?;
                            inner.history = reloaded;
                            events.push(Event::Reloaded);
                        }
                        Err(e) => {
                            inner.rejected.insert(id);
                            report.rejected.push((id, e.to_string()));
                        }
                    }
                }
            }
            report.waiting = inner.waiting.keys().copied().collect();
        }
        self.emit(events);
        Ok(report)
    }

    /// Ids still waiting for parents, and the parents they're missing.
    pub fn missing_parents(&self) -> Vec<BatchId> {
        let inner = self.lock();
        let mut missing: HashSet<BatchId> = HashSet::new();
        for b in inner.waiting.values() {
            for p in inner.history.dag().missing_parents(&b.header.parents) {
                if !inner.waiting.contains_key(&p) {
                    missing.insert(p);
                }
            }
        }
        missing.into_iter().collect()
    }

    pub fn unpushed(&self) -> Result<Vec<Batch>, Error> {
        let mut inner = self.lock();
        let key = inner.key;
        Ok(inner.store.unpushed(key)?)
    }

    pub fn mark_pushed(&self, ids: &[BatchId]) -> Result<(), Error> {
        let mut inner = self.lock();
        let key = inner.key;
        Ok(inner.store.mark_pushed(key, ids)?)
    }

    /// Every batch not included by `have` (unknown heads are ignored), in
    /// causal order, with blobs attached.
    pub fn batches_missing_from(&self, have: &Version) -> Result<Vec<Batch>, Error> {
        let mut inner = self.lock();
        let known: Version = have.heads().filter(|h| inner.history.dag().contains_batch_id(h)).copied().collect();
        let diff = inner.history.dag().difference(inner.history.heads(), &known);
        let ordered = inner.history.dag().topo_sorted(diff);
        let key = inner.key;
        let mut out = Vec::with_capacity(ordered.len());
        for id in ordered {
            out.push(inner.store.batch(key, &id)?.ok_or_else(|| Error::Invalid(format!("missing batch {id:?}")))?);
        }
        Ok(out)
    }

    pub fn batch(&self, id: &BatchId) -> Result<Option<Batch>, Error> {
        let mut inner = self.lock();
        let key = inner.key;
        Ok(inner.store.batch(key, id)?)
    }

    pub fn summary(&self, id: &BatchId) -> Result<BatchSummary, Error> {
        self.lock().summary(id)
    }

    pub fn blob(&self, oid: &Oid) -> Result<Option<Vec<u8>>, Error> {
        Ok(self.lock().store.blob(oid)?)
    }

    /// The local actor for `(kind, name)`, created and registered on first
    /// use. Actor ids are per replica, never shared between devices.
    pub fn actor(&self, name: &str, kind: ActorKind) -> Result<ActorId, Error> {
        let local_key = format!("actor:{kind:?}:{name}");
        let (existing, replica) = {
            let inner = self.lock();
            (inner.store.local_get(&local_key)?, inner.replica)
        };
        if let Some(bytes) = existing {
            return Ok(ActorId(Uuid::from_slice(&bytes).map_err(|e| Error::Invalid(e.to_string()))?));
        }
        let actor = ActorId::random();
        let info = ActorInfo { name: name.to_string(), kind, replica, created_ms: ondb_core::now_ms() };
        let value = postcard::to_stdvec(&info).map_err(|e| Error::Invalid(e.to_string()))?;
        self.commit(actor, None, |txn| Ok(txn.push(Op::Meta { key: actor_key(&actor), value: Some(value) })?))?;
        self.lock().store.local_set(&local_key, actor.0.as_bytes())?;
        Ok(actor)
    }

    pub fn actor_info(&self, actor: &ActorId) -> Option<ActorInfo> {
        self.read(|h| h.meta(&actor_key(actor)).and_then(|v| postcard::from_bytes(v).ok()))
    }

    pub fn actors(&self) -> Vec<(ActorId, ActorInfo)> {
        self.read(|h| {
            h.meta_with_prefix("actor/")
                .filter_map(|(k, v)| {
                    let id = Uuid::parse_str(k.strip_prefix("actor/")?).ok()?;
                    Some((ActorId(id), postcard::from_bytes(v).ok()?))
                })
                .collect()
        })
    }

    pub fn local_get(&self, key: &str) -> Result<Option<Vec<u8>>, Error> {
        Ok(self.lock().store.local_get(key)?)
    }

    pub fn local_set(&self, key: &str, value: &[u8]) -> Result<(), Error> {
        Ok(self.lock().store.local_set(key, value)?)
    }
}
