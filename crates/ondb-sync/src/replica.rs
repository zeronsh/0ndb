use ondb::Workspace;
use ondb_core::{Batch, BatchId, HistoryId, Version};

use crate::SyncError;
use crate::protocol::Rejection;

#[derive(Clone, Debug, Default)]
pub struct Integration {
    pub applied: Vec<BatchId>,
    /// Still waiting for parents.
    pub waiting: Vec<BatchId>,
    pub rejected: Vec<(BatchId, String)>,
}

/// Everything a sync layer needs from local storage. Implement this to put
/// 0ndb behind any replication scheme (a relay, peer-to-peer gossip, a
/// cloud object store, ...).
pub trait Replica {
    fn history(&self) -> HistoryId;
    fn heads(&self) -> Version;
    /// Local batches not yet acknowledged by the remote, in causal order.
    fn unpushed(&self) -> Result<Vec<Batch>, SyncError>;
    fn mark_pushed(&self, ids: &[BatchId]) -> Result<(), SyncError>;
    /// Applies remote batches; must buffer those whose parents are missing.
    fn integrate(&self, batches: Vec<Batch>) -> Result<Integration, SyncError>;
    /// Batches not included by `have` (to serve peers).
    fn batches_missing_from(&self, have: &Version) -> Result<Vec<Batch>, SyncError>;
    /// Called when the remote permanently refuses a local batch.
    fn rejected(&self, rejection: &Rejection) {
        tracing::warn!(batch = ?rejection.batch, reason = ?rejection.reason, "remote rejected a local batch");
    }
}

impl Replica for Workspace {
    fn history(&self) -> HistoryId {
        self.id()
    }

    fn heads(&self) -> Version {
        Workspace::heads(self)
    }

    fn unpushed(&self) -> Result<Vec<Batch>, SyncError> {
        Ok(Workspace::unpushed(self)?)
    }

    fn mark_pushed(&self, ids: &[BatchId]) -> Result<(), SyncError> {
        Ok(Workspace::mark_pushed(self, ids)?)
    }

    fn integrate(&self, batches: Vec<Batch>) -> Result<Integration, SyncError> {
        let r = Workspace::integrate(self, batches)?;
        Ok(Integration { applied: r.applied, waiting: r.waiting, rejected: r.rejected })
    }

    fn batches_missing_from(&self, have: &Version) -> Result<Vec<Batch>, SyncError> {
        Ok(Workspace::batches_missing_from(self, have)?)
    }
}
