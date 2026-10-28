//! Persistent copy-on-write B-tree with per-subtree summaries.
//!
//! * Nodes are immutable once shared: mutation goes through
//!   `Arc::make_mut`, which edits in place when this tree is the only owner
//!   and copies just the root-to-leaf path otherwise. Cloning a tree (a
//!   snapshot) is O(1); readers of a snapshot never need latches.
//! * Branches keep child summaries and item counts in arrays separate from
//!   the child pointers, so descents scan dense summary arrays.
//! * Every node remembers the storage id it was last persisted under.
//!   Persisting writes only nodes created or changed since, so durable
//!   writes cost O(changed path), not O(tree).

use std::ops::Range;
use std::sync::{Arc, OnceLock};

use serde::Serialize;
use serde::de::DeserializeOwned;

pub const LEAF_MAX: usize = 48;
pub const BRANCH_MAX: usize = 32;

pub trait Summary: Clone + Default {
    fn add(&mut self, other: &Self);
}

pub trait Item: Clone {
    type Summary: Summary;
    fn summary(&self) -> Self::Summary;
}

#[derive(Clone)]
pub enum Node<T: Item> {
    Leaf { items: Vec<T> },
    Branch { children: Vec<Arc<NodeBox<T>>>, sums: Vec<T::Summary>, counts: Vec<usize> },
}

pub struct NodeBox<T: Item> {
    pub node: Node<T>,
    pub summary: T::Summary,
    pub count: usize,
    pub height: u8,
    id: OnceLock<u64>,
}

impl<T: Item> Clone for NodeBox<T> {
    fn clone(&self) -> Self {
        // A copy is a new node: it has never been persisted.
        NodeBox {
            node: self.node.clone(),
            summary: self.summary.clone(),
            count: self.count,
            height: self.height,
            id: OnceLock::new(),
        }
    }
}

impl<T: Item> NodeBox<T> {
    fn leaf(items: Vec<T>) -> Self {
        let mut summary = T::Summary::default();
        for i in &items {
            summary.add(&i.summary());
        }
        NodeBox { count: items.len(), node: Node::Leaf { items }, summary, height: 0, id: OnceLock::new() }
    }

    fn branch(children: Vec<Arc<NodeBox<T>>>) -> Self {
        let height = children.first().map(|c| c.height + 1).unwrap_or(1);
        let sums: Vec<T::Summary> = children.iter().map(|c| c.summary.clone()).collect();
        let counts: Vec<usize> = children.iter().map(|c| c.count).collect();
        let mut summary = T::Summary::default();
        for s in &sums {
            summary.add(s);
        }
        NodeBox {
            count: counts.iter().sum(),
            node: Node::Branch { children, sums, counts },
            summary,
            height,
            id: OnceLock::new(),
        }
    }

    pub fn persisted_id(&self) -> Option<u64> {
        self.id.get().copied()
    }
}

/// Chunks `items` into nodes of at most `max`, as evenly as possible.
fn chunk<X>(mut items: Vec<X>, max: usize) -> Vec<Vec<X>> {
    if items.len() <= max {
        return vec![items];
    }
    let parts = items.len().div_ceil(max);
    let size = items.len().div_ceil(parts);
    let mut out = Vec::with_capacity(parts);
    while items.len() > size {
        let rest = items.split_off(size);
        out.push(std::mem::replace(&mut items, rest));
    }
    out.push(items);
    out
}

fn splice_rec<T: Item>(mut nb: Arc<NodeBox<T>>, start: usize, end: usize, new: Vec<T>) -> Vec<Arc<NodeBox<T>>> {
    let n = Arc::make_mut(&mut nb);
    n.id = OnceLock::new();
    match &mut n.node {
        Node::Leaf { items } => {
            items.splice(start..end, new);
            if items.is_empty() {
                return Vec::new();
            }
            if items.len() <= LEAF_MAX {
                let items = std::mem::take(items);
                return vec![Arc::new(NodeBox::leaf(items))];
            }
            chunk(std::mem::take(items), LEAF_MAX).into_iter().map(|c| Arc::new(NodeBox::leaf(c))).collect()
        }
        Node::Branch { children, counts, .. } => {
            // Locate the children covering [start, end). An empty range at a
            // child boundary inserts into the child on the left (or the first).
            let mut acc = 0;
            let mut first = children.len() - 1;
            for (i, c) in counts.iter().enumerate() {
                if start < acc + c || (start == acc + c && start == end && i + 1 == counts.len()) {
                    first = i;
                    break;
                }
                acc += c;
            }
            let first_start = acc;
            let mut last = first;
            let mut last_start = first_start;
            if end > start {
                let mut a = first_start;
                for (i, c) in counts.iter().enumerate().skip(first) {
                    last = i;
                    last_start = a;
                    if end <= a + c {
                        break;
                    }
                    a += c;
                }
            }
            let old: Vec<Arc<NodeBox<T>>> = children.drain(first..=last).collect();
            let mut replacement = Vec::new();
            let mut new = Some(new);
            let n_old = old.len();
            for (k, child) in old.into_iter().enumerate() {
                let base = if k == 0 {
                    first_start
                } else if k + 1 == n_old {
                    last_start
                } else {
                    0
                };
                let child_count = child.count;
                let s = if k == 0 { start - base } else { 0 };
                let e = if k + 1 == n_old { end - base } else { child_count };
                let e = e.min(child_count);
                if k > 0 && k + 1 < n_old {
                    continue; // fully covered middle child
                }
                replacement.extend(splice_rec(child, s, e, new.take().unwrap_or_default()));
            }
            children.splice(first..first, replacement);
            let kids = std::mem::take(children);
            if kids.is_empty() {
                return Vec::new();
            }
            chunk(kids, BRANCH_MAX).into_iter().map(|c| Arc::new(NodeBox::branch(c))).collect()
        }
    }
}

/// Errors from a node store, opaque to the tree.
pub type StoreResult<T> = Result<T, String>;

/// Durable node storage: `put` writes a node that references `children`
/// (which the store must keep alive), `get` reads one back.
pub trait NodeStore {
    fn put(&mut self, data: &[u8], children: &[u64]) -> StoreResult<u64>;
    fn get(&mut self, id: u64) -> StoreResult<Vec<u8>>;
}

#[derive(serde::Serialize, serde::Deserialize)]
enum Stored<T> {
    Leaf(Vec<T>),
    Branch(Vec<u64>),
}

pub struct SumTree<T: Item> {
    root: Arc<NodeBox<T>>,
}

impl<T: Item> Clone for SumTree<T> {
    fn clone(&self) -> Self {
        SumTree { root: self.root.clone() }
    }
}

impl<T: Item> Default for SumTree<T> {
    fn default() -> Self {
        SumTree { root: Arc::new(NodeBox::leaf(Vec::new())) }
    }
}

impl<T: Item> SumTree<T> {
    pub fn new() -> Self {
        Self::default()
    }

    /// Bulk-builds a balanced tree.
    pub fn from_items(items: Vec<T>) -> Self {
        let mut level: Vec<Arc<NodeBox<T>>> = chunk(items, LEAF_MAX).into_iter().map(|c| Arc::new(NodeBox::leaf(c))).collect();
        while level.len() > 1 {
            level = chunk(level, BRANCH_MAX).into_iter().map(|c| Arc::new(NodeBox::branch(c))).collect();
        }
        SumTree { root: level.pop().expect("at least one leaf") }
    }

    pub fn root(&self) -> &NodeBox<T> {
        &self.root
    }

    pub fn summary(&self) -> &T::Summary {
        &self.root.summary
    }

    pub fn len(&self) -> usize {
        self.root.count
    }

    pub fn is_empty(&self) -> bool {
        self.root.count == 0
    }

    /// Replaces items `range` with `items`, copying only the touched path.
    pub fn splice(&mut self, range: Range<usize>, items: Vec<T>) {
        assert!(range.start <= range.end && range.end <= self.len(), "splice out of bounds");
        if range.is_empty() && items.is_empty() {
            return;
        }
        let root = std::mem::replace(&mut self.root, Arc::new(NodeBox::leaf(Vec::new())));
        let mut level = splice_rec(root, range.start, range.end, items);
        while level.len() > 1 {
            level = chunk(level, BRANCH_MAX).into_iter().map(|c| Arc::new(NodeBox::branch(c))).collect();
        }
        let mut root = level.pop().unwrap_or_else(|| Arc::new(NodeBox::leaf(Vec::new())));
        // Collapse single-child branches left by shrinking.
        while let Node::Branch { children, .. } = &root.node {
            if children.len() != 1 {
                break;
            }
            root = children[0].clone();
        }
        self.root = root;
    }

    pub fn iter(&self) -> Iter<'_, T> {
        self.iter_from(0)
    }

    /// Items starting at global index `index`.
    pub fn iter_from(&self, index: usize) -> Iter<'_, T> {
        let mut stack = Vec::new();
        let mut node: &NodeBox<T> = &self.root;
        let mut rem = index;
        loop {
            match &node.node {
                Node::Leaf { items } => {
                    stack.push(Frame::Leaf(items, rem.min(items.len())));
                    break;
                }
                Node::Branch { children, counts, .. } => {
                    let mut i = 0;
                    while i + 1 < counts.len() && rem >= counts[i] {
                        rem -= counts[i];
                        i += 1;
                    }
                    stack.push(Frame::Branch(children, i + 1));
                    node = &children[i];
                }
            }
        }
        Iter { stack }
    }
}

impl<T: Item + Serialize + DeserializeOwned> SumTree<T> {
    /// Writes every node not yet persisted (post-order) and returns the
    /// root id. Unchanged subtrees are referenced, not rewritten.
    pub fn persist(&self, store: &mut dyn NodeStore) -> StoreResult<u64> {
        fn rec<T: Item + Serialize>(nb: &NodeBox<T>, store: &mut dyn NodeStore) -> StoreResult<u64> {
            if let Some(id) = nb.id.get() {
                return Ok(*id);
            }
            let (data, children) = match &nb.node {
                Node::Leaf { items } => (postcard::to_stdvec(&Stored::<&T>::Leaf(items.iter().collect())), Vec::new()),
                Node::Branch { children, .. } => {
                    let ids = children.iter().map(|c| rec(c, store)).collect::<StoreResult<Vec<u64>>>()?;
                    (postcard::to_stdvec(&Stored::<&T>::Branch(ids.clone())), ids)
                }
            };
            let id = store.put(&data.map_err(|e| e.to_string())?, &children)?;
            let _ = nb.id.set(id);
            Ok(id)
        }
        rec(&self.root, store)
    }

    pub fn load(id: u64, store: &mut dyn NodeStore) -> StoreResult<Self> {
        fn rec<T: Item + DeserializeOwned>(id: u64, store: &mut dyn NodeStore) -> StoreResult<Arc<NodeBox<T>>> {
            let data = store.get(id)?;
            let nb = match postcard::from_bytes::<Stored<T>>(&data).map_err(|e| e.to_string())? {
                Stored::Leaf(items) => NodeBox::leaf(items),
                Stored::Branch(ids) => NodeBox::branch(ids.into_iter().map(|c| rec(c, store)).collect::<StoreResult<_>>()?),
            };
            let _ = nb.id.set(id);
            Ok(Arc::new(nb))
        }
        Ok(SumTree { root: rec(id, store)? })
    }
}

enum Frame<'a, T: Item> {
    Leaf(&'a [T], usize),
    Branch(&'a [Arc<NodeBox<T>>], usize),
}

pub struct Iter<'a, T: Item> {
    stack: Vec<Frame<'a, T>>,
}

impl<'a, T: Item> Iterator for Iter<'a, T> {
    type Item = &'a T;

    fn next(&mut self) -> Option<&'a T> {
        loop {
            match self.stack.last_mut()? {
                Frame::Leaf(items, i) => {
                    if let Some(item) = items.get(*i) {
                        *i += 1;
                        return Some(item);
                    }
                    self.stack.pop();
                }
                Frame::Branch(children, i) => {
                    let Some(child) = children.get(*i) else {
                        self.stack.pop();
                        continue;
                    };
                    *i += 1;
                    let mut node: &'a NodeBox<T> = child;
                    loop {
                        match &node.node {
                            Node::Leaf { items } => {
                                self.stack.push(Frame::Leaf(items, 0));
                                break;
                            }
                            Node::Branch { children, .. } => {
                                self.stack.push(Frame::Branch(children, 1));
                                node = &children[0];
                            }
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
    struct N(u64);
    #[derive(Clone, Default)]
    struct Sum(u64);
    impl Summary for Sum {
        fn add(&mut self, o: &Self) {
            self.0 += o.0;
        }
    }
    impl Item for N {
        type Summary = Sum;
        fn summary(&self) -> Sum {
            Sum(self.0)
        }
    }

    #[derive(Default)]
    struct Mem {
        nodes: HashMap<u64, Vec<u8>>,
    }
    impl NodeStore for Mem {
        fn put(&mut self, data: &[u8], _: &[u64]) -> StoreResult<u64> {
            let id = self.nodes.len() as u64 + 1;
            self.nodes.insert(id, data.to_vec());
            Ok(id)
        }
        fn get(&mut self, id: u64) -> StoreResult<Vec<u8>> {
            self.nodes.get(&id).cloned().ok_or("missing".into())
        }
    }

    #[test]
    fn splice_matches_vec_model_and_snapshots_are_isolated() {
        let mut model: Vec<u64> = (0..5000).collect();
        let mut tree = SumTree::from_items(model.iter().map(|x| N(*x)).collect());
        let mut seed = 7u64;
        let mut rnd = |n: usize| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed % (n as u64).max(1)) as usize
        };
        let snapshot = tree.clone();
        for round in 0..3000 {
            let start = rnd(model.len() + 1);
            let end = (start + rnd(if round % 50 == 0 { 400 } else { 4 })).min(model.len());
            let new: Vec<u64> = (0..rnd(5)).map(|k| 1_000_000 + round * 10 + k as u64).collect();
            model.splice(start..end, new.clone());
            tree.splice(start..end, new.into_iter().map(N).collect());
            assert_eq!(tree.len(), model.len());
        }
        assert_eq!(tree.iter().map(|n| n.0).collect::<Vec<_>>(), model);
        assert_eq!(tree.summary().0, model.iter().sum::<u64>());
        assert_eq!(tree.iter_from(1234).next().map(|n| n.0), model.get(1234).copied());
        assert_eq!(snapshot.iter().map(|n| n.0).collect::<Vec<_>>(), (0..5000).collect::<Vec<_>>());
    }

    #[test]
    fn persist_writes_only_changed_paths() {
        let mut tree = SumTree::from_items((0..20_000).map(N).collect());
        let mut store = Mem::default();
        let root = tree.persist(&mut store).unwrap();
        let full = store.nodes.len();
        tree.splice(10_000..10_001, vec![N(1), N(2)]);
        tree.persist(&mut store).unwrap();
        let delta = store.nodes.len() - full;
        assert!(delta <= 4, "rewrote {delta} nodes for one edit");
        let loaded: SumTree<N> = SumTree::load(root, &mut store).unwrap();
        assert_eq!(loaded.len(), 20_000);
        assert_eq!(loaded.root().persisted_id(), Some(root));
    }
}
