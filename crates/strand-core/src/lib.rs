//! Core model for strand: a causal graph of batches over a file-tree CRDT
//! whose files are text CRDTs. Pure data structures, no I/O.

pub mod codec;
pub mod dag;
pub mod diff;
pub mod history;
pub mod id;
pub mod op;
pub mod text;
pub mod tree;
pub mod version;

pub use dag::{BatchHeader, Dag, DagError};
pub use history::{ApplyError, FileState, History, HistoryView, IntegrateError, Integrated, Status, Txn, now_ms};
pub use id::{ActorId, BatchId, HistoryId, InodeId, Lamport, Oid, OpId};
pub use op::{Batch, Blob, BlobRef, Content, FileMode, ImportEntry, ImportNode, ImportParent, LineEnding, Op, Splice};
pub use text::{Anchor, Bias, Everything, Fragment, Text, View};
pub use tree::{ContentKind, Inode, NodeKind, Placement, Tree};
pub use version::Version;
