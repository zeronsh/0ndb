//! Provider sessions for 0ndb.
//!
//! * [`Provider`] puts agent CLIs behind one interface; [`claude::ClaudeCode`]
//!   drives Claude Code, [`mock::Mock`] is a scripted stand-in.
//! * [`Sessions`] runs agent turns in managed worktrees: threads are message
//!   trees (editing makes branches), every message is pinned to a worktree
//!   version, every turn and tool call is an attribution scope, and every
//!   provider event is recorded verbatim with tool calls and CLI output.
//!   Providers can be switched mid-thread; idle processes are bounded.

pub mod claude;
pub mod codex;
pub mod mock;
pub mod provider;
pub mod sessions;
pub mod store;

pub use provider::{Capabilities, Event, EventKind, Interrupter, Provider, Run, StartRequest};
pub use sessions::{Page, SessionOptions, Sessions, Turn, Update};
pub use store::{Message, ProviderSession, RecordedEvent, Role, Status, Thread, ToolCall};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Store(#[from] rusqlite::Error),
    #[error(transparent)]
    Ondb(#[from] ondb::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Git(#[from] ondb::git::Error),
    #[error("provider: {0}")]
    Provider(String),
    #[error("thread {0} already has a turn running")]
    Busy(String),
    #[error("{0}")]
    Invalid(String),
}
