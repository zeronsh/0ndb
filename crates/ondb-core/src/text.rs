//! Sequence CRDT for file text, stored in a persistent summarized B-tree.
//!
//! Text is a sequence of fragments, each a slice of one insertion's bytes.
//! Fragments are never removed: a deletion records the deleting op on the
//! fragment (a tombstone), so every byte keeps a stable identity
//! `(insertion, offset)` that anchors and attribution can point at.
//!
//! An edit is expressed against the *visible* text of its parent version.
//! Applying it on a replica that already holds concurrent edits replays the
//! positions through a [`View`] of that parent: fragments the author could
//! not see occupy zero width. At an insertion point, concurrent insertions
//! with a greater op id are kept to the left, which yields one convergent
//! order regardless of delivery order.
//!
//! Every subtree summarizes its visible bytes, total bytes and the newest
//! timestamp of any insertion or deletion inside it. A view reports the
//! oldest timestamp it does *not* observe; any subtree whose newest op is
//! older than that looks the same in the view as it does now, so seeks in a
//! past version only descend into regions concurrent edits actually touched.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::contents::{Contents, InsertionKey};
use crate::id::{Lamport, OpId};
use crate::op::Splice;
use crate::sumtree::{self, Item, Node, NodeBox, NodeStore, StoreResult, SumTree};

/// Which operations are considered applied.
pub trait View {
    fn observes(&self, op: OpId) -> bool;

    /// Lower bound on the timestamp of every unobserved operation;
    /// `Lamport::MAX` when everything is observed. Ops older than this are
    /// observed, which lets seeks skip whole subtrees.
    fn min_unobserved(&self) -> Lamport {
        0
    }
}

/// The current state: every applied operation is observed.
pub struct Everything;

impl View for Everything {
    fn observes(&self, _: OpId) -> bool {
        true
    }

    fn min_unobserved(&self) -> Lamport {
        Lamport::MAX
    }
}

impl<F: Fn(OpId) -> bool> View for F {
    fn observes(&self, op: OpId) -> bool {
        self(op)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fragment {
    /// Operation whose inserted text this fragment is a slice of.
    pub ins: OpId,
    /// Which insertion of that op (the entry index of an import).
    pub part: u32,
    /// Offset into that insertion.
    pub off: u64,
    pub len: u64,
    /// Operations that deleted this slice (sorted). Empty = visible.
    pub deleted_by: Vec<OpId>,
}

impl Fragment {
    pub fn key(&self) -> InsertionKey {
        (self.ins, self.part)
    }

    pub fn is_visible(&self) -> bool {
        self.deleted_by.is_empty()
    }

    pub fn visible_in(&self, view: &dyn View) -> bool {
        view.observes(self.ins) && !self.deleted_by.iter().any(|d| view.observes(*d))
    }

    fn max_ts(&self) -> Lamport {
        self.deleted_by.iter().map(|d| d.ts).max().unwrap_or(0).max(self.ins.ts)
    }

    fn split(self, at: u64) -> (Fragment, Fragment) {
        debug_assert!(at > 0 && at < self.len);
        let left = Fragment { ins: self.ins, part: self.part, off: self.off, len: at, deleted_by: self.deleted_by.clone() };
        let right = Fragment { off: self.off + at, len: self.len - at, ..self };
        (left, right)
    }

    fn mark_deleted(&mut self, op: OpId) {
        if let Err(i) = self.deleted_by.binary_search(&op) {
            self.deleted_by.insert(i, op);
        }
    }

    fn mergeable(&self, next: &Fragment) -> bool {
        self.ins == next.ins && self.part == next.part && self.off + self.len == next.off && self.deleted_by == next.deleted_by
    }
}

#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub struct FragSummary {
    pub visible: u64,
    pub total: u64,
    pub max_ts: Lamport,
}

impl sumtree::Summary for FragSummary {
    fn add(&mut self, o: &Self) {
        self.visible += o.visible;
        self.total += o.total;
        self.max_ts = self.max_ts.max(o.max_ts);
    }
}

impl Item for Fragment {
    type Summary = FragSummary;
    fn summary(&self) -> FragSummary {
        FragSummary { visible: if self.is_visible() { self.len } else { 0 }, total: self.len, max_ts: self.max_ts() }
    }
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Bias {
    Left,
    Right,
}

/// A position that survives edits: it names a byte by its insertion identity
/// rather than by offset. `Left` sticks to the byte before the position,
/// `Right` to the byte after it.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Anchor {
    Start,
    End,
    At { ins: OpId, part: u32, off: u64, bias: Bias },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TextError {
    #[error("splices must be sorted and non-overlapping")]
    Unordered,
    #[error("splice ends at {end} but the parent text is {len} bytes")]
    OutOfBounds { end: u64, len: u64 },
    #[error("splices insert {used} bytes but the operation carries {have}")]
    LengthMismatch { used: u64, have: u64 },
}

/// Visible length of a fragment in a view, using the timestamp bound to
/// avoid per-op membership checks for old fragments.
fn width(f: &Fragment, view: &dyn View, min: Lamport) -> u64 {
    let visible = if f.max_ts() < min { f.is_visible() } else { f.visible_in(view) };
    if visible { f.len } else { 0 }
}

fn node_width(nb: &NodeBox<Fragment>, view: &dyn View, min: Lamport) -> u64 {
    if nb.summary.max_ts < min {
        return nb.summary.visible;
    }
    match &nb.node {
        Node::Leaf { items } => items.iter().map(|f| width(f, view, min)).sum(),
        Node::Branch { children, .. } => children.iter().map(|c| node_width(c, view, min)).sum(),
    }
}

/// `view` minus the op being applied: its own insertions and deletions are
/// never part of its parent version.
struct Without<'a> {
    view: &'a dyn View,
    op: OpId,
}

impl View for Without<'_> {
    fn observes(&self, op: OpId) -> bool {
        op != self.op && self.view.observes(op)
    }

    fn min_unobserved(&self) -> Lamport {
        self.view.min_unobserved().min(self.op.ts)
    }
}

#[derive(Clone, Default)]
pub struct Text {
    tree: SumTree<Fragment>,
}

impl PartialEq for Text {
    fn eq(&self, other: &Self) -> bool {
        self.tree.len() == other.tree.len() && self.tree.iter().eq(other.tree.iter())
    }
}

impl Eq for Text {}

impl std::fmt::Debug for Text {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list().entries(self.tree.iter()).finish()
    }
}

impl Serialize for Text {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeSeq;
        let mut seq = s.serialize_seq(Some(self.tree.len()))?;
        for f in self.tree.iter() {
            seq.serialize_element(f)?;
        }
        seq.end()
    }
}

impl<'de> Deserialize<'de> for Text {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Text { tree: SumTree::from_items(Vec::<Fragment>::deserialize(d)?) })
    }
}

impl Text {
    pub fn new() -> Self {
        Self::default()
    }

    /// Text consisting of `len` bytes of insertion `(ins, part)` from `off`.
    pub fn from_insertion(ins: OpId, part: u32, off: u64, len: u64) -> Self {
        if len == 0 {
            return Self::new();
        }
        Text { tree: SumTree::from_items(vec![Fragment { ins, part, off, len, deleted_by: Vec::new() }]) }
    }

    /// Current visible length.
    pub fn len(&self) -> u64 {
        self.tree.summary().visible
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn fragments_len(&self) -> usize {
        self.tree.len()
    }

    pub fn fragments(&self) -> impl Iterator<Item = &Fragment> {
        self.tree.iter()
    }

    pub fn len_in(&self, view: &dyn View) -> u64 {
        node_width(self.tree.root(), view, view.min_unobserved())
    }

    /// Index of the fragment holding visible byte `k` of the view, and the
    /// view offset where that fragment starts. Past the end: `(len, total)`.
    fn locate(&self, view: &dyn View, min: Lamport, k: u64) -> (usize, u64) {
        let mut node = self.tree.root();
        let (mut idx, mut pos) = (0usize, 0u64);
        loop {
            match &node.node {
                Node::Branch { children, counts, .. } => {
                    let mut next = None;
                    for (c, n) in children.iter().zip(counts) {
                        let w = node_width(c, view, min);
                        if pos + w > k {
                            next = Some(c);
                            break;
                        }
                        pos += w;
                        idx += n;
                    }
                    match next {
                        Some(c) => node = c,
                        None => return (idx, pos),
                    }
                }
                Node::Leaf { items } => {
                    for f in items {
                        let w = width(f, view, min);
                        if pos + w > k {
                            return (idx, pos);
                        }
                        pos += w;
                        idx += 1;
                    }
                    return (idx, pos);
                }
            }
        }
    }

    fn read_with(&self, contents: &Contents, mut keep: impl FnMut(&Fragment) -> bool) -> Option<Vec<u8>> {
        let mut out = Vec::new();
        let mut last: Option<(InsertionKey, std::sync::Arc<[u8]>)> = None;
        for f in self.tree.iter().filter(|f| keep(f)) {
            let key = f.key();
            if last.as_ref().is_none_or(|(k, _)| *k != key) {
                last = Some((key, contents.bytes(&key)?));
            }
            let bytes = &last.as_ref().unwrap().1;
            out.extend_from_slice(bytes.get(f.off as usize..(f.off + f.len) as usize)?);
        }
        Some(out)
    }

    /// Visible bytes; `None` if some insertion's blob isn't available.
    pub fn read(&self, contents: &Contents) -> Option<Vec<u8>> {
        self.read_with(contents, |f| f.is_visible())
    }

    pub fn read_in(&self, contents: &Contents, view: &dyn View) -> Option<Vec<u8>> {
        let min = view.min_unobserved();
        self.read_with(contents, |f| width(f, view, min) > 0)
    }

    /// Visible spans `(insertion op, part, offset into insertion, len)` in order.
    pub fn visible_spans(&self) -> impl Iterator<Item = (OpId, u32, u64, u64)> + '_ {
        self.tree.iter().filter(|f| f.is_visible()).map(|f| (f.ins, f.part, f.off, f.len))
    }

    pub fn validate(&self, view: &dyn View, splices: &[Splice], inserted: u64) -> Result<(), TextError> {
        let mut floor = 0u64;
        let mut used = 0u64;
        for s in splices {
            if s.at < floor {
                return Err(TextError::Unordered);
            }
            floor = s.at + s.del;
            used += s.ins;
        }
        if used != inserted {
            return Err(TextError::LengthMismatch { used, have: inserted });
        }
        let len = self.len_in(view);
        if floor > len {
            return Err(TextError::OutOfBounds { end: floor, len });
        }
        Ok(())
    }

    /// Applies operation `op`'s splices (insertion part 0), interpreted
    /// against `view` (the op's parent version as seen from this replica).
    ///
    /// Splices are independent in the parent's coordinates (the op's own
    /// insertions are invisible there, and its own deletions don't apply
    /// there), so each is applied with its own O(log n) seek and only the
    /// fragments it touches are rewritten.
    pub fn apply(&mut self, op: OpId, view: &dyn View, splices: &[Splice], inserted: u64) -> Result<(), TextError> {
        let view = &Without { view, op };
        self.validate(view, splices, inserted)?;
        let min = view.min_unobserved();
        let mut used = 0u64;
        for s in splices {
            let (start, mut pos) = if s.at == 0 { (0, 0) } else { self.locate(view, min, s.at - 1) };
            let mut out: Vec<Fragment> = Vec::new();
            let mut consumed = 0usize;
            {
                let mut it = self.tree.iter_from(start);
                let mut pull = || {
                    let f = it.next().cloned();
                    consumed += f.is_some() as usize;
                    f
                };
                let mut cur = pull();
                // Advance to the splice start. Zero-width fragments exactly at
                // the start stay to the right: a new insertion goes right after
                // the last byte the author could see.
                while let Some(f) = cur.take() {
                    let w = width(&f, view, min);
                    if w == 0 {
                        if pos < s.at {
                            out.push(f);
                            cur = pull();
                            continue;
                        }
                        cur = Some(f);
                        break;
                    }
                    if pos + w <= s.at {
                        pos += w;
                        out.push(f);
                        cur = pull();
                        continue;
                    }
                    if pos < s.at {
                        let (l, r) = f.split(s.at - pos);
                        out.push(l);
                        cur = Some(r);
                        pos = s.at;
                    } else {
                        cur = Some(f);
                    }
                    break;
                }
                // Concurrent insertions here with a greater id go first, as do
                // this op's own earlier insertions at the same point.
                while let Some(f) = cur.take() {
                    if width(&f, view, min) == 0 && f.ins >= op {
                        out.push(f);
                        cur = pull();
                    } else {
                        cur = Some(f);
                        break;
                    }
                }
                if s.ins > 0 {
                    out.push(Fragment { ins: op, part: 0, off: used, len: s.ins, deleted_by: Vec::new() });
                    used += s.ins;
                }
                // Tombstone every byte the author saw in the range; text
                // inserted concurrently inside it survives.
                let end = s.at + s.del;
                while pos < end {
                    let Some(mut f) = cur.take() else { break };
                    let w = width(&f, view, min);
                    if w == 0 {
                        out.push(f);
                    } else if pos + w <= end {
                        pos += w;
                        f.mark_deleted(op);
                        out.push(f);
                    } else {
                        let (mut l, r) = f.split(end - pos);
                        l.mark_deleted(op);
                        out.push(l);
                        cur = Some(r);
                        pos = end;
                        continue;
                    }
                    cur = pull();
                }
                out.extend(cur);
            }
            let mut merged: Vec<Fragment> = Vec::with_capacity(out.len());
            for f in out {
                match merged.last_mut() {
                    Some(last) if last.mergeable(&f) => last.len += f.len,
                    _ => merged.push(f),
                }
            }
            self.tree.splice(start..start + consumed, merged);
        }
        Ok(())
    }

    pub fn anchor_at(&self, offset: u64, bias: Bias) -> Anchor {
        let len = self.len();
        match bias {
            Bias::Left if offset == 0 => return Anchor::Start,
            Bias::Right if offset >= len => return Anchor::End,
            _ => {}
        }
        let k = match bias {
            Bias::Left => offset - 1,
            Bias::Right => offset,
        };
        let (idx, pos) = self.locate(&Everything, Lamport::MAX, k);
        match self.tree.iter_from(idx).next() {
            Some(f) => Anchor::At { ins: f.ins, part: f.part, off: f.off + (offset - pos), bias },
            None => Anchor::End,
        }
    }

    /// Current offset of an anchor. Anchors into deleted text resolve to
    /// where that text used to be.
    pub fn resolve(&self, anchor: &Anchor) -> u64 {
        let (ins, part, off, bias) = match *anchor {
            Anchor::Start => return 0,
            Anchor::End => return self.len(),
            Anchor::At { ins, part, off, bias } => (ins, part, off, bias),
        };
        let mut pos = 0u64;
        for f in self.tree.iter() {
            let hit = f.ins == ins
                && f.part == part
                && match bias {
                    Bias::Left => f.off < off && off <= f.off + f.len,
                    Bias::Right => f.off <= off && off < f.off + f.len,
                };
            if hit {
                return pos + if f.is_visible() { off - f.off } else { 0 };
            }
            if f.is_visible() {
                pos += f.len;
            }
        }
        self.len()
    }

    pub fn persist(&self, store: &mut dyn NodeStore) -> StoreResult<u64> {
        self.tree.persist(store)
    }

    pub fn load(id: u64, store: &mut dyn NodeStore) -> StoreResult<Self> {
        Ok(Text { tree: SumTree::load(id, store)? })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::contents::Insertion;
    use crate::id::ActorId;
    use uuid::Uuid;

    fn op(ts: u64, a: u128) -> OpId {
        OpId::new(ts, ActorId(Uuid::from_u128(a)))
    }

    struct Doc {
        text: Text,
        ins: Contents,
    }

    impl Doc {
        fn new(base: OpId, s: &str) -> Self {
            let mut ins = Contents::default();
            ins.insert((base, 0), Insertion::Bytes(Arc::from(s.as_bytes())));
            Doc { text: Text::from_insertion(base, 0, 0, s.len() as u64), ins }
        }
        fn edit(&mut self, id: OpId, view: &dyn View, at: u64, del: u64, s: &str) {
            self.ins.insert((id, 0), Insertion::Bytes(Arc::from(s.as_bytes())));
            self.text.apply(id, view, &[Splice { at, del, ins: s.len() as u64 }], s.len() as u64).unwrap();
        }
        fn get(&self) -> String {
            String::from_utf8(self.text.read(&self.ins).unwrap()).unwrap()
        }
    }

    #[test]
    fn concurrent_inserts_at_same_point_converge() {
        let base = op(1, 1);
        let a = op(2, 1);
        let b = op(2, 2);
        let only_base = |o: OpId| o == base;
        let mut x = Doc::new(base, "hello world");
        x.edit(a, &only_base, 5, 0, " A");
        x.edit(b, &only_base, 5, 0, " B");
        let mut y = Doc::new(base, "hello world");
        y.edit(b, &only_base, 5, 0, " B");
        y.edit(a, &only_base, 5, 0, " A");
        assert_eq!(x.get(), y.get());
        assert_eq!(x.get(), "hello B A world");
    }

    #[test]
    fn concurrent_delete_keeps_concurrent_insert() {
        let base = op(1, 1);
        let only_base = |o: OpId| o == base;
        let (a, b) = (op(2, 1), op(2, 2));
        let mut x = Doc::new(base, "abcdef");
        x.edit(a, &only_base, 1, 4, "");
        x.edit(b, &only_base, 3, 0, "XY");
        let mut y = Doc::new(base, "abcdef");
        y.edit(b, &only_base, 3, 0, "XY");
        y.edit(a, &only_base, 1, 4, "");
        assert_eq!(x.get(), "aXYf");
        assert_eq!(x.get(), y.get());
    }

    #[test]
    fn anchors_survive_edits_and_deletion() {
        let base = op(1, 1);
        let mut d = Doc::new(base, "fn main() {}");
        let at_paren = d.text.anchor_at(7, Bias::Right);
        d.edit(op(2, 1), &Everything, 0, 0, "// hi\n");
        assert_eq!(d.text.resolve(&at_paren), 13);
        d.edit(op(3, 1), &Everything, 6, 7, "");
        assert_eq!(d.get(), "// hi\n() {}");
        assert_eq!(d.text.resolve(&at_paren), 6);
    }

    #[test]
    fn rejects_out_of_bounds() {
        let base = op(1, 1);
        let d = Doc::new(base, "abc");
        let mut t = d.text.clone();
        assert!(matches!(
            t.apply(op(2, 1), &Everything, &[Splice { at: 2, del: 5, ins: 0 }], 0),
            Err(TextError::OutOfBounds { .. })
        ));
        assert_eq!(t, d.text);
    }

    #[test]
    fn multi_splice_ops_match_sequential_reference() {
        let base = op(1, 1);
        let mut d = Doc::new(base, "0123456789");
        let id = op(2, 1);
        let text = b"ABCD".to_vec();
        d.ins.insert((id, 0), Insertion::Bytes(Arc::from(text.as_slice())));
        let splices = [Splice { at: 2, del: 0, ins: 1 }, Splice { at: 2, del: 2, ins: 2 }, Splice { at: 9, del: 1, ins: 1 }];
        d.text.apply(id, &Everything, &splices, 4).unwrap();
        assert_eq!(
            d.get(),
            crate::diff::apply_splices(b"0123456789", &text, &splices).iter().map(|b| *b as char).collect::<String>()
        );
    }
}
