use std::collections::BTreeSet;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::id::{BatchId, Lamport};

/// A causal frontier: the set of batches with no descendants inside the
/// version. The empty frontier is the root (nothing applied).
#[derive(Clone, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Version(BTreeSet<BatchId>);

impl Version {
    pub fn root() -> Self {
        Version(BTreeSet::new())
    }

    pub fn single(id: BatchId) -> Self {
        Version(BTreeSet::from([id]))
    }

    pub fn is_root(&self) -> bool {
        self.0.is_empty()
    }

    pub fn heads(&self) -> impl ExactSizeIterator<Item = &BatchId> + '_ {
        self.0.iter()
    }

    pub fn contains_head(&self, id: &BatchId) -> bool {
        self.0.contains(id)
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Largest timestamp inside the version. Because children always start
    /// after their parents, this is the max over the heads.
    pub fn max_ts(&self) -> Lamport {
        self.0.iter().map(|h| h.ts).max().unwrap_or(0)
    }

    pub(crate) fn insert(&mut self, id: BatchId) {
        self.0.insert(id);
    }

    pub(crate) fn remove(&mut self, id: &BatchId) {
        self.0.remove(id);
    }
}

impl FromIterator<BatchId> for Version {
    fn from_iter<T: IntoIterator<Item = BatchId>>(iter: T) -> Self {
        Version(iter.into_iter().collect())
    }
}

impl fmt::Debug for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            return write!(f, "root");
        }
        let parts: Vec<String> = self.0.iter().map(|h| format!("{h:?}")).collect();
        write!(f, "{}", parts.join("+"))
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}
