use ondb_core::codec;
use ondb_core::{Batch, BatchId, HistoryId, Version};
use serde::{Deserialize, Serialize};

pub const PROTOCOL_FORMAT: u8 = 1;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum RejectReason {
    /// Parents unknown to the relay; resend after them.
    MissingParents(Vec<BatchId>),
    /// Starts at or below its parents' frontier.
    LamportViolation,
    /// Bad timestamp range or reuse of an actor's timestamps.
    InvalidRange,
    /// Built on a version older than the relay's concurrency cutoff: the
    /// author must reload and re-author on a newer base.
    BehindCutoff,
    /// Causally fine but its operations don't apply.
    Invalid(String),
}

impl RejectReason {
    /// Whether retrying the same batch later can succeed.
    pub fn is_retryable(&self) -> bool {
        matches!(self, RejectReason::MissingParents(_))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rejection {
    pub batch: BatchId,
    pub reason: RejectReason,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Message {
    /// Client joins a history, stating what it already has.
    Hello { history: HistoryId, heads: Version },
    /// Batches in causal order (either direction).
    Batches { history: HistoryId, batches: Vec<Batch> },
    /// Request every batch not included by `have`.
    Want { history: HistoryId, have: Version },
    /// Client reports what it has integrated (feeds the cutoff).
    Have { history: HistoryId, heads: Version },
    /// Outcome of a push.
    Ack { history: HistoryId, accepted: Vec<BatchId>, rejected: Vec<Rejection> },
    /// Admitted frontier and concurrency cutoff.
    Heads { history: HistoryId, heads: Version, cutoff: Version },
}

impl Message {
    pub fn history(&self) -> HistoryId {
        match self {
            Message::Hello { history, .. }
            | Message::Batches { history, .. }
            | Message::Want { history, .. }
            | Message::Have { history, .. }
            | Message::Ack { history, .. }
            | Message::Heads { history, .. } => *history,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        codec::encode(PROTOCOL_FORMAT, self)
    }

    pub fn decode(bytes: &[u8]) -> Result<Message, codec::CodecError> {
        codec::decode(PROTOCOL_FORMAT, bytes)
    }
}
