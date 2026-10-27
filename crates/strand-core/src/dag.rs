use std::collections::{BTreeMap, BinaryHeap, HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::id::{ActorId, BatchId, Lamport, OpId};
use crate::version::Version;

/// Causal metadata for one batch: a contiguous run of operations by one actor
/// (timestamps `start..=end`), all made on top of `parents`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BatchHeader {
    pub actor: ActorId,
    pub start: Lamport,
    pub end: Lamport,
    pub parents: Version,
    /// Wall-clock milliseconds when the batch was authored (informational).
    pub wall_ms: u64,
}

impl BatchHeader {
    pub fn id(&self) -> BatchId {
        OpId::new(self.end, self.actor)
    }

    pub fn len(&self) -> u64 {
        self.end - self.start + 1
    }

    pub fn is_empty(&self) -> bool {
        false
    }

    pub fn op_id(&self, index: usize) -> OpId {
        OpId::new(self.start + index as u64, self.actor)
    }

    pub fn contains_op(&self, op: OpId) -> bool {
        op.actor == self.actor && (self.start..=self.end).contains(&op.ts)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DagError {
    #[error("batch {batch:?} references unknown parents {missing:?}")]
    MissingParents { batch: BatchId, missing: Vec<BatchId> },
    #[error("batch {batch:?} starts at {start}, not after its parent frontier ({parent_max})")]
    LamportViolation { batch: BatchId, start: Lamport, parent_max: Lamport },
    #[error("batch {batch:?} has an invalid timestamp range")]
    InvalidRange { batch: BatchId },
    #[error("batch {batch:?} overlaps existing batch {existing:?} of the same actor")]
    Overlap { batch: BatchId, existing: BatchId },
}

/// The causal graph of batches. Operations are located by `(actor, ts)` in a
/// per-actor index of contiguous runs.
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Dag {
    headers: HashMap<BatchId, BatchHeader>,
    /// actor -> (end -> start)
    by_actor: HashMap<ActorId, BTreeMap<Lamport, Lamport>>,
    heads: Version,
    max_ts: Lamport,
}

impl Dag {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn heads(&self) -> &Version {
        &self.heads
    }

    pub fn max_ts(&self) -> Lamport {
        self.max_ts
    }

    pub fn len(&self) -> usize {
        self.headers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.headers.is_empty()
    }

    pub fn header(&self, id: &BatchId) -> Option<&BatchHeader> {
        self.headers.get(id)
    }

    pub fn contains_batch_id(&self, id: &BatchId) -> bool {
        self.headers.contains_key(id)
    }

    pub fn headers(&self) -> impl Iterator<Item = &BatchHeader> {
        self.headers.values()
    }

    pub fn missing_parents(&self, parents: &Version) -> Vec<BatchId> {
        parents.heads().filter(|p| !self.headers.contains_key(p)).copied().collect()
    }

    /// Checks every admission rule without mutating. `Ok(true)` means the batch
    /// is already present with an identical header (idempotent re-delivery).
    pub fn check(&self, h: &BatchHeader) -> Result<bool, DagError> {
        let id = h.id();
        if h.end < h.start || h.start == 0 {
            return Err(DagError::InvalidRange { batch: id });
        }
        if let Some(existing) = self.headers.get(&id) {
            if existing.start == h.start && existing.parents == h.parents {
                return Ok(true);
            }
            return Err(DagError::Overlap { batch: id, existing: id });
        }
        let missing = self.missing_parents(&h.parents);
        if !missing.is_empty() {
            return Err(DagError::MissingParents { batch: id, missing });
        }
        let parent_max = h.parents.max_ts();
        if h.start <= parent_max {
            return Err(DagError::LamportViolation { batch: id, start: h.start, parent_max });
        }
        if let Some(runs) = self.by_actor.get(&h.actor)
            && let Some((&end, &start)) = runs.range(h.start..).next()
            && start <= h.end
        {
            return Err(DagError::Overlap { batch: id, existing: OpId::new(end, h.actor) });
        }
        Ok(false)
    }

    /// Inserts a header whose parents are all present. Returns `false` if the
    /// identical header was already present.
    pub fn insert(&mut self, h: BatchHeader) -> Result<bool, DagError> {
        if self.check(&h)? {
            return Ok(false);
        }
        let id = h.id();
        for p in h.parents.heads() {
            self.heads.remove(p);
        }
        // A new batch never has known children: children are only admitted
        // after their parents.
        self.heads.insert(id);
        self.max_ts = self.max_ts.max(h.end);
        self.by_actor.entry(h.actor).or_default().insert(h.end, h.start);
        self.headers.insert(id, h);
        Ok(true)
    }

    /// The batch containing an operation, if known.
    pub fn batch_of(&self, op: OpId) -> Option<BatchId> {
        let runs = self.by_actor.get(&op.actor)?;
        let (&end, &start) = runs.range(op.ts..).next()?;
        (start <= op.ts).then(|| OpId::new(end, op.actor))
    }

    /// Whether `version` causally includes the batch `target`.
    pub fn version_contains_batch(&self, version: &Version, target: &BatchId) -> bool {
        if version.contains_head(target) {
            return true;
        }
        let mut stack: Vec<BatchId> = version.heads().copied().collect();
        let mut seen = HashSet::new();
        while let Some(id) = stack.pop() {
            if id == *target {
                return true;
            }
            // An ancestor always ends before its descendants start, so nothing
            // at or below the target's end can reach it.
            if id.ts <= target.ts || !seen.insert(id) {
                continue;
            }
            if let Some(h) = self.headers.get(&id) {
                stack.extend(h.parents.heads().copied());
            }
        }
        false
    }

    pub fn version_contains_op(&self, version: &Version, op: OpId) -> bool {
        self.batch_of(op).is_some_and(|b| self.version_contains_batch(version, &b))
    }

    /// `a` causally includes everything in `b`.
    pub fn includes(&self, a: &Version, b: &Version) -> bool {
        b.heads().all(|h| self.version_contains_batch(a, h))
    }

    /// Batches reachable from `a` but not from `b`. Walks both frontiers in
    /// descending timestamp order and stops once only `b`-reachable work
    /// remains, so the cost is proportional to the divergence, not the history.
    pub fn difference(&self, a: &Version, b: &Version) -> HashSet<BatchId> {
        let mut out = HashSet::new();
        if a == b {
            return out;
        }
        // state: true = reachable from b
        let mut state: HashMap<BatchId, bool> = HashMap::new();
        let mut heap: BinaryHeap<BatchId> = BinaryHeap::new();
        let mut outside = 0usize;
        let push =
            |id: BatchId, in_b: bool, state: &mut HashMap<BatchId, bool>, heap: &mut BinaryHeap<BatchId>, outside: &mut usize| {
                match state.get_mut(&id) {
                    None => {
                        state.insert(id, in_b);
                        heap.push(id);
                        if !in_b {
                            *outside += 1;
                        }
                    }
                    Some(s) => {
                        if in_b && !*s {
                            *s = true;
                            *outside -= 1;
                        }
                    }
                }
            };
        for h in b.heads() {
            push(*h, true, &mut state, &mut heap, &mut outside);
        }
        for h in a.heads() {
            push(*h, false, &mut state, &mut heap, &mut outside);
        }
        let mut done: HashSet<BatchId> = HashSet::new();
        while outside > 0 {
            let Some(id) = heap.pop() else { break };
            if !done.insert(id) {
                continue;
            }
            let in_b = state[&id];
            if !in_b {
                outside -= 1;
                out.insert(id);
            }
            if let Some(h) = self.headers.get(&id) {
                for p in h.parents.heads() {
                    push(*p, in_b, &mut state, &mut heap, &mut outside);
                }
            }
        }
        out
    }

    /// Smallest frontier including both versions.
    pub fn union(&self, a: &Version, b: &Version) -> Version {
        let candidates: Vec<BatchId> = a.heads().chain(b.heads()).copied().collect::<HashSet<_>>().into_iter().collect();
        self.frontier_of(&candidates)
    }

    /// Reduces a set of batches to the antichain of those not included by
    /// another member.
    pub fn frontier_of(&self, ids: &[BatchId]) -> Version {
        ids.iter()
            .filter(|c| !ids.iter().any(|o| o != *c && o.ts > c.ts && self.version_contains_batch(&Version::single(*o), c)))
            .copied()
            .collect()
    }

    /// Frontier of the batches included by every given version.
    pub fn common_frontier(&self, versions: &[Version]) -> Version {
        let Some((first, rest)) = versions.split_first() else { return Version::root() };
        let mut common = self.closure(first);
        for v in rest {
            let other = self.closure(v);
            common.retain(|id| other.contains(id));
        }
        let mut has_child: HashSet<BatchId> = HashSet::new();
        for id in &common {
            if let Some(h) = self.headers.get(id) {
                has_child.extend(h.parents.heads().copied());
            }
        }
        common.into_iter().filter(|id| !has_child.contains(id)).collect()
    }

    /// Every batch included by `v`.
    pub fn closure(&self, v: &Version) -> HashSet<BatchId> {
        let mut seen = HashSet::new();
        let mut stack: Vec<BatchId> = v.heads().copied().collect();
        while let Some(id) = stack.pop() {
            if seen.insert(id)
                && let Some(h) = self.headers.get(&id)
            {
                stack.extend(h.parents.heads().copied());
            }
        }
        seen
    }

    /// Orders batch ids so parents come before children (timestamp order is a
    /// valid topological order thanks to the Lamport rule).
    pub fn topo_sorted(&self, ids: impl IntoIterator<Item = BatchId>) -> Vec<BatchId> {
        let mut v: Vec<BatchId> = ids.into_iter().collect();
        v.sort_by_key(|id| (self.headers.get(id).map(|h| h.start).unwrap_or(id.ts), id.actor));
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn actor(n: u128) -> ActorId {
        ActorId(Uuid::from_u128(n))
    }

    fn h(a: u128, start: u64, end: u64, parents: &[BatchId]) -> BatchHeader {
        BatchHeader { actor: actor(a), start, end, parents: parents.iter().copied().collect(), wall_ms: 0 }
    }

    #[test]
    fn heads_difference_and_union() {
        let mut d = Dag::new();
        let a = h(1, 1, 2, &[]);
        let a_id = a.id();
        d.insert(a).unwrap();
        let b = h(1, 3, 3, &[a_id]);
        let c = h(2, 3, 5, &[a_id]);
        let (b_id, c_id) = (b.id(), c.id());
        d.insert(b).unwrap();
        d.insert(c).unwrap();
        assert_eq!(d.heads().len(), 2);
        let diff = d.difference(d.heads(), &Version::single(b_id));
        assert_eq!(diff, HashSet::from([c_id]));
        assert!(d.version_contains_op(&Version::single(c_id), OpId::new(1, actor(1))));
        assert!(!d.version_contains_op(&Version::single(c_id), OpId::new(3, actor(1))));
        assert_eq!(d.batch_of(OpId::new(4, actor(2))), Some(c_id));
        assert_eq!(d.union(&Version::single(b_id), &Version::single(a_id)), Version::single(b_id));
        assert_eq!(d.common_frontier(&[Version::single(b_id), Version::single(c_id)]), Version::single(a_id));
        let m = h(3, 6, 6, &[b_id, c_id]);
        d.insert(m.clone()).unwrap();
        assert_eq!(d.heads(), &Version::single(m.id()));
    }

    #[test]
    fn admission_rules() {
        let mut d = Dag::new();
        let a = h(1, 1, 1, &[]);
        let a_id = a.id();
        d.insert(a.clone()).unwrap();
        assert!(!d.insert(a).unwrap());
        assert!(matches!(d.check(&h(2, 1, 1, &[a_id])), Err(DagError::LamportViolation { .. })));
        assert!(matches!(d.check(&h(2, 5, 5, &[OpId::new(9, actor(9))])), Err(DagError::MissingParents { .. })));
        assert!(matches!(d.check(&h(1, 1, 3, &[])), Err(DagError::Overlap { .. })));
        assert!(matches!(d.check(&h(1, 3, 2, &[])), Err(DagError::InvalidRange { .. })));
    }
}
