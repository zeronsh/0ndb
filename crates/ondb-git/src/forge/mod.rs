//! Git hosting providers ("forges") behind one interface.
//!
//! Everything above this module speaks [`Forge`]: repositories, change
//! requests (pull requests, merge requests) and auth. Which implementation
//! serves a remote is decided by [`Forges`] from the remote's host, with
//! mappings for self-hosted instances. Adding a provider means implementing
//! [`Forge`] and registering it; nothing else changes.

mod github;

use std::collections::HashMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

pub use github::GitHub;

use crate::remote::RemoteUrl;

#[derive(Debug, thiserror::Error)]
pub enum ForgeError {
    #[error("no provider serves {0}")]
    Unsupported(String),
    #[error("{0} is not installed")]
    CliMissing(&'static str),
    #[error("not signed in to {0}")]
    Auth(String),
    #[error("rate limited")]
    RateLimited,
    #[error("request timed out")]
    Timeout,
    #[error("not found")]
    NotFound,
    #[error("unexpected response: {0}")]
    Decode(String),
    #[error("{0}")]
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForgeRepo {
    /// Canonical `namespace/name` (follows renames).
    pub slug: String,
    pub default_branch: Option<String>,
    pub web_url: String,
    pub private: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChangeState {
    Open,
    Closed,
    Merged,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReviewState {
    Approved,
    ChangesRequested,
    ReviewRequired,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChecksState {
    #[default]
    None,
    Pending,
    Passing,
    Failing,
}

/// A pull request / merge request, normalized across providers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChangeRequest {
    /// Provider-scoped number (`#123`, `!123`).
    pub number: u64,
    pub title: String,
    pub url: String,
    pub state: ChangeState,
    pub draft: bool,
    pub head_branch: String,
    /// Owner of the head repository when it is a fork.
    pub head_owner: Option<String>,
    pub base_branch: String,
    pub head_oid: Option<String>,
    pub author: Option<String>,
    pub checks: ChecksState,
    pub review: Option<ReviewState>,
    pub mergeable: Option<bool>,
    pub updated_at: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NewChangeRequest {
    pub title: String,
    pub body: String,
    pub head: String,
    pub base: String,
    pub draft: bool,
}

/// A git hosting provider.
pub trait Forge: Send + Sync {
    /// Stable provider id (`"github"`, `"gitlab"`, ...).
    fn id(&self) -> &'static str;
    /// Whether the user is signed in for `host`.
    fn signed_in(&self, host: &str) -> Result<bool, ForgeError>;
    fn repository(&self, remote: &RemoteUrl) -> Result<ForgeRepo, ForgeError>;
    /// The change request whose head is `branch` (preferring open ones, then
    /// the most recently updated).
    fn change_request_for_branch(
        &self,
        remote: &RemoteUrl,
        branch: &str,
        head_owner: Option<&str>,
    ) -> Result<Option<ChangeRequest>, ForgeError>;
    fn open_change_requests(&self, remote: &RemoteUrl, limit: usize) -> Result<Vec<ChangeRequest>, ForgeError>;
    fn create_change_request(&self, remote: &RemoteUrl, req: &NewChangeRequest) -> Result<ChangeRequest, ForgeError>;
}

/// Picks the provider for a remote by host.
#[derive(Clone)]
pub struct Forges {
    providers: HashMap<&'static str, Arc<dyn Forge>>,
    hosts: HashMap<String, &'static str>,
}

impl Default for Forges {
    /// The built-in providers with their public hosts.
    fn default() -> Self {
        let mut f = Forges::empty();
        f.register(Arc::new(GitHub::default()), &["github.com"]);
        f
    }
}

impl Forges {
    pub fn empty() -> Self {
        Forges { providers: HashMap::new(), hosts: HashMap::new() }
    }

    /// Adds a provider serving `hosts`.
    pub fn register(&mut self, forge: Arc<dyn Forge>, hosts: &[&str]) {
        let id = forge.id();
        self.providers.insert(id, forge);
        for h in hosts {
            self.hosts.insert(h.to_ascii_lowercase(), id);
        }
    }

    /// Routes a self-hosted instance (`github.acme.com` -> `"github"`).
    pub fn map_host(&mut self, host: &str, provider: &'static str) -> Result<(), ForgeError> {
        if !self.providers.contains_key(provider) {
            return Err(ForgeError::Unsupported(provider.to_string()));
        }
        self.hosts.insert(host.to_ascii_lowercase(), provider);
        Ok(())
    }

    pub fn for_remote(&self, remote: &RemoteUrl) -> Result<Arc<dyn Forge>, ForgeError> {
        self.hosts
            .get(&remote.host)
            .and_then(|id| self.providers.get(id))
            .cloned()
            .ok_or_else(|| ForgeError::Unsupported(remote.host.clone()))
    }
}
