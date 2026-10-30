//! Durable record of agent work: threads (message trees), provider sessions,
//! every raw provider event, tool calls with their output, and streamed CLI
//! output. Nothing here is held in memory beyond the current statement.

use std::path::Path;
use std::sync::Mutex;

use ondb_core::Version;
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

use crate::Error;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS threads (
    id TEXT PRIMARY KEY,
    worktree TEXT NOT NULL,
    title TEXT NOT NULL,
    leaf TEXT,
    created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    thread TEXT NOT NULL,
    parent TEXT,
    role TEXT NOT NULL,
    provider TEXT,
    model TEXT,
    text TEXT NOT NULL,
    version TEXT,
    scope TEXT,
    session TEXT,
    native TEXT,
    status TEXT NOT NULL,
    error TEXT,
    created_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_by_parent ON messages (thread, parent);
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    thread TEXT NOT NULL,
    provider TEXT NOT NULL,
    native TEXT,
    cwd TEXT NOT NULL,
    seen TEXT,
    forked_from TEXT,
    created_ms INTEGER NOT NULL,
    updated_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_by_thread ON sessions (thread, provider);
CREATE TABLE IF NOT EXISTS events (
    seq INTEGER PRIMARY KEY,
    session TEXT NOT NULL,
    message TEXT,
    ts_ms INTEGER NOT NULL,
    kind TEXT NOT NULL,
    native TEXT,
    raw BLOB
);
CREATE INDEX IF NOT EXISTS events_by_message ON events (message, seq);
CREATE TABLE IF NOT EXISTS tool_calls (
    message TEXT NOT NULL,
    id TEXT NOT NULL,
    session TEXT NOT NULL,
    name TEXT NOT NULL,
    input TEXT NOT NULL,
    output TEXT,
    stdout TEXT,
    stderr TEXT,
    is_error INTEGER,
    scope TEXT,
    started_ms INTEGER NOT NULL,
    ended_ms INTEGER,
    PRIMARY KEY (message, id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS outputs (
    seq INTEGER PRIMARY KEY,
    message TEXT NOT NULL,
    tool_call TEXT,
    stream TEXT NOT NULL,
    ts_ms INTEGER NOT NULL,
    data BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS outputs_by_tool ON outputs (message, tool_call, seq);
"#;

/// Tool output kept in the tool-call row; the full text stays in the raw
/// event.
const OUTPUT_CAP: usize = 256 << 10;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Thread {
    pub id: String,
    pub worktree: String,
    pub title: String,
    /// The message the thread currently ends at (its selected branch).
    pub leaf: Option<String>,
    pub created_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Role {
    User,
    Assistant,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Status {
    Running,
    Done,
    Failed,
    Interrupted,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub thread: String,
    pub parent: Option<String>,
    pub role: Role,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub text: String,
    /// The worktree's version: before the turn for user messages, after it
    /// for assistant messages.
    pub version: Option<Version>,
    /// Attribution scope of the turn (assistant messages).
    pub scope: Option<String>,
    /// Provider session that produced it (assistant messages).
    pub session: Option<String>,
    /// The provider's id for the last message of the turn (fork point).
    pub native: Option<String>,
    pub status: Status,
    pub error: Option<String>,
    pub created_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderSession {
    pub id: String,
    pub thread: String,
    pub provider: String,
    /// The provider's own session id, once known.
    pub native: Option<String>,
    pub cwd: String,
    /// Last message of the thread this session has seen.
    pub seen: Option<String>,
    pub forked_from: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolCall {
    pub message: String,
    pub id: String,
    pub session: String,
    pub name: String,
    pub input: String,
    pub output: Option<String>,
    pub stdout: Option<String>,
    pub stderr: Option<String>,
    pub is_error: Option<bool>,
    /// Attribution scope covering the tool's disk effects.
    pub scope: Option<String>,
    pub started_ms: u64,
    pub ended_ms: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordedEvent {
    pub seq: i64,
    pub session: String,
    pub message: Option<String>,
    pub ts_ms: u64,
    pub kind: String,
    pub native: Option<String>,
    /// The provider's wire line, verbatim.
    pub raw: Option<Vec<u8>>,
}

pub struct Store {
    conn: Mutex<Connection>,
}

fn status_str(s: Status) -> &'static str {
    match s {
        Status::Running => "running",
        Status::Done => "done",
        Status::Failed => "failed",
        Status::Interrupted => "interrupted",
    }
}

fn version_json(v: Option<&Version>) -> Option<String> {
    v.and_then(|v| serde_json::to_string(v).ok())
}

fn message_row(r: &Row<'_>) -> rusqlite::Result<Message> {
    let version: Option<String> = r.get(7)?;
    Ok(Message {
        id: r.get(0)?,
        thread: r.get(1)?,
        parent: r.get(2)?,
        role: if r.get::<_, String>(3)? == "user" { Role::User } else { Role::Assistant },
        provider: r.get(4)?,
        model: r.get(5)?,
        text: r.get(6)?,
        version: version.and_then(|v| serde_json::from_str(&v).ok()),
        scope: r.get(8)?,
        session: r.get(9)?,
        native: r.get(10)?,
        status: match r.get::<_, String>(11)?.as_str() {
            "running" => Status::Running,
            "failed" => Status::Failed,
            "interrupted" => Status::Interrupted,
            _ => Status::Done,
        },
        error: r.get(12)?,
        created_ms: r.get::<_, i64>(13)? as u64,
    })
}

const MESSAGE_COLS: &str =
    "id, thread, parent, role, provider, model, text, version, scope, session, native, status, error, created_ms";

fn session_row(r: &Row<'_>) -> rusqlite::Result<ProviderSession> {
    Ok(ProviderSession {
        id: r.get(0)?,
        thread: r.get(1)?,
        provider: r.get(2)?,
        native: r.get(3)?,
        cwd: r.get(4)?,
        seen: r.get(5)?,
        forked_from: r.get(6)?,
    })
}

fn cap(s: &str) -> String {
    if s.len() <= OUTPUT_CAP {
        return s.to_string();
    }
    let mut end = OUTPUT_CAP;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}… [{} bytes total]", &s[..end], s.len())
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Store, Error> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "cache_size", -512)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.execute_batch(SCHEMA)?;
        // A crash mid-turn leaves messages running; nothing is running now.
        conn.execute("UPDATE messages SET status = 'interrupted' WHERE status = 'running'", [])?;
        Ok(Store { conn: Mutex::new(conn) })
    }

    fn c(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn insert_thread(&self, t: &Thread) -> Result<(), Error> {
        self.c().execute(
            "INSERT INTO threads (id, worktree, title, leaf, created_ms) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![t.id, t.worktree, t.title, t.leaf, t.created_ms as i64],
        )?;
        Ok(())
    }

    pub fn thread(&self, id: &str) -> Result<Option<Thread>, Error> {
        Ok(self
            .c()
            .query_row("SELECT id, worktree, title, leaf, created_ms FROM threads WHERE id = ?1", [id], |r| {
                Ok(Thread {
                    id: r.get(0)?,
                    worktree: r.get(1)?,
                    title: r.get(2)?,
                    leaf: r.get(3)?,
                    created_ms: r.get::<_, i64>(4)? as u64,
                })
            })
            .optional()?)
    }

    pub fn threads(&self) -> Result<Vec<Thread>, Error> {
        let c = self.c();
        let mut st = c.prepare("SELECT id, worktree, title, leaf, created_ms FROM threads ORDER BY created_ms")?;
        let rows = st.query_map([], |r| {
            Ok(Thread {
                id: r.get(0)?,
                worktree: r.get(1)?,
                title: r.get(2)?,
                leaf: r.get(3)?,
                created_ms: r.get::<_, i64>(4)? as u64,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn set_leaf(&self, thread: &str, leaf: &str) -> Result<(), Error> {
        self.c().execute("UPDATE threads SET leaf = ?2 WHERE id = ?1", params![thread, leaf])?;
        Ok(())
    }

    pub fn insert_message(&self, m: &Message) -> Result<(), Error> {
        self.c().execute(
            &format!(
                "INSERT INTO messages ({MESSAGE_COLS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)"
            ),
            params![
                m.id,
                m.thread,
                m.parent,
                if m.role == Role::User { "user" } else { "assistant" },
                m.provider,
                m.model,
                m.text,
                version_json(m.version.as_ref()),
                m.scope,
                m.session,
                m.native,
                status_str(m.status),
                m.error,
                m.created_ms as i64
            ],
        )?;
        Ok(())
    }

    /// Final state of an assistant message.
    #[allow(clippy::too_many_arguments)]
    pub fn finish_message(
        &self,
        id: &str,
        text: &str,
        status: Status,
        error: Option<&str>,
        version: Option<&Version>,
        scope: Option<&str>,
        native: Option<&str>,
        session: &str,
    ) -> Result<(), Error> {
        self.c().execute(
            "UPDATE messages SET text = ?2, status = ?3, error = ?4, version = ?5, scope = ?6, native = ?7, session = ?8 WHERE id = ?1",
            params![id, text, status_str(status), error, version_json(version), scope, native, session],
        )?;
        Ok(())
    }

    pub fn message(&self, id: &str) -> Result<Option<Message>, Error> {
        Ok(self.c().query_row(&format!("SELECT {MESSAGE_COLS} FROM messages WHERE id = ?1"), [id], message_row).optional()?)
    }

    /// Messages with this parent (siblings of each other), oldest first.
    pub fn children(&self, thread: &str, parent: Option<&str>) -> Result<Vec<Message>, Error> {
        let c = self.c();
        let mut st = c.prepare(&format!(
            "SELECT {MESSAGE_COLS} FROM messages WHERE thread = ?1 AND parent IS ?2 ORDER BY created_ms, rowid"
        ))?;
        let rows = st.query_map(params![thread, parent], message_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Root-to-`leaf` path.
    pub fn path(&self, leaf: &str) -> Result<Vec<Message>, Error> {
        let mut out = Vec::new();
        let mut cur = Some(leaf.to_string());
        while let Some(id) = cur {
            let m = self.message(&id)?.ok_or_else(|| Error::Invalid(format!("missing message {id}")))?;
            cur = m.parent.clone();
            out.push(m);
        }
        out.reverse();
        Ok(out)
    }

    pub fn insert_session(&self, s: &ProviderSession, now: u64) -> Result<(), Error> {
        self.c().execute(
            "INSERT INTO sessions (id, thread, provider, native, cwd, seen, forked_from, created_ms, updated_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)",
            params![s.id, s.thread, s.provider, s.native, s.cwd, s.seen, s.forked_from, now as i64],
        )?;
        Ok(())
    }

    pub fn update_session(&self, id: &str, native: Option<&str>, seen: Option<&str>, now: u64) -> Result<(), Error> {
        self.c().execute(
            "UPDATE sessions SET native = COALESCE(?2, native), seen = COALESCE(?3, seen), updated_ms = ?4 WHERE id = ?1",
            params![id, native, seen, now as i64],
        )?;
        Ok(())
    }

    pub fn session(&self, id: &str) -> Result<Option<ProviderSession>, Error> {
        Ok(self
            .c()
            .query_row(
                "SELECT id, thread, provider, native, cwd, seen, forked_from FROM sessions WHERE id = ?1",
                [id],
                session_row,
            )
            .optional()?)
    }

    pub fn sessions(&self, thread: &str) -> Result<Vec<ProviderSession>, Error> {
        let c = self.c();
        let mut st = c.prepare(
            "SELECT id, thread, provider, native, cwd, seen, forked_from FROM sessions WHERE thread = ?1 ORDER BY created_ms",
        )?;
        let rows = st.query_map([thread], session_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn record_event(
        &self,
        session: &str,
        message: Option<&str>,
        ts: u64,
        kind: &str,
        native: Option<&str>,
        raw: Option<&[u8]>,
    ) -> Result<(), Error> {
        self.c().execute(
            "INSERT INTO events (session, message, ts_ms, kind, native, raw) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![session, message, ts as i64, kind, native, raw.map(lz4_flex::compress_prepend_size)],
        )?;
        Ok(())
    }

    /// Recorded events of a message (or of a whole session), in order.
    pub fn events(&self, message: Option<&str>, session: Option<&str>) -> Result<Vec<RecordedEvent>, Error> {
        let c = self.c();
        let mut st = c.prepare(
            "SELECT seq, session, message, ts_ms, kind, native, raw FROM events
             WHERE (?1 IS NULL OR message = ?1) AND (?2 IS NULL OR session = ?2) ORDER BY seq",
        )?;
        let rows = st.query_map(params![message, session], |r| {
            let raw: Option<Vec<u8>> = r.get(6)?;
            Ok(RecordedEvent {
                seq: r.get(0)?,
                session: r.get(1)?,
                message: r.get(2)?,
                ts_ms: r.get::<_, i64>(3)? as u64,
                kind: r.get(4)?,
                native: r.get(5)?,
                raw: raw.and_then(|b| lz4_flex::decompress_size_prepended(&b).ok()),
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn start_tool(&self, t: &ToolCall) -> Result<(), Error> {
        self.c().execute(
            "INSERT OR REPLACE INTO tool_calls (message, id, session, name, input, scope, started_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![t.message, t.id, t.session, t.name, t.input, t.scope, t.started_ms as i64],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn finish_tool(
        &self,
        message: &str,
        id: &str,
        output: &str,
        stdout: Option<&str>,
        stderr: Option<&str>,
        is_error: bool,
        scope: Option<&str>,
        ended: u64,
    ) -> Result<(), Error> {
        self.c().execute(
            "UPDATE tool_calls SET output = ?3, stdout = ?4, stderr = ?5, is_error = ?6, scope = COALESCE(?7, scope), ended_ms = ?8
             WHERE message = ?1 AND id = ?2",
            params![message, id, cap(output), stdout.map(cap), stderr.map(cap), is_error, scope, ended as i64],
        )?;
        Ok(())
    }

    pub fn tool_calls(&self, message: &str) -> Result<Vec<ToolCall>, Error> {
        let c = self.c();
        let mut st = c.prepare(
            "SELECT message, id, session, name, input, output, stdout, stderr, is_error, scope, started_ms, ended_ms
             FROM tool_calls WHERE message = ?1 ORDER BY started_ms, id",
        )?;
        let rows = st.query_map([message], |r| {
            Ok(ToolCall {
                message: r.get(0)?,
                id: r.get(1)?,
                session: r.get(2)?,
                name: r.get(3)?,
                input: r.get(4)?,
                output: r.get(5)?,
                stdout: r.get(6)?,
                stderr: r.get(7)?,
                is_error: r.get(8)?,
                scope: r.get(9)?,
                started_ms: r.get::<_, i64>(10)? as u64,
                ended_ms: r.get::<_, Option<i64>>(11)?.map(|v| v as u64),
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Appends streamed CLI output (a terminal, a long-running command).
    pub fn append_output(&self, message: &str, tool_call: Option<&str>, stream: &str, ts: u64, data: &[u8]) -> Result<(), Error> {
        self.c().execute(
            "INSERT INTO outputs (message, tool_call, stream, ts_ms, data) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![message, tool_call, stream, ts as i64, lz4_flex::compress_prepend_size(data)],
        )?;
        Ok(())
    }

    /// Streamed output of a message or one of its tool calls, concatenated
    /// per stream in order.
    pub fn output(&self, message: &str, tool_call: Option<&str>, stream: &str) -> Result<Vec<u8>, Error> {
        let c = self.c();
        let mut st = c.prepare("SELECT data FROM outputs WHERE message = ?1 AND tool_call IS ?2 AND stream = ?3 ORDER BY seq")?;
        let mut out = Vec::new();
        for chunk in st.query_map(params![message, tool_call, stream], |r| r.get::<_, Vec<u8>>(0))? {
            out.extend(lz4_flex::decompress_size_prepended(&chunk?).unwrap_or_default());
        }
        Ok(out)
    }
}
