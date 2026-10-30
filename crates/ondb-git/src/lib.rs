//! Git for 0ndb: repositories, worktrees and git hosting providers.
//!
//! * [`Repo`] reads and changes a repository through `git` itself, with
//!   bounded time and output, no prompts and no optional locks.
//! * [`RemoteUrl`] gives every spelling of a remote one identity.
//! * [`forge`] puts hosting providers (GitHub today) behind one [`Forge`]
//!   interface, chosen per remote host by [`Forges`].

pub mod cmd;
pub mod forge;
pub mod remote;
pub mod repo;

use std::path::PathBuf;

pub use forge::{ChangeRequest, ChangeState, ChecksState, Forge, ForgeError, ForgeRepo, Forges, NewChangeRequest, ReviewState};
pub use remote::RemoteUrl;
pub use repo::{Branch, Checkout, Head, Remote, Repo, RepoId, Status, Worktree, slugify};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0} is not inside a git repository")]
    NotARepo(PathBuf),
    #[error("{0} is not installed")]
    Missing(String),
    #[error("{0} timed out")]
    Timeout(String),
    #[error("{command} failed ({code:?}): {stderr}")]
    Failed { command: String, code: Option<i32>, stderr: String },
    #[error("{0}")]
    Invalid(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}
