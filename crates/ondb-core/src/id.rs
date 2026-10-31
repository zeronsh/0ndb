use std::fmt;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Lamport timestamp. Every operation in a history gets one, and every batch
/// starts strictly after the largest timestamp its parents contain.
pub type Lamport = u64;

/// A single writer. Each actor must only ever write from one replica: the
/// pair `(actor, timestamp)` is a globally unique operation identity.
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct ActorId(pub Uuid);

impl ActorId {
    pub const NIL: ActorId = ActorId(Uuid::nil());

    pub fn random() -> Self {
        ActorId(Uuid::new_v4())
    }

    pub fn short(&self) -> String {
        self.0.simple().to_string()[..8].to_string()
    }
}

impl fmt::Debug for ActorId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.short())
    }
}

impl fmt::Display for ActorId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Identity of one operation. Ordered by timestamp first, then actor, which
/// is the total order used to break ties between concurrent operations.
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct OpId {
    pub ts: Lamport,
    pub actor: ActorId,
}

impl OpId {
    pub const ZERO: OpId = OpId { ts: 0, actor: ActorId::NIL };

    pub fn new(ts: Lamport, actor: ActorId) -> Self {
        OpId { ts, actor }
    }
}

impl fmt::Debug for OpId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}@{}", self.ts, self.actor.short())
    }
}

impl fmt::Display for OpId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

/// A batch is named by its last operation.
pub type BatchId = OpId;

/// Stable file/directory identity: the operation that created it plus an
/// index for operations that create many entries at once (imports).
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct InodeId {
    pub op: OpId,
    pub index: u32,
}

impl InodeId {
    pub const ROOT: InodeId = InodeId { op: OpId::ZERO, index: 0 };

    pub fn new(op: OpId, index: u32) -> Self {
        InodeId { op, index }
    }

    pub fn is_root(&self) -> bool {
        *self == Self::ROOT
    }
}

impl fmt::Debug for InodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_root() {
            write!(f, "root")
        } else if self.index == 0 {
            write!(f, "{:?}", self.op)
        } else {
            write!(f, "{:?}#{}", self.op, self.index)
        }
    }
}

/// Identity of a whole history (one synced worktree).
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct HistoryId(pub Uuid);

impl HistoryId {
    pub fn random() -> Self {
        HistoryId(Uuid::new_v4())
    }
}

impl fmt::Debug for HistoryId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.simple())
    }
}

impl fmt::Display for HistoryId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Git-compatible blob object id (`sha1("blob <len>\0" ++ bytes)`), so that
/// content identity matches what `git hash-object` reports.
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Oid(pub [u8; 20]);

impl Oid {
    pub fn of_blob(bytes: &[u8]) -> Self {
        use sha1::Digest;
        let mut h = sha1::Sha1::new();
        h.update(format!("blob {}\0", bytes.len()).as_bytes());
        h.update(bytes);
        Oid(h.finalize().into())
    }

    /// The blob id of `len` bytes read from `r`, without holding them.
    pub fn of_reader(len: u64, mut r: impl std::io::Read) -> std::io::Result<Self> {
        use sha1::Digest;
        let mut h = sha1::Sha1::new();
        h.update(format!("blob {len}\0").as_bytes());
        let mut buf = vec![0u8; 1 << 20];
        let mut total = 0u64;
        loop {
            let n = r.read(&mut buf)?;
            if n == 0 {
                break;
            }
            total += n as u64;
            h.update(&buf[..n]);
        }
        if total != len {
            return Err(std::io::Error::other("changed while hashing"));
        }
        Ok(Oid(h.finalize().into()))
    }

    pub fn hex(&self) -> String {
        self.0.iter().map(|b| format!("{b:02x}")).collect()
    }
}

impl fmt::Debug for Oid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", &self.hex()[..12])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oid_matches_git_hash_object() {
        // `printf 'hello\n' | git hash-object --stdin`
        assert_eq!(Oid::of_blob(b"hello\n").hex(), "ce013625030ba8dba906f756967f9e9ca394464a");
    }

    #[test]
    fn op_order_is_timestamp_then_actor() {
        let a = ActorId(Uuid::from_u128(1));
        let b = ActorId(Uuid::from_u128(2));
        assert!(OpId::new(1, b) < OpId::new(2, a));
        assert!(OpId::new(2, a) < OpId::new(2, b));
    }
}

#[cfg(test)]
mod oid_tests {
    use super::Oid;

    #[test]
    fn blob_ids_match_git() {
        // `printf 'hello\n' | git hash-object --stdin`
        assert_eq!(Oid::of_blob(b"hello\n").hex(), "ce013625030ba8dba906f756967f9e9ca394464a");
        assert_eq!(Oid::of_blob(b"").hex(), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    }
}
