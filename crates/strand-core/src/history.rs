use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::dag::{BatchHeader, Dag, DagError};
use crate::id::{ActorId, BatchId, HistoryId, InodeId, Lamport, OpId};
use crate::op::{Batch, Blob, BlobRef, Content, FileMode, ImportNode, ImportParent, LineEnding, Op, Splice};
use crate::text::{Insertions, Text, TextError, View};
use crate::tree::{ContentKind, FileNode, Inode, Lww, NodeKind, Placement, Tree};
use crate::version::Version;

/// Which batches count as applied when reading or applying. Built from a
/// version (everything not in its causal past is excluded) or from an
/// explicit exclusion set (selective views for reports and reverts).
pub struct HistoryView<'a> {
    dag: &'a Dag,
    excluded: Option<&'a HashSet<BatchId>>,
    /// Ops of a batch being applied: `(actor, start, limit)` — ops of that
    /// run below `limit` are observed, the rest are not.
    pending: Option<(ActorId, Lamport, Lamport)>,
}

impl View for HistoryView<'_> {
    fn observes(&self, op: OpId) -> bool {
        if op == OpId::ZERO {
            return true;
        }
        if let Some((actor, start, limit)) = self.pending
            && op.actor == actor
            && op.ts >= start
        {
            return op.ts < limit;
        }
        match self.excluded {
            None => true,
            Some(ex) if ex.is_empty() => true,
            Some(ex) => self.dag.batch_of(op).is_some_and(|b| !ex.contains(&b)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Status {
    Healthy,
    /// An admitted batch could not be applied; the in-memory state must be
    /// rebuilt from durable storage before more work is accepted.
    RequiresReload {
        batch: BatchId,
        reason: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ApplyError {
    #[error("unknown inode {0:?}")]
    UnknownInode(InodeId),
    #[error("{0:?} is not a directory")]
    NotADirectory(InodeId),
    #[error("{0:?} is not a regular file")]
    NotAFile(InodeId),
    #[error("{0:?} is not a symlink")]
    NotASymlink(InodeId),
    #[error("invalid entry name {0:?}")]
    InvalidName(String),
    #[error("the root cannot be renamed or removed")]
    Root,
    #[error("import entry {0} references an invalid parent")]
    InvalidImport(u32),
    #[error(transparent)]
    Text(#[from] TextError),
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IntegrateError {
    #[error(transparent)]
    Dag(#[from] DagError),
    #[error("batch {batch:?} declares {declared} ops but carries {actual}")]
    Malformed { batch: BatchId, declared: u64, actual: usize },
    #[error("op {index} of batch {batch:?} failed: {error}")]
    Op { batch: BatchId, index: usize, error: ApplyError },
    #[error("history requires reload")]
    RequiresReload,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Integrated {
    Applied { touched: Vec<InodeId> },
    Duplicate,
}

/// Materializable state of a file at some view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FileState {
    Text { bytes: Vec<u8>, ending: LineEnding, mode: FileMode },
    Binary { blob: BlobRef, mode: FileMode },
}

/// One history: the causal graph plus the CRDT state it produces.
#[derive(Clone, Serialize, Deserialize)]
pub struct History {
    id: HistoryId,
    dag: Dag,
    tree: Tree,
    insertions: Insertions,
    meta: BTreeMap<String, (OpId, Option<Vec<u8>>)>,
    status: Status,
}

fn valid_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\0')
}

struct State<'a> {
    tree: &'a mut Tree,
    insertions: &'a mut Insertions,
    meta: &'a mut BTreeMap<String, (OpId, Option<Vec<u8>>)>,
}

/// Ops may only reference entries inside their own causal past; anything
/// else would apply differently depending on what a replica happens to hold.
fn require_known(view: &dyn View, id: &InodeId) -> Result<(), ApplyError> {
    if id.is_root() || view.observes(id.op) { Ok(()) } else { Err(ApplyError::UnknownInode(*id)) }
}

impl State<'_> {
    fn require_dir(&self, view: &dyn View, id: &InodeId) -> Result<(), ApplyError> {
        require_known(view, id)?;
        let inode = self.tree.get(id).ok_or(ApplyError::UnknownInode(*id))?;
        if !inode.is_dir() {
            return Err(ApplyError::NotADirectory(*id));
        }
        Ok(())
    }

    fn inode_mut(&mut self, view: &dyn View, id: &InodeId) -> Result<&mut Inode, ApplyError> {
        require_known(view, id)?;
        self.tree.get_mut(id).ok_or(ApplyError::UnknownInode(*id))
    }

    fn file_mut(&mut self, view: &dyn View, id: &InodeId) -> Result<&mut FileNode, ApplyError> {
        self.inode_mut(view, id)?.file_mut().ok_or(ApplyError::NotAFile(*id))
    }

    fn new_inode(&mut self, id: InodeId, op: OpId, parent: InodeId, name: &str, kind: NodeKind) {
        self.tree.insert(Inode {
            id,
            kind,
            placement: Lww::new(op, Placement { parent, name: name.to_string() }),
            alive: Lww::new(op, true),
        });
    }

    fn file_node(op: OpId, mode: FileMode, ending: LineEnding, content: &Content, text_off: u64) -> FileNode {
        let (text, kind) = match content {
            Content::Text(bytes) => (Text::from_insertion(op, text_off, bytes.len() as u64), ContentKind::Text),
            Content::Binary(blob) => (Text::new(), ContentKind::Binary(*blob)),
        };
        FileNode { text, content: Lww::new(op, kind), mode: Lww::new(op, mode), line_ending: Lww::new(op, ending) }
    }

    fn apply(&mut self, view: &dyn View, id: OpId, op: &Op) -> Result<Vec<InodeId>, ApplyError> {
        match op {
            Op::CreateDir { parent, name } => {
                self.check_create(view, parent, name)?;
                let inode = InodeId::new(id, 0);
                self.new_inode(inode, id, *parent, name, NodeKind::Dir);
                Ok(vec![inode])
            }
            Op::CreateFile { parent, name, mode, line_ending, content } => {
                self.check_create(view, parent, name)?;
                if let Content::Text(bytes) = content {
                    self.insertions.insert(id, Arc::from(bytes.as_slice()));
                }
                let inode = InodeId::new(id, 0);
                let node = Self::file_node(id, *mode, *line_ending, content, 0);
                self.new_inode(inode, id, *parent, name, NodeKind::File(node));
                Ok(vec![inode])
            }
            Op::CreateSymlink { parent, name, target } => {
                self.check_create(view, parent, name)?;
                let inode = InodeId::new(id, 0);
                self.new_inode(inode, id, *parent, name, NodeKind::Symlink { target: Lww::new(id, target.clone()) });
                Ok(vec![inode])
            }
            Op::Import { entries } => {
                let mut is_dir = Vec::with_capacity(entries.len());
                for (i, e) in entries.iter().enumerate() {
                    if !valid_name(&e.name) {
                        return Err(ApplyError::InvalidName(e.name.clone()));
                    }
                    match e.parent {
                        ImportParent::Existing(p) => self.require_dir(view, &p)?,
                        ImportParent::Entry(j) if (j as usize) < i && is_dir[j as usize] => {}
                        ImportParent::Entry(_) => return Err(ApplyError::InvalidImport(i as u32)),
                    }
                    is_dir.push(matches!(e.node, ImportNode::Dir));
                }
                let mut buffer = Vec::new();
                let mut touched = Vec::with_capacity(entries.len());
                for (i, e) in entries.iter().enumerate() {
                    let inode = InodeId::new(id, i as u32);
                    let parent = match e.parent {
                        ImportParent::Existing(p) => p,
                        ImportParent::Entry(j) => InodeId::new(id, j),
                    };
                    let kind = match &e.node {
                        ImportNode::Dir => NodeKind::Dir,
                        ImportNode::Symlink { target } => NodeKind::Symlink { target: Lww::new(id, target.clone()) },
                        ImportNode::File { mode, line_ending, content } => {
                            let off = buffer.len() as u64;
                            if let Content::Text(bytes) = content {
                                buffer.extend_from_slice(bytes);
                            }
                            NodeKind::File(Self::file_node(id, *mode, *line_ending, content, off))
                        }
                    };
                    self.new_inode(inode, id, parent, &e.name, kind);
                    touched.push(inode);
                }
                if !buffer.is_empty() {
                    self.insertions.insert(id, Arc::from(buffer));
                }
                Ok(touched)
            }
            Op::Rename { inode, parent, name } => {
                if inode.is_root() {
                    return Err(ApplyError::Root);
                }
                if !valid_name(name) {
                    return Err(ApplyError::InvalidName(name.clone()));
                }
                self.inode_mut(view, inode)?;
                self.require_dir(view, parent)?;
                self.tree.place(*inode, id, Placement { parent: *parent, name: name.clone() });
                let mut touched = vec![*inode];
                touched.extend(self.tree.descendants(view, inode));
                Ok(touched)
            }
            Op::Remove { inode } => {
                if inode.is_root() {
                    return Err(ApplyError::Root);
                }
                self.inode_mut(view, inode)?;
                let mut touched = vec![*inode];
                touched.extend(self.tree.descendants(view, inode));
                for t in &touched {
                    if let Some(i) = self.tree.get_mut(t) {
                        i.alive.set(id, false);
                    }
                }
                Ok(touched)
            }
            Op::Restore { inode } => {
                self.inode_mut(view, inode)?.alive.set(id, true);
                Ok(vec![*inode])
            }
            Op::EditText { inode, text, splices } => {
                let file = self.file_mut(view, inode)?;
                file.text.apply(id, view, splices, text.len() as u64)?;
                if !text.is_empty() {
                    self.insertions.insert(id, Arc::from(text.as_slice()));
                }
                Ok(vec![*inode])
            }
            Op::SetContent { inode, content } => {
                let file = self.file_mut(view, inode)?;
                match content {
                    Content::Text(bytes) => {
                        let len = file.text.len_in(view);
                        let splice = Splice { at: 0, del: len, ins: bytes.len() as u64 };
                        file.text.apply(id, view, &[splice], bytes.len() as u64)?;
                        file.content.set(id, ContentKind::Text);
                        if !bytes.is_empty() {
                            self.insertions.insert(id, Arc::from(bytes.as_slice()));
                        }
                    }
                    Content::Binary(blob) => file.content.set(id, ContentKind::Binary(*blob)),
                }
                Ok(vec![*inode])
            }
            Op::SetMode { inode, mode } => {
                self.file_mut(view, inode)?.mode.set(id, *mode);
                Ok(vec![*inode])
            }
            Op::SetLineEnding { inode, ending } => {
                self.file_mut(view, inode)?.line_ending.set(id, *ending);
                Ok(vec![*inode])
            }
            Op::SetSymlinkTarget { inode, target: t } => {
                match &mut self.inode_mut(view, inode)?.kind {
                    NodeKind::Symlink { target } => target.set(id, t.clone()),
                    _ => return Err(ApplyError::NotASymlink(*inode)),
                }
                Ok(vec![*inode])
            }
            Op::Meta { key, value } => {
                let replace = self.meta.get(key).is_none_or(|(o, _)| *o < id);
                if replace {
                    self.meta.insert(key.clone(), (id, value.clone()));
                }
                Ok(vec![])
            }
        }
    }

    fn check_create(&self, view: &dyn View, parent: &InodeId, name: &str) -> Result<(), ApplyError> {
        if !valid_name(name) {
            return Err(ApplyError::InvalidName(name.to_string()));
        }
        self.require_dir(view, parent)
    }
}

/// An open local batch. Each pushed op is validated and applied immediately,
/// so later ops (and reads through [`Txn::view`]) see earlier ones.
pub struct Txn<'a> {
    h: &'a mut History,
    actor: ActorId,
    start: Lamport,
    parents: Version,
    excluded: HashSet<BatchId>,
    ops: Vec<Op>,
    blobs: Vec<Blob>,
    touched: Vec<InodeId>,
}

impl<'a> Txn<'a> {
    pub fn actor(&self) -> ActorId {
        self.actor
    }

    pub fn parents(&self) -> &Version {
        &self.parents
    }

    /// Id the next pushed op will get (and inode id of a create).
    pub fn next_id(&self) -> OpId {
        OpId::new(self.start + self.ops.len() as u64, self.actor)
    }

    pub fn len(&self) -> usize {
        self.ops.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ops.is_empty()
    }

    pub fn history(&self) -> &History {
        self.h
    }

    /// The parent version plus this batch's ops so far.
    pub fn view(&self) -> HistoryView<'_> {
        HistoryView {
            dag: &self.h.dag,
            excluded: Some(&self.excluded),
            pending: Some((self.actor, self.start, self.start + self.ops.len() as u64)),
        }
    }

    pub fn push(&mut self, op: Op) -> Result<OpId, ApplyError> {
        let id = self.next_id();
        let h = &mut *self.h;
        let view = HistoryView { dag: &h.dag, excluded: Some(&self.excluded), pending: Some((self.actor, self.start, id.ts)) };
        let mut state = State { tree: &mut h.tree, insertions: &mut h.insertions, meta: &mut h.meta };
        let touched = state.apply(&view, id, &op)?;
        self.touched.extend(touched);
        self.ops.push(op);
        Ok(id)
    }

    pub fn attach_blob(&mut self, blob: Blob) {
        if !self.blobs.iter().any(|b| b.oid == blob.oid) {
            self.blobs.push(blob);
        }
    }

    pub fn touched(&self) -> &[InodeId] {
        &self.touched
    }

    fn finish(self) -> Option<Batch> {
        if self.ops.is_empty() {
            return None;
        }
        let header = BatchHeader {
            actor: self.actor,
            start: self.start,
            end: self.start + self.ops.len() as u64 - 1,
            parents: self.parents,
            wall_ms: now_ms(),
        };
        self.h.dag.insert(header.clone()).expect("local batch satisfies admission rules");
        Some(Batch { header, ops: self.ops, blobs: self.blobs })
    }
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl History {
    pub fn new(id: HistoryId) -> Self {
        History {
            id,
            dag: Dag::new(),
            tree: Tree::new(),
            insertions: Insertions::new(),
            meta: BTreeMap::new(),
            status: Status::Healthy,
        }
    }

    pub fn id(&self) -> HistoryId {
        self.id
    }

    pub fn dag(&self) -> &Dag {
        &self.dag
    }

    pub fn tree(&self) -> &Tree {
        &self.tree
    }

    pub fn insertions(&self) -> &Insertions {
        &self.insertions
    }

    pub fn heads(&self) -> &Version {
        self.dag.heads()
    }

    pub fn status(&self) -> &Status {
        &self.status
    }

    pub fn current(&self) -> HistoryView<'_> {
        HistoryView { dag: &self.dag, excluded: None, pending: None }
    }

    /// A view excluding an explicit set of batches.
    pub fn excluding<'a>(&'a self, excluded: &'a HashSet<BatchId>) -> HistoryView<'a> {
        HistoryView { dag: &self.dag, excluded: Some(excluded), pending: None }
    }

    /// Batches that a view at `version` must exclude.
    pub fn exclusions_for(&self, version: &Version) -> HashSet<BatchId> {
        self.dag.difference(self.dag.heads(), version)
    }

    /// Runs `f` inside a local batch authored by `actor` on top of `parents`
    /// (default: current heads). Ops pushed before an error are kept, so the
    /// returned batch must always be persisted.
    pub fn transact<R, E>(
        &mut self,
        actor: ActorId,
        parents: Option<Version>,
        f: impl FnOnce(&mut Txn<'_>) -> Result<R, E>,
    ) -> Result<(Option<Batch>, Result<R, E>), IntegrateError> {
        if self.status != Status::Healthy {
            return Err(IntegrateError::RequiresReload);
        }
        let parents = parents.unwrap_or_else(|| self.dag.heads().clone());
        let missing = self.dag.missing_parents(&parents);
        if !missing.is_empty() {
            return Err(DagError::MissingParents { batch: OpId::new(self.dag.max_ts() + 1, actor), missing }.into());
        }
        let excluded = self.exclusions_for(&parents);
        let mut txn = Txn {
            start: self.dag.max_ts() + 1,
            h: self,
            actor,
            parents,
            excluded,
            ops: Vec::new(),
            blobs: Vec::new(),
            touched: Vec::new(),
        };
        let result = f(&mut txn);
        Ok((txn.finish(), result))
    }

    /// Applies a batch authored elsewhere (or replayed from storage).
    pub fn integrate(&mut self, batch: &Batch) -> Result<Integrated, IntegrateError> {
        if self.status != Status::Healthy {
            return Err(IntegrateError::RequiresReload);
        }
        let header = &batch.header;
        let id = header.id();
        if self.dag.check(header)? {
            return Ok(Integrated::Duplicate);
        }
        if batch.ops.len() as u64 != header.len() {
            return Err(IntegrateError::Malformed { batch: id, declared: header.len(), actual: batch.ops.len() });
        }
        let excluded = self.exclusions_for(&header.parents);
        self.dag.insert(header.clone())?;
        let mut touched = Vec::new();
        for (i, op) in batch.ops.iter().enumerate() {
            let op_id = header.op_id(i);
            let view =
                HistoryView { dag: &self.dag, excluded: Some(&excluded), pending: Some((header.actor, header.start, op_id.ts)) };
            let mut state = State { tree: &mut self.tree, insertions: &mut self.insertions, meta: &mut self.meta };
            match state.apply(&view, op_id, op) {
                Ok(t) => touched.extend(t),
                Err(error) => {
                    self.status = Status::RequiresReload { batch: id, reason: error.to_string() };
                    return Err(IntegrateError::Op { batch: id, index: i, error });
                }
            }
        }
        touched.sort();
        touched.dedup();
        Ok(Integrated::Applied { touched })
    }

    pub fn meta(&self, key: &str) -> Option<&[u8]> {
        self.meta.get(key).and_then(|(_, v)| v.as_deref())
    }

    pub fn meta_with_prefix<'a>(&'a self, prefix: &'a str) -> impl Iterator<Item = (&'a str, &'a [u8])> + 'a {
        self.meta
            .range(prefix.to_string()..)
            .take_while(move |(k, _)| k.starts_with(prefix))
            .filter_map(|(k, (_, v))| v.as_deref().map(|v| (k.as_str(), v)))
    }

    pub fn inode(&self, id: &InodeId) -> Option<&Inode> {
        self.tree.get(id)
    }

    pub fn lookup(&self, path: &str) -> Option<InodeId> {
        self.tree.lookup(&self.current(), path)
    }

    pub fn path_of(&self, id: &InodeId) -> Option<String> {
        self.tree.path_of(&self.current(), id)
    }

    pub fn text(&self, id: &InodeId) -> Option<Vec<u8>> {
        Some(self.tree.get(id)?.file()?.text.read(&self.insertions))
    }

    pub fn text_in(&self, view: &dyn View, id: &InodeId) -> Option<Vec<u8>> {
        Some(self.tree.get(id)?.file()?.text.read_in(&self.insertions, view))
    }

    pub fn file_state(&self, view: &dyn View, id: &InodeId) -> Option<FileState> {
        let file = self.tree.get(id)?.file()?;
        let mode = file.mode.get_in(view).copied().unwrap_or_default();
        match file.content.get_in(view)? {
            ContentKind::Text => Some(FileState::Text {
                bytes: file.text.read_in(&self.insertions, view),
                ending: file.line_ending.get_in(view).copied().unwrap_or_default(),
                mode,
            }),
            ContentKind::Binary(blob) => Some(FileState::Binary { blob: *blob, mode }),
        }
    }

    pub fn symlink_target(&self, view: &dyn View, id: &InodeId) -> Option<String> {
        match &self.tree.get(id)?.kind {
            NodeKind::Symlink { target } => target.get_in(view).cloned(),
            _ => None,
        }
    }

    /// Present entries with paths at the current state.
    pub fn walk(&self) -> Vec<(String, InodeId)> {
        self.tree.walk(&self.current())
    }
}
