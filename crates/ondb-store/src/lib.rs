//! SQLite persistence. Batches are the source of truth (append-only, stored
//! in arrival order, which is always topological); snapshots of the derived
//! CRDT state only speed up loading. Actor UUIDs are interned per history so
//! versions and batch keys stay small.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;

use ondb_core::codec::{self, CodecError};
use ondb_core::{
    ActorId, Batch, BatchHeader, BatchId, Blob, BlobSource, Content, Dag, Dirty, History, HistoryId, Inode, InodeId, InodeSource,
    Insertion, InsertionKey, MetaEntry, NodeSource, NodeStore, ObjectStore, Oid, Op, OpId, Status, StoreResult, StoredInode,
    Text, Version,
};
use rusqlite::{Connection, OptionalExtension, params};
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
CREATE TABLE IF NOT EXISTS nodes (
    id INTEGER PRIMARY KEY,
    refcount INTEGER NOT NULL,
    children BLOB NOT NULL,
    data BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS inodes (
    history_key INTEGER NOT NULL,
    inode BLOB NOT NULL,
    data BLOB NOT NULL,
    text_root INTEGER,
    PRIMARY KEY (history_key, inode)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS insertions (
    history_key INTEGER NOT NULL,
    insertion BLOB NOT NULL,
    data BLOB NOT NULL,
    PRIMARY KEY (history_key, insertion)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS meta (
    history_key INTEGER NOT NULL,
    key TEXT NOT NULL,
    entry BLOB NOT NULL,
    PRIMARY KEY (history_key, key)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS blobs (
    oid BLOB PRIMARY KEY,
    len INTEGER NOT NULL,
    data BLOB NOT NULL
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS retained_versions (
    history_key INTEGER NOT NULL,
    name TEXT NOT NULL,
    version TEXT NOT NULL,
    PRIMARY KEY (history_key, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS pending_pins (
    history_key INTEGER NOT NULL,
    oid BLOB NOT NULL,
    PRIMARY KEY (history_key, oid)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS external_objects (
    history_key INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    location TEXT NOT NULL,
    pin_ref TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS mounts (
    root TEXT PRIMARY KEY,
    history_key INTEGER NOT NULL,
    ingestion_actor BLOB NOT NULL,
    synced_version TEXT NOT NULL,
    git_head TEXT,
    git_reflog INTEGER,
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

const SCHEMA_VERSION: &str = "3";
/// SQLite page cache per connection, in KiB. Many stores can be open in one
/// process (one per worktree), so these stay small; the shared content cache
/// in `ondb_core::contents` is what keeps hot text in memory.
const WRITER_CACHE_KIB: i64 = -1024;
const READER_CACHE_KIB: i64 = -256;

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
    /// Git HEAD (`ref@commit`) the disk was last reconciled against.
    pub git_head: Option<String>,
    /// Length of HEAD's reflog at that point.
    pub git_reflog: Option<u64>,
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
    /// How to open more connections to the same database (blob reader).
    reopen: Reopen,
    /// Objects held outside the store (the repository's git objects): blobs
    /// found there are pinned rather than copied, and read back from there.
    external: Option<Arc<dyn ObjectStore>>,
    actors: HashMap<(i64, ActorId), i64>,
    ordinals: HashMap<(i64, i64), ActorId>,
}

fn uuid_bytes(u: &Uuid) -> Vec<u8> {
    u.as_bytes().to_vec()
}

fn uuid_from(bytes: &[u8]) -> Result<Uuid> {
    Uuid::from_slice(bytes).map_err(|e| StoreError::Corrupt(e.to_string()))
}

#[derive(Clone)]
enum Reopen {
    Path(std::path::PathBuf),
    Memory(String),
}

impl Reopen {
    fn open(&self) -> rusqlite::Result<Connection> {
        match self {
            Reopen::Path(p) => Connection::open_with_flags(p, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY),
            Reopen::Memory(uri) => Connection::open_with_flags(
                uri,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_URI,
            ),
        }
    }
}

/// Reads blobs and insertions over its own connection, so stored text can be
/// loaded on demand while the writer connection is in use.
pub struct BlobReader {
    conn: std::sync::Mutex<Connection>,
    key: HistoryKey,
    external: Option<Arc<dyn ObjectStore>>,
}

impl BlobSource for BlobReader {
    fn blob(&self, oid: &Oid) -> Option<Vec<u8>> {
        let stored = (|| {
            let conn = self.conn.lock().unwrap_or_else(|p| p.into_inner());
            let mut stmt = conn.prepare_cached("SELECT data FROM blobs WHERE oid = ?1").ok()?;
            let data: Vec<u8> = stmt.query_row([oid.0.to_vec()], |r| r.get(0)).optional().ok()??;
            decompress(&data).ok()
        })();
        stored.or_else(|| self.external.as_ref()?.read(oid))
    }

    fn insertion(&self, key: &InsertionKey) -> Option<Insertion> {
        let conn = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        let mut stmt = conn.prepare_cached("SELECT data FROM insertions WHERE history_key = ?1 AND insertion = ?2").ok()?;
        let data: Vec<u8> = stmt.query_row(params![self.key.0, enc(key).ok()?], |r| r.get(0)).optional().ok()??;
        dec(&decompress(&data).ok()?).ok()
    }

    fn serves_insertions(&self) -> bool {
        true
    }
}

/// Inodes for lazily loaded histories: rows are read by id on first use,
/// their texts lazily too.
struct StoredInodes(Arc<BlobReader>);

impl InodeSource for StoredInodes {
    fn inode(&self, id: &InodeId) -> Option<Inode> {
        let (data, root): (Vec<u8>, Option<i64>) = {
            let conn = self.0.conn.lock().unwrap_or_else(|p| p.into_inner());
            let mut stmt =
                conn.prepare_cached("SELECT data, text_root FROM inodes WHERE history_key = ?1 AND inode = ?2").ok()?;
            stmt.query_row(params![self.0.key.0, enc(id).ok()?], |r| Ok((r.get(0)?, r.get(1)?))).optional().ok()??
        };
        let stored: StoredInode = dec(&decompress(&data).ok()?).ok()?;
        let source: Arc<dyn NodeSource> = self.0.clone();
        Some(Inode::from_stored(stored, root.map(|r| Text::lazy(r as u64, source))))
    }
}

/// Text nodes for lazily loaded texts (see `Text::lazy`).
impl NodeSource for BlobReader {
    fn node(&self, id: u64) -> Option<Vec<u8>> {
        let conn = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        node_data(&conn, id).ok()
    }
}

/// Copy-on-write tree nodes inside a transaction. A node's refcount is the
/// number of parent nodes and inode rows referencing it; nodes reaching zero
/// are deleted and release their children.
struct TxNodes<'a> {
    tx: &'a rusqlite::Transaction<'a>,
}

fn pack(ids: &[u64]) -> Vec<u8> {
    ids.iter().flat_map(|i| i.to_le_bytes()).collect()
}

fn unpack(bytes: &[u8]) -> Vec<u64> {
    bytes.as_chunks::<8>().0.iter().map(|c| u64::from_le_bytes(*c)).collect()
}

impl TxNodes<'_> {
    fn retain(&self, id: u64) -> rusqlite::Result<()> {
        self.tx.execute("UPDATE nodes SET refcount = refcount + 1 WHERE id = ?1", [id as i64])?;
        Ok(())
    }

    fn release(&self, id: u64) -> rusqlite::Result<()> {
        let mut stack = vec![id];
        while let Some(id) = stack.pop() {
            self.tx.execute("UPDATE nodes SET refcount = refcount - 1 WHERE id = ?1", [id as i64])?;
            let row: Option<(i64, Vec<u8>)> = self
                .tx
                .query_row("SELECT refcount, children FROM nodes WHERE id = ?1", [id as i64], |r| Ok((r.get(0)?, r.get(1)?)))
                .optional()?;
            if let Some((rc, children)) = row
                && rc <= 0
            {
                self.tx.execute("DELETE FROM nodes WHERE id = ?1", [id as i64])?;
                stack.extend(unpack(&children));
            }
        }
        Ok(())
    }
}

impl NodeStore for TxNodes<'_> {
    fn put(&mut self, data: &[u8], children: &[u64]) -> StoreResult<u64> {
        let s = |e: rusqlite::Error| e.to_string();
        self.tx
            .execute("INSERT INTO nodes (refcount, children, data) VALUES (0, ?1, ?2)", params![pack(children), compress(data)])
            .map_err(s)?;
        let id = self.tx.last_insert_rowid() as u64;
        for c in children {
            self.retain(*c).map_err(s)?;
        }
        Ok(id)
    }

    fn get(&mut self, id: u64) -> StoreResult<Vec<u8>> {
        node_data(self.tx, id)
    }
}

fn node_data(conn: &Connection, id: u64) -> StoreResult<Vec<u8>> {
    let data: Vec<u8> =
        conn.query_row("SELECT data FROM nodes WHERE id = ?1", [id as i64], |r| r.get(0)).map_err(|e| e.to_string())?;
    decompress(&data).map_err(|e| e.to_string())
}

fn enc<T: serde::Serialize>(v: &T) -> Result<Vec<u8>> {
    Ok(postcard::to_stdvec(v).map_err(CodecError::from)?)
}

fn dec<T: serde::de::DeserializeOwned>(b: &[u8]) -> Result<T> {
    Ok(postcard::from_bytes(b).map_err(CodecError::from)?)
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
                    if let ondb_core::ImportNode::File { content: Content::Binary(b) | Content::TextBlob(b), .. } = &e.node {
                        out.push(b.oid);
                    }
                }
                None
            }
            _ => None,
        };
        if let Some(Content::Binary(b) | Content::TextBlob(b)) = content {
            out.push(b.oid);
        }
    }
    out.sort();
    out.dedup();
    out
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Store> {
        Self::init(Connection::open(path.as_ref())?, Reopen::Path(path.as_ref().to_path_buf()))
    }

    /// A private in-memory database (shared-cache, so readers can attach).
    pub fn open_in_memory() -> Result<Store> {
        let uri = format!("file:ondb-{}?mode=memory&cache=shared", Uuid::new_v4().simple());
        let reopen = Reopen::Memory(uri);
        Self::init(reopen.open()?, reopen)
    }

    /// Returns up to `pages` free pages to the filesystem (stores created
    /// with incremental auto-vacuum; a no-op otherwise).
    pub fn reclaim_space(&self, pages: u32) -> Result<()> {
        // The pragma frees pages as it is stepped; step it to completion.
        let mut stmt = self.conn.prepare(&format!("PRAGMA incremental_vacuum({pages})"))?;
        let mut rows = stmt.query([])?;
        while rows.next()?.is_some() {}
        Ok(())
    }

    /// Releases SQLite's cached pages and other freeable memory.
    pub fn shrink_memory(&self) {
        let _ = self.conn.execute_batch("PRAGMA shrink_memory");
    }

    pub fn blob_reader(&self, key: HistoryKey) -> Result<BlobReader> {
        let conn = self.reopen.open()?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.pragma_update(None, "cache_size", READER_CACHE_KIB)?;
        Ok(BlobReader { conn: std::sync::Mutex::new(conn), key, external: self.external.clone() })
    }

    /// Sets where blobs outside the store are found (see [`ObjectStore`]).
    /// Blob readers made afterwards use it too.
    pub fn set_external(&mut self, external: Option<Arc<dyn ObjectStore>>) {
        self.external = external;
    }

    fn init(conn: Connection, reopen: Reopen) -> Result<Store> {
        // Pages freed by reclaimed tree nodes and blobs are returned to the
        // filesystem (`reclaim_space`). Only takes effect before the first
        // table exists, so it applies to new stores.
        conn.pragma_update(None, "auto_vacuum", "INCREMENTAL")?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        // Every commit is on disk before append returns (NORMAL can lose the
        // latest commits on power loss), and checkpoints use a full barrier
        // (F_FULLFSYNC on macOS, where plain fsync leaves data in the
        // drive's cache).
        conn.pragma_update(None, "synchronous", "FULL")?;
        conn.pragma_update(None, "checkpoint_fullfsync", "ON")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "cache_size", WRITER_CACHE_KIB)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.execute_batch(SCHEMA)?;
        let version: Option<String> =
            conn.query_row("SELECT value FROM store_meta WHERE key = 'schema_version'", [], |r| r.get(0)).optional()?;
        match version.as_deref() {
            None => {
                conn.execute("INSERT INTO store_meta (key, value) VALUES ('schema_version', ?1)", [SCHEMA_VERSION])?;
            }
            Some(SCHEMA_VERSION) => {}
            Some("2") => {
                conn.execute_batch(
                    "ALTER TABLE mounts ADD COLUMN git_head TEXT;
                     ALTER TABLE mounts ADD COLUMN git_reflog INTEGER;
                     UPDATE store_meta SET value = '3' WHERE key = 'schema_version';",
                )?;
            }
            Some(other) => return Err(StoreError::Corrupt(format!("unsupported schema version {other}"))),
        }
        Ok(Store { conn, reopen, external: None, actors: HashMap::new(), ordinals: HashMap::new() })
    }

    // ----- histories -------------------------------------------------------

    pub fn create_history(&mut self, id: HistoryId) -> Result<HistoryKey> {
        self.conn.execute(
            "INSERT OR IGNORE INTO histories (history_uuid, created_ms) VALUES (?1, ?2)",
            params![uuid_bytes(&id.0), ondb_core::now_ms() as i64],
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

    /// Persists an integrated batch, its blobs, and every piece of derived
    /// state it changed, in one transaction: the stored state always equals
    /// replaying the stored batches, so there is nothing to recover after a
    /// crash. Local batches are also queued for upload.
    pub fn append(&mut self, key: HistoryKey, batch: &Batch, origin: Origin, history: &mut History) -> Result<()> {
        let heads = &history.heads().clone();
        let id = batch.id();
        let actor = self.ordinal(key, batch.header.actor)?;
        let parents = self.encode_version(key, &batch.header.parents)?;
        let head = self.encode_version(key, heads)?;
        for p in batch.header.parents.heads() {
            self.ordinal(key, p.actor)?;
        }
        let stripped = Batch { header: batch.header.clone(), ops: batch.ops.clone(), blobs: Vec::new() };
        let payload = compress(&codec::encode_batch(&stripped));
        // Blobs the external object store already holds are not copied. They
        // are queued, in this transaction, to be pinned there in bulk (see
        // `flush_pins`); until then git keeps them, since they came from
        // its index or a commit.
        let external: HashSet<Oid> = match &self.external {
            // Attached blobs, and references to blobs not attached at all
            // (large files git holds, never read into memory).
            Some(ext) => batch.blobs.iter().map(|b| b.oid).chain(blob_refs(batch)).filter(|o| ext.contains(o)).collect(),
            None => HashSet::new(),
        };
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
            for oid in &external {
                tx.execute(
                    "INSERT OR IGNORE INTO pending_pins (history_key, oid) VALUES (?1, ?2)",
                    params![key.0, oid.0.to_vec()],
                )?;
            }
            for blob in batch.blobs.iter().filter(|b| !external.contains(&b.oid)) {
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
        let dirty = history.take_dirty();
        write_state(&tx, key, history, &dirty)?;
        tx.commit()?;
        let blobs: Vec<Oid> = batch.blobs.iter().map(|b| b.oid).collect();
        history.persisted(&dirty.insertions, &blobs);
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
        // An empty payload was pruned (see `prune_payloads`).
        payload.filter(|p| !p.is_empty()).map(|p| self.decode_row(&p, true)).transpose()
    }

    // ----- retention and pruning -------------------------------------------

    /// Keeps `version` viewable (diffable against the present) under
    /// `name`, or forgets it with `None`. Clients pin what they may still
    /// navigate to, e.g. a thread's oldest message.
    pub fn set_retained(&mut self, key: HistoryKey, name: &str, version: Option<&Version>) -> Result<()> {
        match version {
            Some(v) => {
                let enc = self.encode_version(key, v)?;
                self.conn.execute(
                    "INSERT INTO retained_versions (history_key, name, version) VALUES (?1, ?2, ?3)
                     ON CONFLICT (history_key, name) DO UPDATE SET version = excluded.version",
                    params![key.0, name, enc],
                )?;
            }
            None => {
                self.conn.execute("DELETE FROM retained_versions WHERE history_key = ?1 AND name = ?2", params![key.0, name])?;
            }
        }
        Ok(())
    }

    /// Every version that must stay diffable: retained ones and each
    /// mount's synced version.
    pub fn retained_versions(&mut self, key: HistoryKey) -> Result<Vec<Version>> {
        let encoded: Vec<String> = {
            let mut stmt = self.conn.prepare(
                "SELECT version FROM retained_versions WHERE history_key = ?1
                 UNION ALL SELECT synced_version FROM mounts WHERE history_key = ?1",
            )?;
            stmt.query_map([key.0], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
        };
        encoded.iter().map(|e| self.decode_version(key, e)).collect()
    }

    /// Whether this history has ever uploaded a batch (`mark_pushed`).
    pub fn ever_synced(&self, key: HistoryKey) -> Result<bool> {
        Ok(self.local_get(&format!("synced:{}", key.0))?.is_some())
    }

    /// Drops the ops of `ids`, keeping their headers (the DAG, dedup and
    /// ordering stay intact). Once the history has synced, batches not yet
    /// uploaded are kept; a history that never synced prunes them too, and
    /// can then no longer start syncing (`unpushed` refuses). Returns how
    /// many were pruned. Their summaries, and diffs that include them, are
    /// no longer available.
    pub fn prune_payloads(&mut self, key: HistoryKey, ids: &[BatchId]) -> Result<usize> {
        let keep_unuploaded = self.ever_synced(key)?;
        let mut ords = Vec::with_capacity(ids.len());
        for id in ids {
            ords.push((self.ordinal(key, id.actor)?, id.ts as i64));
        }
        let tx = self.conn.transaction()?;
        let mut n = 0;
        {
            let mut stmt = tx.prepare(
                "UPDATE batches SET payload = X'' WHERE history_key = ?1 AND actor = ?2 AND end_ts = ?3 AND length(payload) > 0
                   AND NOT (?4 AND EXISTS (SELECT 1 FROM outbox o WHERE o.history_key = ?1 AND o.actor = ?2 AND o.end_ts = ?3))",
            )?;
            for (actor, ts) in ords {
                n += stmt.execute(params![key.0, actor, ts, keep_unuploaded])?;
            }
        }
        tx.commit()?;
        Ok(n)
    }

    /// All batches in arrival (topological) order.
    pub fn all_batches(&mut self, key: HistoryKey, with_blobs: bool) -> Result<Vec<Batch>> {
        let payloads: Vec<Vec<u8>> = {
            let mut stmt =
                self.conn.prepare("SELECT payload FROM batches WHERE history_key = ?1 AND length(payload) > 0 ORDER BY seq")?;
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
        if payloads.iter().any(|p| p.is_empty()) {
            return Err(StoreError::Corrupt(
                "this history was pruned before it ever synced; its oldest batches can't be uploaded".into(),
            ));
        }
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
        tx.execute(
            "INSERT INTO local_kv (key, value) VALUES (?1, X'01') ON CONFLICT (key) DO NOTHING",
            [format!("synced:{}", key.0)],
        )?;
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
        match data {
            Some(d) => Ok(Some(decompress(&d)?)),
            None => Ok(self.external.as_ref().and_then(|e| e.read(oid))),
        }
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

    /// Rebuilds the in-memory history from stored state (no replay).
    pub fn load(&mut self, id: HistoryId) -> Result<(HistoryKey, History)> {
        let key = self.history_key(id)?.ok_or(StoreError::UnknownHistory(id))?;
        let mut dag = Dag::new();
        for h in self.headers(key)? {
            dag.insert(h).map_err(|e| StoreError::Corrupt(e.to_string()))?;
        }
        // Inodes (and their texts) load on first use, so memory follows the
        // files actually touched, not the tree's size. Only each inode's id
        // and the directories it was placed under are read now.
        let reader = Arc::new(self.blob_reader(key)?);
        let mut inodes = Vec::new();
        {
            let mut stmt = self.conn.prepare("SELECT data FROM inodes WHERE history_key = ?1")?;
            let mut rows = stmt.query([key.0])?;
            while let Some(row) = rows.next()? {
                let data: Vec<u8> = row.get(0)?;
                let stored: StoredInode = dec(&decompress(&data)?)?;
                let parents: Vec<InodeId> = stored.placement.history().iter().map(|(_, p)| p.parent).collect();
                inodes.push((stored.id, parents));
            }
        }
        let mut meta = BTreeMap::new();
        {
            let mut stmt = self.conn.prepare("SELECT key, entry FROM meta WHERE history_key = ?1")?;
            let rows = stmt.query_map([key.0], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?)))?;
            for row in rows {
                let (k, v) = row?;
                meta.insert(k, dec::<MetaEntry>(&v)?);
            }
        }
        let status: Option<Vec<u8>> =
            self.conn.query_row("SELECT status FROM histories WHERE history_key = ?1", [key.0], |r| r.get(0))?;
        let status = status.map(|s| dec(&s)).transpose()?.unwrap_or(Status::Healthy);
        let mut history = History::from_stored(id, dag, inodes, Arc::new(StoredInodes(reader.clone())), meta, status);
        // Insertions stay in the store; the blob reader serves them on demand.
        history.set_blob_source(reader);
        Ok((key, history))
    }

    /// Blobs whose bytes are in the store (not held externally).
    pub fn stored_blob_count(&self) -> Result<u64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM blobs", [], |r| r.get::<_, i64>(0))? as u64)
    }

    /// Number of stored tree nodes (diagnostics, tests).
    pub fn node_count(&self) -> Result<u64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM nodes", [], |r| r.get::<_, i64>(0))? as u64)
    }

    // ----- external objects ------------------------------------------------

    /// Pins queued blobs in the external store. Any it can't pin are copied
    /// into the store instead, so content is never left unprotected.
    /// Returns how many were handled.
    pub fn flush_pins(&mut self, key: HistoryKey) -> Result<usize> {
        let Some(ext) = self.external.clone() else { return Ok(0) };
        let mut done = 0;
        loop {
            let oids: Vec<Oid> = {
                let mut stmt = self.conn.prepare_cached("SELECT oid FROM pending_pins WHERE history_key = ?1 LIMIT 50000")?;
                let rows = stmt.query_map([key.0], |r| r.get::<_, Vec<u8>>(0))?;
                rows.filter_map(|r| r.ok()).filter_map(|b| <[u8; 20]>::try_from(b.as_slice()).ok()).map(Oid).collect()
            };
            if oids.is_empty() {
                return Ok(done);
            }
            let pinned = ext.pin(&oids);
            let tx = self.conn.transaction()?;
            for oid in &oids {
                if !pinned {
                    let data = ext.read(oid).ok_or_else(|| {
                        StoreError::Corrupt(format!("blob {} is neither pinned nor readable from the repository", oid.hex()))
                    })?;
                    tx.execute(
                        "INSERT OR IGNORE INTO blobs (oid, len, data) VALUES (?1, ?2, ?3)",
                        params![oid.0.to_vec(), data.len() as i64, compress(&data)],
                    )?;
                }
                tx.execute("DELETE FROM pending_pins WHERE history_key = ?1 AND oid = ?2", params![key.0, oid.0.to_vec()])?;
            }
            tx.commit()?;
            done += oids.len();
        }
    }

    /// Where this history's externally held content lives: `(kind,
    /// location, pin_ref)`, e.g. `("git", <common git dir>, "refs/0ndb/<id>")`.
    pub fn external_record(&self, key: HistoryKey) -> Result<Option<(String, String, String)>> {
        Ok(self
            .conn
            .query_row("SELECT kind, location, pin_ref FROM external_objects WHERE history_key = ?1", [key.0], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .optional()?)
    }

    pub fn set_external_record(&mut self, key: HistoryKey, kind: &str, location: &str, pin_ref: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO external_objects (history_key, kind, location, pin_ref) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (history_key) DO UPDATE SET kind = excluded.kind, location = excluded.location, pin_ref = excluded.pin_ref",
            params![key.0, kind, location, pin_ref],
        )?;
        Ok(())
    }

    // ----- mounts ----------------------------------------------------------

    pub fn mount_record(&mut self, root: &str) -> Result<Option<MountRecord>> {
        type Row = (i64, Vec<u8>, String, Option<String>, Option<i64>);
        let row: Option<Row> = self
            .conn
            .query_row(
                "SELECT history_key, ingestion_actor, synced_version, git_head, git_reflog FROM mounts WHERE root = ?1",
                [root],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .optional()?;
        let Some((hk, actor, synced, git_head, git_reflog)) = row else { return Ok(None) };
        let key = HistoryKey(hk);
        let uuid: Vec<u8> =
            self.conn.query_row("SELECT history_uuid FROM histories WHERE history_key = ?1", [hk], |r| r.get(0))?;
        Ok(Some(MountRecord {
            root: root.to_string(),
            history: HistoryId(uuid_from(&uuid)?),
            ingestion_actor: ActorId(uuid_from(&actor)?),
            synced_version: self.decode_version(key, &synced)?,
            git_head,
            git_reflog: git_reflog.map(|n| n as u64),
        }))
    }

    pub fn save_mount_record(&mut self, key: HistoryKey, record: &MountRecord) -> Result<()> {
        let synced = self.encode_version(key, &record.synced_version)?;
        let now = ondb_core::now_ms() as i64;
        self.conn.execute(
            "INSERT INTO mounts (root, history_key, ingestion_actor, synced_version, git_head, git_reflog, created_ms, updated_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
             ON CONFLICT (root) DO UPDATE SET synced_version = excluded.synced_version, git_head = excluded.git_head,
               git_reflog = excluded.git_reflog, updated_ms = excluded.updated_ms",
            params![
                record.root,
                key.0,
                uuid_bytes(&record.ingestion_actor.0),
                synced,
                record.git_head,
                record.git_reflog.map(|n| n as i64),
                now
            ],
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
            "UPDATE mounts SET synced_version = ?2, git_head = ?3, git_reflog = ?4, updated_ms = ?5 WHERE root = ?1",
            params![record.root, synced, record.git_head, record.git_reflog.map(|n| n as i64), ondb_core::now_ms() as i64],
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

/// Writes the derived state a batch changed. Text trees write only nodes
/// created since they were last persisted; replaced roots are released.
fn write_state(tx: &rusqlite::Transaction<'_>, key: HistoryKey, history: &History, dirty: &Dirty) -> Result<()> {
    let mut nodes = TxNodes { tx };
    for id in &dirty.inodes {
        let Some(inode) = history.inode(id) else { continue };
        let (stored, text) = inode.to_stored();
        let new_root = text.map(|t| t.persist(&mut nodes)).transpose().map_err(StoreError::Corrupt)?;
        let ikey = enc(id)?;
        let old_root: Option<Option<i64>> = tx
            .query_row("SELECT text_root FROM inodes WHERE history_key = ?1 AND inode = ?2", params![key.0, ikey], |r| r.get(0))
            .optional()?;
        tx.execute(
            "INSERT INTO inodes (history_key, inode, data, text_root) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (history_key, inode) DO UPDATE SET data = excluded.data, text_root = excluded.text_root",
            params![key.0, ikey, compress(&enc(&stored)?), new_root.map(|r| r as i64)],
        )?;
        let old_root = old_root.flatten().map(|r| r as u64);
        if old_root != new_root {
            if let Some(r) = new_root {
                nodes.retain(r)?;
            }
            if let Some(r) = old_root {
                nodes.release(r)?;
            }
        }
    }
    for k in &dirty.meta {
        match history.meta_entry(k) {
            Some(entry) => tx.execute(
                "INSERT INTO meta (history_key, key, entry) VALUES (?1, ?2, ?3)
                 ON CONFLICT (history_key, key) DO UPDATE SET entry = excluded.entry",
                params![key.0, k, enc(entry)?],
            )?,
            None => tx.execute("DELETE FROM meta WHERE history_key = ?1 AND key = ?2", params![key.0, k])?,
        };
    }
    for k in &dirty.insertions {
        if let Some(ins) = history.contents().get(k) {
            tx.execute(
                "INSERT OR REPLACE INTO insertions (history_key, insertion, data) VALUES (?1, ?2, ?3)",
                params![key.0, enc(k)?, compress(&enc(ins)?)],
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ondb_core::{FileMode, InodeId, LineEnding};

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
    fn state_is_durable_after_every_batch_and_outbox_works() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.db");
        let id = HistoryId::random();
        let actor = ActorId::random();
        let mut h = History::new(id);
        {
            let mut s = Store::open(&path).unwrap();
            let key = s.create_history(id).unwrap();
            let b1 = write(&mut h, actor, "a.txt", "one\n");
            s.append(key, &b1, Origin::Local, &mut h).unwrap();
            let b2 = write(&mut h, actor, "b.txt", "two\n");
            s.append(key, &b2, Origin::Local, &mut h).unwrap();
            assert_eq!(s.unpushed(key).unwrap().len(), 2);
            s.mark_pushed(key, &[b1.id()]).unwrap();
            assert_eq!(s.unpushed(key).unwrap(), vec![b2]);
            // Dropped without any snapshot or shutdown step.
        }
        let mut s = Store::open(&path).unwrap();
        let (key, loaded) = s.load(id).unwrap();
        assert_eq!(loaded.heads(), h.heads());
        assert_eq!(loaded.walk(), h.walk());
        let v = s.encode_version(key, h.heads()).unwrap();
        assert_eq!(s.decode_version(key, &v).unwrap(), *h.heads());
        assert_eq!(s.headers(key).unwrap().len(), 2);
    }

    /// Editing a large file writes O(log n) nodes per batch and releases the
    /// nodes the edit replaced, so storage tracks the live tree size.
    #[test]
    fn large_file_edits_are_incremental_and_reclaimed() {
        let dir = tempfile::tempdir().unwrap();
        let id = HistoryId::random();
        let actor = ActorId::random();
        let mut h = History::new(id);
        let mut s = Store::open(dir.path().join("s.db")).unwrap();
        let key = s.create_history(id).unwrap();
        let body: Vec<u8> = (0..50_000).flat_map(|i| format!("line {i}\n").into_bytes()).collect();
        let (content, blob) = Content::text(body.clone());
        let (b, r) = h
            .transact(actor, None, |t| {
                t.attach_blob(blob.clone().unwrap());
                t.push(Op::CreateFile {
                    parent: InodeId::ROOT,
                    name: "big".into(),
                    mode: FileMode::Regular,
                    line_ending: LineEnding::Lf,
                    content,
                })
            })
            .unwrap();
        r.unwrap();
        let b = b.unwrap();
        s.append(key, &b, Origin::Local, &mut h).unwrap();
        let inode = InodeId::new(b.header.op_id(0), 0);
        let mut expected = body;
        for i in 0..2000u64 {
            let at = (i * 7919) % expected.len() as u64;
            let (b, r) = h
                .transact(actor, None, |t| {
                    t.push(Op::EditText { inode, text: b"x".to_vec(), splices: vec![ondb_core::Splice { at, del: 1, ins: 1 }] })
                })
                .unwrap();
            r.unwrap();
            expected[at as usize] = b'x';
            s.append(key, &b.unwrap(), Origin::Local, &mut h).unwrap();
        }
        let frags = h.inode(&inode).unwrap().file().unwrap().text.fragments_len() as u64;
        let nodes = s.node_count().unwrap();
        assert!(nodes <= frags / 8 + 16, "{nodes} stored nodes for {frags} fragments: old paths not reclaimed");
        let (_, loaded) = s.load(id).unwrap();
        assert_eq!(loaded.text(&inode).unwrap(), expected, "blob-backed base text is read lazily after reload");
    }

    /// An external object store whose pinning can be made to fail.
    struct FakeObjects {
        blobs: std::sync::Mutex<HashMap<Oid, Vec<u8>>>,
        pins: std::sync::Mutex<Vec<Oid>>,
        pin_ok: bool,
    }

    impl ObjectStore for FakeObjects {
        fn contains(&self, oid: &Oid) -> bool {
            self.blobs.lock().unwrap().contains_key(oid)
        }
        fn read(&self, oid: &Oid) -> Option<Vec<u8>> {
            self.blobs.lock().unwrap().get(oid).cloned()
        }
        fn pin(&self, oids: &[Oid]) -> bool {
            self.pins.lock().unwrap().extend_from_slice(oids);
            self.pin_ok
        }
    }

    #[test]
    fn externally_held_blobs_are_referenced_pinned_or_copied_in() {
        for pin_ok in [true, false] {
            let dir = tempfile::tempdir().unwrap();
            let id = HistoryId::random();
            let actor = ActorId::random();
            let body: Vec<u8> = (0..2_000).flat_map(|i| format!("line {i}\n").into_bytes()).collect();
            let (content, blob) = Content::text(body.clone());
            let blob = blob.unwrap();
            let ext = Arc::new(FakeObjects {
                blobs: std::sync::Mutex::new(HashMap::from([(blob.oid, body.clone())])),
                pins: Default::default(),
                pin_ok,
            });
            let mut s = Store::open(dir.path().join("s.db")).unwrap();
            s.set_external(Some(ext.clone()));
            let key = s.create_history(id).unwrap();
            let mut h = History::new(id);
            let (b, r) = h
                .transact(actor, None, |t| {
                    t.attach_blob(blob.clone());
                    t.push(Op::CreateFile {
                        parent: InodeId::ROOT,
                        name: "big".into(),
                        mode: FileMode::Regular,
                        line_ending: LineEnding::Lf,
                        content,
                    })
                })
                .unwrap();
            r.unwrap();
            let b = b.unwrap();
            s.append(key, &b, Origin::Local, &mut h).unwrap();
            let inode = InodeId::new(b.header.op_id(0), 0);
            assert_eq!(s.stored_blob_count().unwrap(), 0, "held externally: not copied");
            assert!(ext.pins.lock().unwrap().is_empty(), "pins are flushed in bulk, not per batch");
            assert_eq!(s.flush_pins(key).unwrap(), 1);
            assert_eq!(*ext.pins.lock().unwrap(), vec![blob.oid]);
            assert_eq!(s.flush_pins(key).unwrap(), 0, "nothing left queued");
            assert_eq!(s.stored_blob_count().unwrap(), if pin_ok { 0 } else { 1 }, "an unpinnable blob is copied in");
            // Readable after reload, through the external store or the copy.
            let (_, loaded) = s.load(id).unwrap();
            assert_eq!(loaded.text(&inode).unwrap(), body);
            assert_eq!(s.blob(&blob.oid).unwrap().unwrap(), body);
            // Unpinned content survives losing the external copy only when it
            // was copied in.
            ext.blobs.lock().unwrap().clear();
            assert_eq!(s.blob(&blob.oid).unwrap().is_some(), !pin_ok);
        }
    }

    #[test]
    fn new_stores_give_freed_space_back() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.db");
        let s = Store::open(&path).unwrap();
        let mode: i64 = s.conn.query_row("PRAGMA auto_vacuum", [], |r| r.get(0)).unwrap();
        assert_eq!(mode, 2, "incremental auto-vacuum");
        let sync: i64 = s.conn.query_row("PRAGMA synchronous", [], |r| r.get(0)).unwrap();
        assert_eq!(sync, 2, "every commit durable");
        s.conn
            .execute_batch("CREATE TABLE junk (b BLOB); INSERT INTO junk SELECT randomblob(4096) FROM generate_series(1, 2000);")
            .ok();
        if s.conn.query_row("SELECT COUNT(*) FROM junk", [], |r| r.get::<_, i64>(0)).unwrap_or(0) == 0 {
            // No generate_series in this SQLite build: insert directly.
            for _ in 0..2000 {
                s.conn.execute("INSERT INTO junk VALUES (randomblob(4096))", []).unwrap();
            }
        }
        s.conn.execute_batch("DELETE FROM junk").unwrap();
        let free = |s: &Store| s.conn.query_row("PRAGMA freelist_count", [], |r| r.get::<_, i64>(0)).unwrap();
        assert!(free(&s) > 1000);
        s.reclaim_space(100_000).unwrap();
        assert_eq!(free(&s), 0);
    }

    #[test]
    fn inodes_load_on_use_and_unload_once_persisted() {
        let dir = tempfile::tempdir().unwrap();
        let id = HistoryId::random();
        let actor = ActorId::random();
        let mut s = Store::open(dir.path().join("s.db")).unwrap();
        let key = s.create_history(id).unwrap();
        let mut h = History::new(id);
        let mut files = Vec::new();
        for i in 0..50 {
            let b = write(&mut h, actor, &format!("f{i}"), &format!("file {i}\n"));
            files.push(InodeId::new(b.header.op_id(0), 0));
            s.append(key, &b, Origin::Local, &mut h).unwrap();
        }
        let (_, mut loaded) = s.load(id).unwrap();
        assert_eq!(loaded.tree().loaded_count(), 1, "only the root is resident after loading");
        assert_eq!(loaded.text(&files[7]).unwrap(), b"file 7\n");
        assert_eq!(loaded.lookup("f9"), Some(files[9]));
        assert!(loaded.tree().loaded_count() > 1);
        // Edit an inode that was never loaded, persist, then drop everything.
        let (b, r) = loaded
            .transact(actor, None, |t| {
                t.push(Op::EditText {
                    inode: files[3],
                    text: b"FILE".to_vec(),
                    splices: vec![ondb_core::Splice { at: 0, del: 4, ins: 4 }],
                })
            })
            .unwrap();
        r.unwrap();
        s.append(key, &b.unwrap(), Origin::Local, &mut loaded).unwrap();
        loaded.trim(0);
        assert_eq!(loaded.tree().loaded_count(), 1);
        assert_eq!(loaded.text(&files[3]).unwrap(), b"FILE 3\n", "unloaded edits read back from the store");
        assert_eq!(loaded.walk().len(), 50);
        let (_, again) = s.load(id).unwrap();
        assert_eq!(again.text(&files[3]).unwrap(), b"FILE 3\n");
    }
}
