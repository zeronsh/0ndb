use std::collections::{HashMap, HashSet};
use std::time::Duration;

use strand_core::{Batch, BatchId, Dag, DagError, History, HistoryId, IntegrateError, Version};

use crate::protocol::{Message, RejectReason, Rejection};

pub type PeerId = u64;

#[derive(Clone, Debug)]
pub struct Outgoing {
    pub to: PeerId,
    pub message: Message,
}

#[derive(Clone, Debug, Default)]
pub struct RelayConfig {
    /// Apply every batch to a full replica and refuse ones that don't apply,
    /// so a buggy or malicious client can't poison other replicas.
    pub validate: bool,
    /// Automatically advance each history's concurrency cutoff to what every
    /// peer ever seen has confirmed, but never past batches admitted less
    /// than this long ago (the grace window for offline devices). Batches
    /// built behind the cutoff are refused, which bounds how far back
    /// concurrent work may reach. `None` leaves the cutoff manual.
    pub cutoff_after: Option<Duration>,
}

/// Where a relay keeps admitted batches.
pub trait RelayStore: Send {
    fn load(&mut self, history: HistoryId) -> Vec<Batch>;
    fn append(&mut self, history: HistoryId, batch: &Batch);
}

#[derive(Default)]
pub struct MemoryRelayStore {
    batches: HashMap<HistoryId, Vec<Batch>>,
}

impl RelayStore for MemoryRelayStore {
    fn load(&mut self, history: HistoryId) -> Vec<Batch> {
        self.batches.get(&history).cloned().unwrap_or_default()
    }

    fn append(&mut self, history: HistoryId, batch: &Batch) {
        self.batches.entry(history).or_default().push(batch.clone());
    }
}

struct Hosted {
    dag: Dag,
    batches: HashMap<BatchId, Batch>,
    admitted_ms: HashMap<BatchId, u64>,
    replica: Option<History>,
    cutoff: Version,
    /// Confirmed version of every peer ever seen.
    peers: HashMap<PeerId, Version>,
    connected: HashSet<PeerId>,
}

/// Relay (server) side as a pure state machine: one admission order per
/// history, fan-out to subscribers.
pub struct Relay<S: RelayStore = MemoryRelayStore> {
    config: RelayConfig,
    store: S,
    hosted: HashMap<HistoryId, Hosted>,
}

fn reason(e: &DagError) -> RejectReason {
    match e {
        DagError::MissingParents { missing, .. } => RejectReason::MissingParents(missing.clone()),
        DagError::LamportViolation { .. } => RejectReason::LamportViolation,
        DagError::InvalidRange { .. } | DagError::Overlap { .. } => RejectReason::InvalidRange,
    }
}

impl Relay<MemoryRelayStore> {
    pub fn in_memory(config: RelayConfig) -> Self {
        Relay::new(config, MemoryRelayStore::default())
    }
}

impl<S: RelayStore> Relay<S> {
    pub fn new(config: RelayConfig, store: S) -> Self {
        Relay { config, store, hosted: HashMap::new() }
    }

    fn hosted(&mut self, history: HistoryId) -> &mut Hosted {
        if !self.hosted.contains_key(&history) {
            let mut h = Hosted {
                dag: Dag::new(),
                batches: HashMap::new(),
                admitted_ms: HashMap::new(),
                replica: self.config.validate.then(|| History::new(history)),
                cutoff: Version::root(),
                peers: HashMap::new(),
                connected: HashSet::new(),
            };
            for b in self.store.load(history) {
                if h.dag.insert(b.header.clone()).is_ok() {
                    if let Some(r) = h.replica.as_mut() {
                        let _ = r.integrate(&b);
                    }
                    h.admitted_ms.insert(b.id(), 0);
                    h.batches.insert(b.id(), b);
                }
            }
            self.hosted.insert(history, h);
        }
        self.hosted.get_mut(&history).expect("just inserted")
    }

    pub fn heads(&mut self, history: HistoryId) -> Version {
        self.hosted(history).dag.heads().clone()
    }

    pub fn cutoff(&mut self, history: HistoryId) -> Version {
        self.hosted(history).cutoff.clone()
    }

    pub fn set_cutoff(&mut self, history: HistoryId, cutoff: Version) {
        self.hosted(history).cutoff = cutoff;
    }

    /// Stops fan-out to a peer. Its confirmed version keeps holding the
    /// cutoff back, so its offline work stays admissible.
    pub fn disconnect(&mut self, peer: PeerId) {
        for h in self.hosted.values_mut() {
            h.connected.remove(&peer);
        }
    }

    fn missing_for(h: &Hosted, have: &Version) -> Vec<Batch> {
        let known: Version = have.heads().filter(|b| h.dag.contains_batch_id(b)).copied().collect();
        let diff = h.dag.difference(h.dag.heads(), &known);
        h.dag.topo_sorted(diff).into_iter().filter_map(|id| h.batches.get(&id).cloned()).collect()
    }

    fn note_peer(h: &mut Hosted, peer: PeerId, seen: &Version) {
        let known: Version = seen.heads().filter(|b| h.dag.contains_batch_id(b)).copied().collect();
        let merged = match h.peers.get(&peer) {
            Some(prev) => h.dag.union(prev, &known),
            None => known,
        };
        h.peers.insert(peer, merged);
    }

    fn advance_cutoff(&mut self, history: HistoryId) -> bool {
        let Some(after) = self.config.cutoff_after else { return false };
        let h = self.hosted(history);
        let versions: Vec<Version> = h.peers.values().cloned().collect();
        if versions.is_empty() {
            return false;
        }
        // Admission order is causal, so "admitted long enough ago" is a
        // downward-closed set and its frontier is a valid version.
        let horizon = strand_core::now_ms().saturating_sub(after.as_millis() as u64);
        let mut eligible = h.dag.closure(&h.dag.common_frontier(&versions));
        eligible.retain(|id| h.admitted_ms.get(id).is_some_and(|t| *t <= horizon));
        let mut has_child = HashSet::new();
        for id in &eligible {
            if let Some(hd) = h.dag.header(id) {
                has_child.extend(hd.parents.heads().copied());
            }
        }
        let common: Version = eligible.into_iter().filter(|id| !has_child.contains(id)).collect();
        if common != h.cutoff && h.dag.includes(&common, &h.cutoff) {
            h.cutoff = common;
            return true;
        }
        false
    }

    fn heads_broadcast(&mut self, history: HistoryId) -> Vec<Outgoing> {
        let h = self.hosted(history);
        let msg = Message::Heads { history, heads: h.dag.heads().clone(), cutoff: h.cutoff.clone() };
        h.connected.iter().map(|p| Outgoing { to: *p, message: msg.clone() }).collect()
    }

    /// Admits one batch or explains why not.
    fn admit(&mut self, history: HistoryId, batch: &Batch) -> Result<bool, RejectReason> {
        let validate = self.config.validate;
        let h = self.hosted(history);
        match h.dag.check(&batch.header) {
            Ok(true) => return Ok(false),
            Ok(false) => {}
            Err(e) => return Err(reason(&e)),
        }
        if !h.dag.includes(&batch.header.parents, &h.cutoff) {
            return Err(RejectReason::BehindCutoff);
        }
        if validate && let Some(r) = h.replica.as_mut() {
            match r.integrate(batch) {
                Ok(_) => {}
                Err(IntegrateError::Op { error, .. }) => {
                    // The replica applied part of the batch; rebuild it.
                    let mut fresh = History::new(history);
                    for id in h.dag.topo_sorted(h.batches.keys().copied()) {
                        let _ = fresh.integrate(&h.batches[&id]);
                    }
                    h.replica = Some(fresh);
                    return Err(RejectReason::Invalid(error.to_string()));
                }
                Err(e) => return Err(RejectReason::Invalid(e.to_string())),
            }
        }
        h.dag.insert(batch.header.clone()).map_err(|e| reason(&e))?;
        h.batches.insert(batch.id(), batch.clone());
        h.admitted_ms.insert(batch.id(), strand_core::now_ms());
        self.store.append(history, batch);
        Ok(true)
    }

    pub fn handle(&mut self, from: PeerId, msg: Message) -> Vec<Outgoing> {
        let history = msg.history();
        let reply = |m: Message| Outgoing { to: from, message: m };
        match msg {
            Message::Hello { heads, .. } => {
                let h = self.hosted(history);
                h.connected.insert(from);
                Self::note_peer(h, from, &heads);
                let batches = Self::missing_for(h, &heads);
                let mut out = Vec::new();
                if !batches.is_empty() {
                    out.push(reply(Message::Batches { history, batches }));
                }
                out.push(reply(Message::Heads { history, heads: h.dag.heads().clone(), cutoff: h.cutoff.clone() }));
                if self.advance_cutoff(history) {
                    out.extend(self.heads_broadcast(history));
                }
                out
            }
            Message::Want { have, .. } => {
                let h = self.hosted(history);
                let batches = Self::missing_for(h, &have);
                if batches.is_empty() { Vec::new() } else { vec![reply(Message::Batches { history, batches })] }
            }
            Message::Have { heads, .. } => {
                let h = self.hosted(history);
                Self::note_peer(h, from, &heads);
                if self.advance_cutoff(history) { self.heads_broadcast(history) } else { Vec::new() }
            }
            Message::Batches { batches, .. } => {
                let mut accepted = Vec::new();
                let mut rejected = Vec::new();
                let mut fresh = Vec::new();
                let mut refused: HashSet<BatchId> = HashSet::new();
                for b in batches {
                    if b.header.parents.heads().any(|p| refused.contains(p)) {
                        refused.insert(b.id());
                        rejected.push(Rejection {
                            batch: b.id(),
                            reason: RejectReason::MissingParents(b.header.parents.heads().copied().collect()),
                        });
                        continue;
                    }
                    match self.admit(history, &b) {
                        Ok(new) => {
                            accepted.push(b.id());
                            if new {
                                fresh.push(b);
                            }
                        }
                        Err(reason) => {
                            refused.insert(b.id());
                            rejected.push(Rejection { batch: b.id(), reason });
                        }
                    }
                }
                let h = self.hosted(history);
                let accepted_version: Version = accepted.iter().copied().collect();
                Self::note_peer(h, from, &accepted_version);
                let mut out = vec![reply(Message::Ack { history, accepted, rejected })];
                if !fresh.is_empty() {
                    let others: Vec<PeerId> = h.connected.iter().filter(|p| **p != from).copied().collect();
                    for p in others {
                        out.push(Outgoing { to: p, message: Message::Batches { history, batches: fresh.clone() } });
                    }
                    self.advance_cutoff(history);
                    out.extend(self.heads_broadcast(history));
                }
                out
            }
            Message::Ack { .. } | Message::Heads { .. } => Vec::new(),
        }
    }
}
