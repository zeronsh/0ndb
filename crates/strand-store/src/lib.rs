//! SQLite persistence. Batches are the source of truth (append-only, stored
//! in arrival order, which is always topological); snapshots of the derived
//! CRDT state only speed up loading. Actor UUIDs are interned per history so
//! versions and batch keys stay small.

use std::collections::HashMap;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use strand_core::codec::{self, CodecError};
use strand_core::{
    ActorId, Batch, BatchHeader, BatchId, Blob, Content, History, HistoryId, InodeId, Oid, Op, OpId, Status, Version,
};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error(transparent)]
    Codec(#[from] CodecError),
    #[error("corrupt store: {0}")]
    Corrupt(String),
    #[error("unknown history {0}")]
    UnknownHistory(HistoryId),
}

pub type Result<T> = std::result::Result<T, StoreError>;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS store_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS histories (
    history_key INTEGER PRIMARY KEY,
    history_uuid BLOB NOT NULL UNIQUE,
    created_ms INTEGER NOT NULL,
    head TEXT NOT NULL DEFAULT '',
    max_ts INTEGER NOT NULL DEFAULT 0,
    batch_count INTEGER NOT NULL DEFAULT 0,
    status BLOB
);
CREATE TABLE IF NOT EXISTS history_actors (
    history_key INTEGER NOT NULL,
    ordinal INTEGER NOT NULL,
    actor_uuid BLOB NOT NULL,
    PRIMARY KEY (history_key, ordinal),
    UNIQUE (history_key, actor_uuid)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS batches (
    history_key INTEGER NOT NULL,
    actor INTEGER NOT NULL,
    end_ts INTEGER NOT NULL,
    start_ts INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    parents TEXT NOT NULL,
    wall_ms INTEGER NOT NULL,
    origin INTEGER NOT NULL,
    payload BLOB NOT NULL,
    PRIMARY KEY (history_key, actor, end_ts)
) WITHOUT ROWID;
CREATE UNIQUE INDEX IF NOT EXISTS batches_by_seq ON batches (history_key, seq);
CREATE TABLE IF NOT EXISTS outbox (
    history_key INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    actor INTEGER NOT NULL,
    end_ts INTEGER NOT NULL,
    PRIMARY KEY (history_key, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS snapshots (
    history_key INTEGER PRIMARY KEY,
    version TEXT NOT NULL,
    batch_count INTEGER NOT NULL,
    data BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS blobs (
    oid BLOB PRIMARY KEY,
    len INTEGER NOT NULL,
    data BLOB NOT NULL
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS mounts (
    root TEXT PRIMARY KEY,
    history_key INTEGER NOT NULL,
    ingestion_actor BLOB NOT NULL,
    synced_version TEXT NOT NULL,
    created_ms INTEGER NOT NULL,
    updated_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS mount_entries (
    root TEXT NOT NULL,
    path TEXT NOT NULL,
    inode BLOB NOT NULL,
    kind INTEGER NOT NULL,
    oid BLOB,
    mode INTEGER NOT NULL,
    mtime_ns INTEGER,
    size INTEGER,
    ino INTEGER,
    PRIMARY KEY (root, path)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS local_kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);
"#;

const SCHEMA_VERSION: &str = "1";

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct HistoryKey(i64);

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Origin {
    Local,
    Remote,
}

/// Durable state of one mounted directory: who ingests its disk changes and
/// which version the disk is known to reflect.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MountRecord {
    pub root: String,
    pub history: HistoryId,
    pub ingestion_actor: ActorId,
    pub synced_version: Version,
}

/// Cached stat/content identity of one materialized path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MountEntryRow {
    pub path: String,
    pub inode: InodeId,
    pub kind: u8,
    pub oid: Option<Oid>,
    pub mode: u8,
    pub mtime_ns: Option<i64>,
    pub size: Option<i64>,
    pub ino: Option<i64>,
}

pub struct Store {
    conn: Connection,
    actors: HashMap<(i64, ActorId), i64>,
    ordinals: HashMap<(i64, i64), ActorId>,
}

fn uuid_bytes(u: &Uuid) -> Vec<u8> {
    u.as_bytes().to_vec()
}

fn uuid_from(bytes: &[u8]) -> Result<Uuid> {
    Uuid::from_slice(bytes).map_err(|e| StoreError::Corrupt(e.to_string()))
}

fn compress(bytes: &[u8]) -> Vec<u8> {
    lz4_flex::compress_prepend_size(bytes)
}

fn decompress(bytes: &[u8]) -> Result<Vec<u8>> {
    lz4_flex::decompress_size_prepended(bytes).map_err(|e| StoreError::Corrupt(e.to_string()))
}

/// Binary blob references made by a batch's ops.
pub fn blob_refs(batch: &Batch) -> Vec<Oid> {
    let mut out = Vec::new();
    for op in &batch.ops {
        let content = match op {
            Op::CreateFile { content, .. } | Op::SetContent { content, .. } => Some(content),
            Op::Import { entries } => {
                for e in entries {
                    if let strand_core::ImportNode::File { content: Content::Binary(b), .. } = &e.node {
                        out.push(b.oid);
                    }
                }
                None
            }
            _ => None,
        };
        if let Some(Content::Binary(b)) = content {
            out.push(b.oid);
        }
    }
    out.sort();
    out.dedup();
    out
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Store> {
        Self::init(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Store> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Store> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.execute_batch(SCHEMA)?;
        let version: Option<String> =
            conn.query_row("SELECT value FROM store_meta WHERE key = 'schema_version'", [], |r| r.get(0)).optional()?;
        match version.as_deref() {
            None => {
                conn.execute("INSERT INTO store_meta (key, value) VALUES ('schema_version', ?1)", [SCHEMA_VERSION])?;
            }
            Some(SCHEMA_VERSION) => {}
            Some(other) => return Err(StoreError::Corrupt(format!("unsupported schema version {other}"))),
        }
        Ok(Store { conn, actors: HashMap::new(), ordinals: HashMap::new() })
    }

    // ----- histories -------------------------------------------------------

    pub fn create_history(&mut self, id: HistoryId) -> Result<HistoryKey> {
        self.conn.execute(
            "INSERT OR IGNORE INTO histories (history_uuid, created_ms) VALUES (?1, ?2)",
            params![uuid_bytes(&id.0), strand_core::now_ms() as i64],
        )?;
        self.history_key(id)?.ok_or(StoreError::UnknownHistory(id))
    }

    pub fn history_key(&self, id: HistoryId) -> Result<Option<HistoryKey>> {
        Ok(self
            .conn
            .query_row("SELECT history_key FROM histories WHERE history_uuid = ?1", [uuid_bytes(&id.0)], |r| r.get(0))
            .optional()?
            .map(HistoryKey))
    }

    pub fn histories(&self) -> Result<Vec<HistoryId>> {
        let mut stmt = self.conn.prepare("SELECT history_uuid FROM histories ORDER BY history_key")?;
        let rows = stmt.query_map([], |r| r.get::<_, Vec<u8>>(0))?;
        rows.map(|r| Ok(HistoryId(uuid_from(&r?)?))).collect()
    }

    fn ordinal(&mut self, key: HistoryKey, actor: ActorId) -> Result<i64> {
        if let Some(o) = self.actors.get(&(key.0, actor)) {
            return Ok(*o);
        }
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT ordinal FROM history_actors WHERE history_key = ?1 AND actor_uuid = ?2",
                params![key.0, uuid_bytes(&actor.0)],
                |r| r.get(0),
            )
            .optional()?;
        let ordinal = match existing {
            Some(o) => o,
            None => {
                let next: i64 = self.conn.query_row(
                    "SELECT COALESCE(MAX(ordinal) + 1, 0) FROM history_actors WHERE history_key = ?1",
                    [key.0],
                    |r| r.get(0),
                )?;
                self.conn.execute(
                    "INSERT INTO history_actors (history_key, ordinal, actor_uuid) VALUES (?1, ?2, ?3)",
                    params![key.0, next, uuid_bytes(&actor.0)],
                )?;
                next
            }
        };
        self.actors.insert((key.0, actor), ordinal);
        self.ordinals.insert((key.0, ordinal), actor);
        Ok(ordinal)
    }

    fn actor_for(&mut self, key: HistoryKey, ordinal: i64) -> Result<ActorId> {
        if let Some(a) = self.ordinals.get(&(key.0, ordinal)) {
            return Ok(*a);
        }
        let bytes: Vec<u8> = self.conn.query_row(
            "SELECT actor_uuid FROM history_actors WHERE history_key = ?1 AND ordinal = ?2",
            params![key.0, ordinal],
            |r| r.get(0),
        )?;
        let actor = ActorId(uuid_from(&bytes)?);
        self.actors.insert((key.0, actor), ordinal);
        self.ordinals.insert((key.0, ordinal), actor);
        Ok(actor)
    }

    /// Compact text form: `ordinal.ts` per head, joined by `,`; root is empty.
    pub fn encode_version(&mut self, key: HistoryKey, v: &Version) -> Result<String> {
        let mut parts = Vec::with_capacity(v.len());
        for h in v.heads() {
            parts.push(format!("{}.{}", self.ordinal(key, h.actor)?, h.ts));
        }
        Ok(parts.join(","))
    }

    pub fn decode_version(&mut self, key: HistoryKey, text: &str) -> Result<Version> {
        let mut heads = Vec::new();
        for part in text.split(',').filter(|p| !p.is_empty()) {
            let (o, ts) = part.split_once('.').ok_or_else(|| StoreError::Corrupt(format!("bad version {text:?}")))?;
            let o: i64 = o.parse().map_err(|_| StoreError::Corrupt(format!("bad version {text:?}")))?;
            let ts: u64 = ts.parse().map_err(|_| StoreError::Corrupt(format!("bad version {text:?}")))?;
            heads.push(OpId::new(ts, self.actor_for(key, o)?));
        }
        Ok(heads.into_iter().collect())
    }

    // ----- batches ---------------------------------------------------------

    /// Persists an integrated batch (and its blobs). Local batches are also
    /// queued for upload.
    pub fn append(&mut self, key: HistoryKey, batch: &Batch, origin: Origin, heads: &Version) -> Result<()> {
        let id = batch.id();
        let actor = self.ordinal(key, batch.header.actor)?;
        let parents = self.encode_version(key, &batch.header.parents)?;
        let head = self.encode_version(key, heads)?;
        for p in batch.header.parents.heads() {
            self.ordinal(key, p.actor)?;
        }
        let stripped = Batch { header: batch.header.clone(), ops: batch.ops.clone(), blobs: Vec::new() };
        let payload = compress(&codec::encode_batch(&stripped));
        let tx = self.conn.transaction()?;
        let seq: i64 =
            tx.query_row("SELECT COALESCE(MAX(seq) + 1, 0) FROM batches WHERE history_key = ?1", [key.0], |r| r.get(0))?;
        let inserted = tx.execute(
            "INSERT OR IGNORE INTO batches (history_key, actor, end_ts, start_ts, seq, parents, wall_ms, origin, payload)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                key.0,
                actor,
                id.ts as i64,
                batch.header.start as i64,
                seq,
                parents,
                batch.header.wall_ms as i64,
                matches!(origin, Origin::Remote) as i64,
                payload
            ],
        )?;
        if inserted > 0 {
            for blob in &batch.blobs {
                tx.execute(
                    "INSERT OR IGNORE INTO blobs (oid, len, data) VALUES (?1, ?2, ?3)",
                    params![blob.oid.0.to_vec(), blob.data.len() as i64, compress(&blob.data)],
                )?;
            }
            if origin == Origin::Local {
                tx.execute(
                    "INSERT INTO outbox (history_key, seq, actor, end_ts) VALUES (?1, ?2, ?3, ?4)",
                    params![key.0, seq, actor, id.ts as i64],
                )?;
            }
            tx.execute(
                "UPDATE histories SET head = ?2, max_ts = MAX(max_ts, ?3), batch_count = batch_count + 1 WHERE history_key = ?1",
                params![key.0, head, id.ts as i64],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    fn decode_row(&self, payload: &[u8], with_blobs: bool) -> Result<Batch> {
        let mut batch = codec::decode_batch(&decompress(payload)?)?;
        if with_blobs {
            for oid in blob_refs(&batch) {
                if let Some(data) = self.blob(&oid)? {
                    batch.blobs.push(Blob { oid, data });
                }
            }
        }
        Ok(batch)
    }

    pub fn batch(&mut self, key: HistoryKey, id: &BatchId) -> Result<Option<Batch>> {
        let actor = self.ordinal(key, id.actor)?;
        let payload: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT payload FROM batches WHERE history_key = ?1 AND actor = ?2 AND end_ts = ?3",
                params![key.0, actor, id.ts as i64],
                |r| r.get(0),
            )
            .optional()?;
        payload.map(|p| self.decode_row(&p, true)).transpose()
    }

    /// All batches in arrival (topological) order.
    pub fn all_batches(&mut self, key: HistoryKey, with_blobs: bool) -> Result<Vec<Batch>> {
        let payloads: Vec<Vec<u8>> = {
            let mut stmt = self.conn.prepare("SELECT payload FROM batches WHERE history_key = ?1 ORDER BY seq")?;
            stmt.query_map([key.0], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
        };
        payloads.iter().map(|p| self.decode_row(p, with_blobs)).collect()
    }

    /// Headers only, in arrival order (cheap: no payload decoding).
    pub fn headers(&mut self, key: HistoryKey) -> Result<Vec<BatchHeader>> {
        let rows: Vec<(i64, i64, i64, String, i64)> = {
            let mut stmt = self
                .conn
                .prepare("SELECT actor, start_ts, end_ts, parents, wall_ms FROM batches WHERE history_key = ?1 ORDER BY seq")?;
            stmt.query_map([key.0], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?
                .collect::<rusqlite::Result<_>>()?
        };
        rows.into_iter()
            .map(|(a, s, e, p, w)| {
                Ok(BatchHeader {
                    actor: self.actor_for(key, a)?,
                    start: s as u64,
                    end: e as u64,
                    parents: self.decode_version(key, &p)?,
                    wall_ms: w as u64,
                })
            })
            .collect()
    }

    pub fn unpushed(&mut self, key: HistoryKey) -> Result<Vec<Batch>> {
        let payloads: Vec<Vec<u8>> = {
            let mut stmt = self.conn.prepare(
                "SELECT b.payload FROM outbox o JOIN batches b
                   ON b.history_key = o.history_key AND b.actor = o.actor AND b.end_ts = o.end_ts
                 WHERE o.history_key = ?1 ORDER BY o.seq",
            )?;
            stmt.query_map([key.0], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
        };
        payloads.iter().map(|p| self.decode_row(p, true)).collect()
    }

    pub fn mark_pushed(&mut self, key: HistoryKey, ids: &[BatchId]) -> Result<()> {
        let mut resolved = Vec::with_capacity(ids.len());
        for id in ids {
            resolved.push((self.ordinal(key, id.actor)?, id.ts as i64));
        }
        let tx = self.conn.transaction()?;
        for (actor, ts) in resolved {
            tx.execute("DELETE FROM outbox WHERE history_key = ?1 AND actor = ?2 AND end_ts = ?3", params![key.0, actor, ts])?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn put_blob(&mut self, oid: &Oid, data: &[u8]) -> Result<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO blobs (oid, len, data) VALUES (?1, ?2, ?3)",
            params![oid.0.to_vec(), data.len() as i64, compress(data)],
        )?;
        Ok(())
    }

    pub fn blob(&self, oid: &Oid) -> Result<Option<Vec<u8>>> {
        let data: Option<Vec<u8>> =
            self.conn.query_row("SELECT data FROM blobs WHERE oid = ?1", [oid.0.to_vec()], |r| r.get(0)).optional()?;
        data.map(|d| decompress(&d)).transpose()
    }

    pub fn set_status(&mut self, key: HistoryKey, status: &Status) -> Result<()> {
        let encoded = match status {
            Status::Healthy => None,
            s => Some(postcard::to_stdvec(s).map_err(CodecError::from)?),
        };
        self.conn.execute("UPDATE histories SET status = ?2 WHERE history_key = ?1", params![key.0, encoded])?;
        Ok(())
    }

    // ----- snapshots & loading ---------------------------------------------

    pub fn save_snapshot(&mut self, key: HistoryKey, history: &History) -> Result<()> {
        let version = self.encode_version(key, history.heads())?;
        let data = compress(&codec::encode_snapshot(history));
        self.conn.execute(
            "INSERT INTO snapshots (history_key, version, batch_count, data) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (history_key) DO UPDATE SET version = excluded.version, batch_count = excluded.batch_count, data = excluded.data",
            params![key.0, version, history.dag().len() as i64, data],
        )?;
        Ok(())
    }

    pub fn snapshot_batch_count(&self, key: HistoryKey) -> Result<usize> {
        let n: Option<i64> =
            self.conn.query_row("SELECT batch_count FROM snapshots WHERE history_key = ?1", [key.0], |r| r.get(0)).optional()?;
        Ok(n.unwrap_or(0) as usize)
    }

    /// Rebuilds the in-memory history: latest snapshot plus every stored
    /// batch it doesn't contain, replayed in arrival order.
    pub fn load(&mut self, id: HistoryId) -> Result<(HistoryKey, History)> {
        let key = self.history_key(id)?.ok_or(StoreError::UnknownHistory(id))?;
        let snapshot: Option<Vec<u8>> =
            self.conn.query_row("SELECT data FROM snapshots WHERE history_key = ?1", [key.0], |r| r.get(0)).optional()?;
        let mut history = match snapshot {
            Some(data) => match codec::decode_snapshot(&decompress(&data)?) {
                Ok(h) if h.id() == id => h,
                _ => History::new(id),
            },
            None => History::new(id),
        };
        let pending: Vec<(i64, i64)> = {
            let mut stmt = self.conn.prepare("SELECT actor, end_ts FROM batches WHERE history_key = ?1 ORDER BY seq")?;
            stmt.query_map([key.0], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?
        };
        for (actor, end) in pending {
            let bid = OpId::new(end as u64, self.actor_for(key, actor)?);
            if history.dag().contains_batch_id(&bid) {
                continue;
            }
            let batch = self.batch(key, &bid)?.ok_or_else(|| StoreError::Corrupt(format!("missing batch {bid:?}")))?;
            history.integrate(&batch).map_err(|e| StoreError::Corrupt(format!("replaying {bid:?}: {e}")))?;
        }
        Ok((key, history))
    }

    // ----- mounts ----------------------------------------------------------

    pub fn mount_record(&mut self, root: &str) -> Result<Option<MountRecord>> {
        let row: Option<(i64, Vec<u8>, String)> = self
            .conn
            .query_row("SELECT history_key, ingestion_actor, synced_version FROM mounts WHERE root = ?1", [root], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .optional()?;
        let Some((hk, actor, synced)) = row else { return Ok(None) };
        let key = HistoryKey(hk);
        let uuid: Vec<u8> =
            self.conn.query_row("SELECT history_uuid FROM histories WHERE history_key = ?1", [hk], |r| r.get(0))?;
        Ok(Some(MountRecord {
            root: root.to_string(),
            history: HistoryId(uuid_from(&uuid)?),
            ingestion_actor: ActorId(uuid_from(&actor)?),
            synced_version: self.decode_version(key, &synced)?,
        }))
    }

    pub fn save_mount_record(&mut self, key: HistoryKey, record: &MountRecord) -> Result<()> {
        let synced = self.encode_version(key, &record.synced_version)?;
        let now = strand_core::now_ms() as i64;
        self.conn.execute(
            "INSERT INTO mounts (root, history_key, ingestion_actor, synced_version, created_ms, updated_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?5)
             ON CONFLICT (root) DO UPDATE SET synced_version = excluded.synced_version, updated_ms = excluded.updated_ms",
            params![record.root, key.0, uuid_bytes(&record.ingestion_actor.0), synced, now],
        )?;
        Ok(())
    }

    pub fn mount_entries(&self, root: &str) -> Result<Vec<MountEntryRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT path, inode, kind, oid, mode, mtime_ns, size, ino FROM mount_entries WHERE root = ?1 ORDER BY path",
        )?;
        let rows = stmt.query_map([root], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, Option<Vec<u8>>>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, Option<i64>>(5)?,
                r.get::<_, Option<i64>>(6)?,
                r.get::<_, Option<i64>>(7)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (path, inode, kind, oid, mode, mtime_ns, size, ino) = row?;
            let inode: InodeId = postcard::from_bytes(&inode).map_err(CodecError::from)?;
            let oid = oid
                .map(|o| <[u8; 20]>::try_from(o.as_slice()).map(Oid).map_err(|_| StoreError::Corrupt("bad oid".into())))
                .transpose()?;
            out.push(MountEntryRow { path, inode, kind: kind as u8, oid, mode: mode as u8, mtime_ns, size, ino });
        }
        Ok(out)
    }

    /// Applies a batch of entry upserts and deletions atomically, together
    /// with the mount's synced version.
    pub fn update_mount(
        &mut self,
        key: HistoryKey,
        record: &MountRecord,
        upserts: &[MountEntryRow],
        removals: &[String],
    ) -> Result<()> {
        let synced = self.encode_version(key, &record.synced_version)?;
        let tx = self.conn.transaction()?;
        for path in removals {
            tx.execute("DELETE FROM mount_entries WHERE root = ?1 AND path = ?2", params![record.root, path])?;
        }
        for e in upserts {
            tx.execute(
                "INSERT INTO mount_entries (root, path, inode, kind, oid, mode, mtime_ns, size, ino)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT (root, path) DO UPDATE SET inode = excluded.inode, kind = excluded.kind, oid = excluded.oid,
                   mode = excluded.mode, mtime_ns = excluded.mtime_ns, size = excluded.size, ino = excluded.ino",
                params![
                    record.root,
                    e.path,
                    postcard::to_stdvec(&e.inode).map_err(CodecError::from)?,
                    e.kind as i64,
                    e.oid.map(|o| o.0.to_vec()),
                    e.mode as i64,
                    e.mtime_ns,
                    e.size,
                    e.ino
                ],
            )?;
        }
        tx.execute(
            "UPDATE mounts SET synced_version = ?2, updated_ms = ?3 WHERE root = ?1",
            params![record.root, synced, strand_core::now_ms() as i64],
        )?;
        tx.commit()?;
        Ok(())
    }

    // ----- local key/value (never synced) ------------------------------------

    pub fn local_get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.conn.query_row("SELECT value FROM local_kv WHERE key = ?1", [key], |r| r.get(0)).optional()?)
    }

    pub fn local_set(&self, key: &str, value: &[u8]) -> Result<()> {
        self.conn.execute(
            "INSERT INTO local_kv (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use strand_core::{FileMode, InodeId, LineEnding};

    fn write(h: &mut History, actor: ActorId, name: &str, text: &str) -> Batch {
        let (batch, r) = h
            .transact(actor, None, |t| {
                t.push(Op::CreateFile {
                    parent: InodeId::ROOT,
                    name: name.into(),
                    mode: FileMode::Regular,
                    line_ending: LineEnding::Lf,
                    content: Content::Text(text.as_bytes().to_vec()),
                })
            })
            .unwrap();
        r.unwrap();
        batch.unwrap()
    }

    #[test]
    fn persist_load_snapshot_and_outbox() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.db");
        let id = HistoryId::random();
        let actor = ActorId::random();
        let mut h = History::new(id);
        {
            let mut s = Store::open(&path).unwrap();
            let key = s.create_history(id).unwrap();
            let b1 = write(&mut h, actor, "a.txt", "one\n");
            s.append(key, &b1, Origin::Local, h.heads()).unwrap();
            s.save_snapshot(key, &h).unwrap();
            let b2 = write(&mut h, actor, "b.txt", "two\n");
            s.append(key, &b2, Origin::Local, h.heads()).unwrap();
            assert_eq!(s.unpushed(key).unwrap().len(), 2);
            s.mark_pushed(key, &[b1.id()]).unwrap();
            assert_eq!(s.unpushed(key).unwrap(), vec![b2]);
        }
        let mut s = Store::open(&path).unwrap();
        let (key, loaded) = s.load(id).unwrap();
        assert_eq!(loaded.heads(), h.heads());
        assert_eq!(loaded.walk(), h.walk());
        let v = s.encode_version(key, h.heads()).unwrap();
        assert_eq!(s.decode_version(key, &v).unwrap(), *h.heads());
        assert_eq!(s.headers(key).unwrap().len(), 2);
    }
}
