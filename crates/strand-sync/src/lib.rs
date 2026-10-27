//! Replication for strand, kept separate from storage and the filesystem.
//!
//! * [`Replica`] is the whole contract with local state. Implement it (or
//!   use the provided impl for `strand::Workspace`) and any transport or
//!   topology can carry batches.
//! * [`Client`] and [`Relay`] are sans-IO state machines: they take messages
//!   and return messages. Admission rules (causal completeness, the Lamport
//!   rule, actor/timestamp uniqueness, an optional concurrency cutoff and
//!   optional full validation) live in the relay.
//! * [`transport`] has in-memory and TCP framings plus blocking drivers.
//!
//! Batches are immutable and content-addressed by `(actor, timestamp)`, and
//! integration is idempotent and order-independent once causally complete,
//! so a replacement sync layer only has to deliver every batch eventually.

pub mod client;
pub mod protocol;
pub mod relay;
pub mod replica;
pub mod transport;

pub use client::Client;
pub use protocol::{Message, RejectReason, Rejection};
pub use relay::{MemoryRelayStore, Outgoing, PeerId, Relay, RelayConfig, RelayStore};
pub use replica::{Integration, Replica};

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error(transparent)]
    Local(#[from] strand::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("connection closed")]
    Closed,
}

/// Routes messages between in-process clients and a relay until nothing
/// more is in flight. Deterministic; used by tests and simulations.
pub fn pump<R: Replica, S: RelayStore>(
    relay: &mut Relay<S>,
    clients: &mut [(PeerId, &mut Client<R>)],
    initial: Vec<(PeerId, Message)>,
) -> Result<(), SyncError> {
    let mut to_relay: std::collections::VecDeque<(PeerId, Message)> = initial.into();
    let mut rounds = 0;
    while let Some((from, msg)) = to_relay.pop_front() {
        rounds += 1;
        if rounds > 100_000 {
            return Err(SyncError::Protocol("pump did not quiesce".into()));
        }
        for out in relay.handle(from, msg) {
            if let Some((_, c)) = clients.iter_mut().find(|(id, _)| *id == out.to) {
                for reply in c.handle(out.message)? {
                    to_relay.push_back((out.to, reply));
                }
            }
        }
    }
    Ok(())
}
