use serde::{Deserialize, Serialize};

use crate::dag::BatchHeader;
use crate::id::{BatchId, InodeId, Oid, OpId};

/// Replace `del` bytes at `at` with the next `ins` bytes of the operation's
/// inserted text. Offsets are in the visible text of the batch's parent
/// version, so they never depend on concurrent edits the author hadn't seen.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Splice {
    pub at: u64,
    pub del: u64,
    pub ins: u64,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub enum FileMode {
    #[default]
    Regular,
    Executable,
}

/// How newlines are written to disk. Text is always stored with `\n`.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub enum LineEnding {
    #[default]
    Lf,
    Crlf,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct BlobRef {
    pub oid: Oid,
    pub len: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Content {
    /// UTF-8 text, newline-normalized, carried inline.
    Text(Vec<u8>),
    /// Large text stored as a content-addressed blob attachment and read
    /// lazily, so untouched big files never need to be in memory.
    TextBlob(BlobRef),
    /// Opaque bytes, stored out of line and shipped as a batch attachment.
    Binary(BlobRef),
}

impl Content {
    /// Text content, inline when small and as a blob (to attach to the
    /// batch) when large.
    pub fn text(bytes: Vec<u8>) -> (Content, Option<Blob>) {
        if bytes.len() <= crate::contents::INLINE_TEXT_MAX {
            return (Content::Text(bytes), None);
        }
        let oid = Oid::of_blob(&bytes);
        (Content::TextBlob(BlobRef { oid, len: bytes.len() as u64 }), Some(Blob { oid, data: bytes }))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ImportParent {
    Existing(InodeId),
    /// Index of an earlier entry of the same import.
    Entry(u32),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ImportNode {
    Dir,
    File { mode: FileMode, line_ending: LineEnding, content: Content },
    Symlink { target: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportEntry {
    pub parent: ImportParent,
    pub name: String,
    pub node: ImportNode,
}

/// One change to a history. Entries are addressed by inode, never by path,
/// so renames and edits commute.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Op {
    CreateDir {
        parent: InodeId,
        name: String,
    },
    CreateFile {
        parent: InodeId,
        name: String,
        mode: FileMode,
        line_ending: LineEnding,
        content: Content,
    },
    CreateSymlink {
        parent: InodeId,
        name: String,
        target: String,
    },
    /// Bulk creation (initial adoption of a directory). Entry `i` becomes
    /// inode `(op, i)`; text of all entries is concatenated into one insertion.
    Import {
        entries: Vec<ImportEntry>,
    },
    Rename {
        inode: InodeId,
        parent: InodeId,
        name: String,
    },
    Remove {
        inode: InodeId,
    },
    Restore {
        inode: InodeId,
    },
    EditText {
        inode: InodeId,
        text: Vec<u8>,
        splices: Vec<Splice>,
    },
    SetContent {
        inode: InodeId,
        content: Content,
    },
    SetMode {
        inode: InodeId,
        mode: FileMode,
    },
    SetLineEnding {
        inode: InodeId,
        ending: LineEnding,
    },
    SetSymlinkTarget {
        inode: InodeId,
        target: String,
    },
    /// Marks a batch as git moving the checkout (branch switch, pull,
    /// rebase, reset): the batch's file changes came from git, not from
    /// anyone editing. `to` is `ref@commit` (or a bare commit when detached).
    GitCheckout {
        from: Option<String>,
        to: String,
    },
    /// Last-writer-wins key/value annotation (actor registry, attribution
    /// records, report cursors). `None` deletes.
    Meta {
        key: String,
        value: Option<Vec<u8>>,
    },
    /// Marks a batch as files git wrote mid-operation without moving HEAD
    /// (a merge, cherry-pick, revert or rebase stopped for conflicts).
    GitWrite {
        operation: String,
        head: Option<String>,
    },
}

impl Op {
    /// Inodes whose materialized state this op can change. Removing a
    /// directory also affects its descendants, which callers expand.
    pub fn touched(&self, id: OpId) -> Vec<InodeId> {
        match self {
            Op::CreateDir { .. } | Op::CreateFile { .. } | Op::CreateSymlink { .. } => vec![InodeId::new(id, 0)],
            Op::Import { entries } => (0..entries.len() as u32).map(|i| InodeId::new(id, i)).collect(),
            Op::Rename { inode, .. }
            | Op::Remove { inode }
            | Op::Restore { inode }
            | Op::EditText { inode, .. }
            | Op::SetContent { inode, .. }
            | Op::SetMode { inode, .. }
            | Op::SetLineEnding { inode, .. }
            | Op::SetSymlinkTarget { inode, .. } => vec![*inode],
            Op::Meta { .. } | Op::GitCheckout { .. } | Op::GitWrite { .. } => vec![],
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Blob {
    pub oid: Oid,
    pub data: Vec<u8>,
}

/// The unit of replication: a header plus its operations (op `i` has id
/// `(header.start + i, header.actor)`) and any binary attachments.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Batch {
    pub header: BatchHeader,
    pub ops: Vec<Op>,
    pub blobs: Vec<Blob>,
}

impl Batch {
    pub fn id(&self) -> BatchId {
        self.header.id()
    }

    pub fn ops_with_ids(&self) -> impl Iterator<Item = (OpId, &Op)> {
        self.ops.iter().enumerate().map(|(i, op)| (self.header.op_id(i), op))
    }

    pub fn touched(&self) -> Vec<InodeId> {
        let mut out: Vec<InodeId> = self.ops_with_ids().flat_map(|(id, op)| op.touched(id)).collect();
        out.sort();
        out.dedup();
        out
    }
}
