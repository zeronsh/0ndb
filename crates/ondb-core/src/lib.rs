//! Core model for 0ndb: a causal graph of batches over a file-tree CRDT
//! whose files are text CRDTs. Pure data structures, no I/O.

pub mod codec;
pub mod contents;
pub mod dag;
pub mod diff;
pub mod history;
pub mod id;
pub mod op;
pub mod sumtree;
pub mod text;
pub mod tree;
pub mod version;

pub use contents::{BlobSource, Contents, INLINE_TEXT_MAX, Insertion, InsertionKey, cache_bytes, set_cache_budget};
pub use dag::{BatchHeader, Dag, DagError};
pub use history::{
    ApplyError, Dirty, FileState, GIT_HEAD_KEY, History, HistoryView, IntegrateError, Integrated, MetaEntry, Status, Txn, now_ms,
};
pub use id::{ActorId, BatchId, HistoryId, InodeId, Lamport, Oid, OpId};
pub use op::{Batch, Blob, BlobRef, Content, FileMode, ImportEntry, ImportNode, ImportParent, LineEnding, Op, Splice};
pub use sumtree::{NodeStore, StoreResult, SumTree};
pub use text::{Anchor, Bias, Everything, Fragment, Text, View};
pub use tree::{ContentKind, Inode, NodeKind, Placement, StoredInode, StoredKind, Tree};
pub use version::Version;
