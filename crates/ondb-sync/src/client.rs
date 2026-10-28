use std::collections::HashSet;

use ondb_core::{BatchId, Version};

use crate::SyncError;
use crate::protocol::{Message, Rejection};
use crate::replica::Replica;

/// Client side of the protocol as a pure state machine: feed it events,
/// send whatever it returns.
pub struct Client<R: Replica> {
    replica: R,
    connected: bool,
    in_flight: HashSet<BatchId>,
    /// Permanently refused batches (and anything built on them).
    blocked: HashSet<BatchId>,
    relay_heads: Version,
    cutoff: Version,
    rejections: Vec<Rejection>,
}

impl<R: Replica> Client<R> {
    pub fn new(replica: R) -> Self {
        Client {
            replica,
            connected: false,
            in_flight: HashSet::new(),
            blocked: HashSet::new(),
            relay_heads: Version::root(),
            cutoff: Version::root(),
            rejections: Vec::new(),
        }
    }

    pub fn replica(&self) -> &R {
        &self.replica
    }

    /// The relay's concurrency cutoff as last announced.
    pub fn cutoff(&self) -> &Version {
        &self.cutoff
    }

    pub fn relay_heads(&self) -> &Version {
        &self.relay_heads
    }

    pub fn rejections(&self) -> &[Rejection] {
        &self.rejections
    }

    /// Nothing pushed is awaiting acknowledgement.
    pub fn is_idle(&self) -> bool {
        self.in_flight.is_empty()
    }

    pub fn connect(&mut self) -> Result<Vec<Message>, SyncError> {
        self.connected = true;
        self.in_flight.clear();
        let mut out = vec![Message::Hello { history: self.replica.history(), heads: self.replica.heads() }];
        out.extend(self.poll()?);
        Ok(out)
    }

    pub fn disconnected(&mut self) {
        self.connected = false;
        self.in_flight.clear();
    }

    /// Pushes local batches that aren't in flight.
    pub fn poll(&mut self) -> Result<Vec<Message>, SyncError> {
        if !self.connected {
            return Ok(Vec::new());
        }
        let batches: Vec<_> = self
            .replica
            .unpushed()?
            .into_iter()
            .filter(|b| !self.in_flight.contains(&b.id()))
            .filter(|b| {
                let blocked = self.blocked.contains(&b.id()) || b.header.parents.heads().any(|p| self.blocked.contains(p));
                if blocked {
                    self.blocked.insert(b.id());
                }
                !blocked
            })
            .collect();
        if batches.is_empty() {
            return Ok(Vec::new());
        }
        self.in_flight.extend(batches.iter().map(|b| b.id()));
        Ok(vec![Message::Batches { history: self.replica.history(), batches }])
    }

    pub fn handle(&mut self, msg: Message) -> Result<Vec<Message>, SyncError> {
        let history = self.replica.history();
        if msg.history() != history {
            return Ok(Vec::new());
        }
        let mut out = Vec::new();
        match msg {
            Message::Batches { batches, .. } => {
                let r = self.replica.integrate(batches)?;
                if r.waiting.is_empty() {
                    out.push(Message::Have { history, heads: self.replica.heads() });
                } else {
                    out.push(Message::Want { history, have: self.replica.heads() });
                }
            }
            Message::Ack { accepted, rejected, .. } => {
                self.replica.mark_pushed(&accepted)?;
                for id in &accepted {
                    self.in_flight.remove(id);
                }
                for r in rejected {
                    self.in_flight.remove(&r.batch);
                    if !r.reason.is_retryable() {
                        self.blocked.insert(r.batch);
                        self.replica.rejected(&r);
                        self.rejections.push(r);
                    }
                }
                // Retry whatever is unblocked (e.g. children of batches that
                // arrived in the same push).
                if self.in_flight.is_empty() {
                    out.extend(self.poll()?);
                }
            }
            Message::Heads { heads, cutoff, .. } => {
                let mine = self.replica.heads();
                self.relay_heads = heads.clone();
                self.cutoff = cutoff;
                if heads != mine {
                    out.push(Message::Want { history, have: mine });
                }
            }
            Message::Want { have, .. } => {
                let batches = self.replica.batches_missing_from(&have)?;
                if !batches.is_empty() {
                    out.push(Message::Batches { history, batches });
                }
            }
            Message::Hello { .. } | Message::Have { .. } => {}
        }
        Ok(out)
    }
}
