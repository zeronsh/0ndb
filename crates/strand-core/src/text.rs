//! Sequence CRDT for file text.
//!
//! Text is a list of fragments, each a slice of one operation's inserted
//! bytes. Fragments are never removed: a deletion records the deleting op on
//! the fragment (a tombstone), so every byte ever written keeps a stable
//! identity `(insertion op, offset)` that anchors and attribution can point at.
//!
//! An edit is expressed against the *visible* text of its parent version.
//! Applying it on a replica that already has concurrent edits replays the
//! positions through a [`View`] of that parent: fragments the author could
//! not see occupy zero width. At an insertion point, concurrent insertions
//! with a greater op id are kept to the left, which yields a single
//! convergent order regardless of delivery order.

use std::collections::HashMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::id::OpId;
use crate::op::Splice;

/// Which operations are considered applied.
pub trait View {
    fn observes(&self, op: OpId) -> bool;
}

/// The current state: every applied operation is observed.
pub struct Everything;

impl View for Everything {
    fn observes(&self, _: OpId) -> bool {
        true
    }
}

impl<F: Fn(OpId) -> bool> View for F {
    fn observes(&self, op: OpId) -> bool {
        self(op)
    }
}

/// Inserted bytes by operation id.
pub type Insertions = HashMap<OpId, Arc<[u8]>>;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fragment {
    /// Operation whose inserted text this fragment is a slice of.
    pub ins: OpId,
    /// Offset into that operation's inserted text.
    pub off: u64,
    pub len: u64,
    /// Operations that deleted this slice (sorted). Empty = visible.
    pub deleted_by: Vec<OpId>,
}

impl Fragment {
    pub fn is_visible(&self) -> bool {
        self.deleted_by.is_empty()
    }

    pub fn visible_in(&self, view: &dyn View) -> bool {
        view.observes(self.ins) && !self.deleted_by.iter().any(|d| view.observes(*d))
    }

    fn split(self, at: u64) -> (Fragment, Fragment) {
        debug_assert!(at > 0 && at < self.len);
        let left = Fragment { ins: self.ins, off: self.off, len: at, deleted_by: self.deleted_by.clone() };
        let right = Fragment { ins: self.ins, off: self.off + at, len: self.len - at, deleted_by: self.deleted_by };
        (left, right)
    }

    fn mark_deleted(&mut self, op: OpId) {
        if let Err(i) = self.deleted_by.binary_search(&op) {
            self.deleted_by.insert(i, op);
        }
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
    At { ins: OpId, off: u64, bias: Bias },
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

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Text {
    frags: Vec<Fragment>,
    len: u64,
}

impl Text {
    pub fn new() -> Self {
        Self::default()
    }

    /// Text consisting of `len` bytes of `ins` starting at `off`.
    pub fn from_insertion(ins: OpId, off: u64, len: u64) -> Self {
        if len == 0 {
            return Self::new();
        }
        Text { frags: vec![Fragment { ins, off, len, deleted_by: Vec::new() }], len }
    }

    /// Current visible length.
    pub fn len(&self) -> u64 {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn fragments(&self) -> &[Fragment] {
        &self.frags
    }

    pub fn len_in(&self, view: &dyn View) -> u64 {
        self.frags.iter().filter(|f| f.visible_in(view)).map(|f| f.len).sum()
    }

    pub fn read(&self, insertions: &Insertions) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.len as usize);
        for f in self.frags.iter().filter(|f| f.is_visible()) {
            out.extend_from_slice(slice(insertions, f));
        }
        out
    }

    pub fn read_in(&self, insertions: &Insertions, view: &dyn View) -> Vec<u8> {
        let mut out = Vec::new();
        for f in self.frags.iter().filter(|f| f.visible_in(view)) {
            out.extend_from_slice(slice(insertions, f));
        }
        out
    }

    /// Visible spans `(insertion op, offset into insertion, len)` in order.
    pub fn visible_spans(&self) -> impl Iterator<Item = (OpId, u64, u64)> + '_ {
        self.frags.iter().filter(|f| f.is_visible()).map(|f| (f.ins, f.off, f.len))
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

    /// Applies operation `op`'s splices, interpreted against `view` (the
    /// op's parent version as seen from this replica).
    pub fn apply(&mut self, op: OpId, view: &dyn View, splices: &[Splice], inserted: u64) -> Result<(), TextError> {
        self.validate(view, splices, inserted)?;
        let plen = |f: &Fragment| if f.visible_in(view) { f.len } else { 0 };
        let old = std::mem::take(&mut self.frags);
        let mut out = Vec::with_capacity(old.len() + splices.len() * 3);
        let mut rest = old.into_iter();
        let mut cur = rest.next();
        let mut pos = 0u64;
        let mut used = 0u64;
        for s in splices {
            // Advance to the splice start. Zero-width fragments exactly at the
            // start stay to the right: a new insertion goes immediately after
            // the last byte the author could see.
            while let Some(f) = cur.take() {
                let w = plen(&f);
                if w == 0 {
                    if pos < s.at {
                        out.push(f);
                        cur = rest.next();
                        continue;
                    }
                    cur = Some(f);
                    break;
                }
                if pos + w <= s.at {
                    pos += w;
                    out.push(f);
                    cur = rest.next();
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
            // Concurrent insertions at this point with a greater id go first.
            while let Some(f) = cur.take() {
                if plen(&f) == 0 && f.ins > op {
                    out.push(f);
                    cur = rest.next();
                } else {
                    cur = Some(f);
                    break;
                }
            }
            if s.ins > 0 {
                out.push(Fragment { ins: op, off: used, len: s.ins, deleted_by: Vec::new() });
                used += s.ins;
            }
            // Tombstone every byte the author saw in the range; text inserted
            // concurrently inside it survives.
            let end = s.at + s.del;
            while pos < end {
                let Some(mut f) = cur.take() else { break };
                let w = plen(&f);
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
                cur = rest.next();
            }
        }
        out.extend(cur);
        out.extend(rest);
        self.frags = out;
        self.compact();
        self.len = self.frags.iter().filter(|f| f.is_visible()).map(|f| f.len).sum();
        Ok(())
    }

    fn compact(&mut self) {
        let mut out: Vec<Fragment> = Vec::with_capacity(self.frags.len());
        for f in self.frags.drain(..) {
            if f.len == 0 {
                continue;
            }
            if let Some(last) = out.last_mut()
                && last.ins == f.ins
                && last.off + last.len == f.off
                && last.deleted_by == f.deleted_by
            {
                last.len += f.len;
                continue;
            }
            out.push(f);
        }
        self.frags = out;
    }

    pub fn anchor_at(&self, offset: u64, bias: Bias) -> Anchor {
        match bias {
            Bias::Left if offset == 0 => return Anchor::Start,
            Bias::Right if offset >= self.len => return Anchor::End,
            _ => {}
        }
        let mut pos = 0u64;
        for f in self.frags.iter().filter(|f| f.is_visible()) {
            let hit = match bias {
                Bias::Left => pos < offset && offset <= pos + f.len,
                Bias::Right => pos <= offset && offset < pos + f.len,
            };
            if hit {
                return Anchor::At { ins: f.ins, off: f.off + (offset - pos), bias };
            }
            pos += f.len;
        }
        Anchor::End
    }

    /// Current offset of an anchor. Anchors into deleted text resolve to
    /// where that text used to be.
    pub fn resolve(&self, anchor: &Anchor) -> u64 {
        let (ins, off, bias) = match *anchor {
            Anchor::Start => return 0,
            Anchor::End => return self.len,
            Anchor::At { ins, off, bias } => (ins, off, bias),
        };
        let mut pos = 0u64;
        for f in &self.frags {
            let hit = f.ins == ins
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
        self.len
    }
}

fn slice<'a>(insertions: &'a Insertions, f: &Fragment) -> &'a [u8] {
    let bytes = insertions.get(&f.ins).map(|b| &b[..]).unwrap_or(&[]);
    let start = (f.off as usize).min(bytes.len());
    let end = ((f.off + f.len) as usize).min(bytes.len());
    &bytes[start..end]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::id::ActorId;
    use uuid::Uuid;

    fn op(ts: u64, a: u128) -> OpId {
        OpId::new(ts, ActorId(Uuid::from_u128(a)))
    }

    struct Doc {
        text: Text,
        ins: Insertions,
    }

    impl Doc {
        fn new(base: OpId, s: &str) -> Self {
            let mut ins = Insertions::new();
            ins.insert(base, Arc::from(s.as_bytes()));
            Doc { text: Text::from_insertion(base, 0, s.len() as u64), ins }
        }
        fn edit(&mut self, id: OpId, view: &dyn View, at: u64, del: u64, s: &str) {
            self.ins.insert(id, Arc::from(s.as_bytes()));
            self.text.apply(id, view, &[Splice { at, del, ins: s.len() as u64 }], s.len() as u64).unwrap();
        }
        fn get(&self) -> String {
            String::from_utf8(self.text.read(&self.ins)).unwrap()
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
}
