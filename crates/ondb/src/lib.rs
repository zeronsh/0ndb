//! 0ndb: tracked, attributed, syncable worktrees.
//!
//! * [`Workspace`] — one history (causal graph + CRDT state) persisted in
//!   SQLite and shared between components.
//! * [`Mount`] — binds a workspace to a directory: ingests disk changes from
//!   any process, materializes remote ones, provides fences.
//! * [`Recorder`] — attribution scopes (turns, tool calls, commands).
//! * [`report`], [`blame`], [`revert`] — reading attribution back.
//!
//! Replication is a separate concern: see the `ondb-sync` crate, which
//! only needs [`Workspace::unpushed`], [`Workspace::integrate`],
//! [`Workspace::batches_missing_from`] and [`Workspace::subscribe`].

pub mod attrib;
pub mod blame;
pub mod land;
pub mod mount;
pub mod report;
pub mod revert;
pub mod timeline;
#[doc(hidden)]
pub mod timing;
pub mod workspace;
pub mod worktrees;

pub use attrib::{Recorder, Scope, ScopeId, ScopeKind, ScopeRecord};
pub use land::{Conflict, ConflictKind, LandReport, Resolution, SyncReport};
pub use mount::{FenceOutcome, Mount, MountHandle, MountOptions};
pub use ondb_core as core;
pub use ondb_git as git;
pub use workspace::{ActorInfo, ActorKind, BatchSummary, Committed, Event, IntegrateReport, Workspace};
pub use worktrees::{ForkOrigin, WorktreeInfo, Worktrees};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Store(#[from] ondb_store::StoreError),
    #[error(transparent)]
    Integrate(#[from] ondb_core::IntegrateError),
    #[error(transparent)]
    Apply(#[from] ondb_core::ApplyError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Watch(#[from] notify::Error),
    #[error(transparent)]
    Git(#[from] ondb_git::Error),
    #[error(transparent)]
    Forge(#[from] ondb_git::ForgeError),
    #[error("the mount has stopped")]
    MountStopped,
    #[error("{0}")]
    Invalid(String),
}
