//! strand: tracked, attributed, syncable worktrees.
//!
//! * [`Workspace`] — one history (causal graph + CRDT state) persisted in
//!   SQLite and shared between components.
//! * [`Mount`] — binds a workspace to a directory: ingests disk changes from
//!   any process, materializes remote ones, provides fences.
//! * [`Recorder`] — attribution scopes (turns, tool calls, commands).
//! * [`report`], [`blame`], [`revert`] — reading attribution back.
//!
//! Replication is a separate concern: see the `strand-sync` crate, which
//! only needs [`Workspace::unpushed`], [`Workspace::integrate`],
//! [`Workspace::batches_missing_from`] and [`Workspace::subscribe`].

pub mod attrib;
pub mod blame;
pub mod mount;
pub mod report;
pub mod revert;
pub mod workspace;

pub use attrib::{Recorder, Scope, ScopeId, ScopeKind, ScopeRecord};
pub use mount::{FenceOutcome, Mount, MountHandle, MountOptions};
pub use strand_core as core;
pub use workspace::{ActorInfo, ActorKind, BatchSummary, Committed, Event, IntegrateReport, Workspace};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Store(#[from] strand_store::StoreError),
    #[error(transparent)]
    Integrate(#[from] strand_core::IntegrateError),
    #[error(transparent)]
    Apply(#[from] strand_core::ApplyError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Watch(#[from] notify::Error),
    #[error("the mount has stopped")]
    MountStopped,
    #[error("{0}")]
    Invalid(String),
}
