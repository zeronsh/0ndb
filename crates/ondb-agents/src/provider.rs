//! Agent providers (Claude Code, Codex, ...) behind one interface, and the
//! normalized events every provider's wire format is mapped to.

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::Error;

/// What a provider can do natively. Anything missing is emulated by the
/// session manager (replaying history into a fresh session).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    /// Continue a native session by id.
    pub resume: bool,
    /// Start a new native session branched from an existing one at a given
    /// native message.
    pub fork_at_message: bool,
    /// A live process accepts further prompts (no respawn between turns).
    pub persistent: bool,
}

/// How to start a provider process.
#[derive(Clone, Debug, Default)]
pub struct StartRequest {
    pub cwd: PathBuf,
    pub model: Option<String>,
    /// Native session to continue.
    pub resume: Option<String>,
    /// With `resume`: branch a new native session off it, ending at this
    /// native message (needs [`Capabilities::fork_at_message`]).
    pub fork_at: Option<String>,
    pub env: Vec<(String, String)>,
}

/// Stops the current turn from any thread.
pub type Interrupter = Arc<dyn Fn() + Send + Sync>;

/// A running provider process.
pub trait Run: Send {
    /// Sends a user prompt (starting a turn).
    fn send(&mut self, prompt: &str) -> Result<(), Error>;
    /// Blocks for the next event; `None` once the process has exited.
    fn next(&mut self) -> Option<Event>;
    /// A handle that stops the current turn (and, for providers that can't
    /// stop a turn in place, the process) from another thread.
    fn interrupter(&self) -> Interrupter;
    /// Ends the process and reaps it.
    fn close(&mut self);
}

pub trait Provider: Send + Sync {
    /// Stable id (`"claude-code"`, `"codex"`, ...).
    fn id(&self) -> &'static str;
    /// Human-readable name (`"Claude Code"`).
    fn name(&self) -> &'static str {
        self.id()
    }
    fn capabilities(&self) -> Capabilities;
    fn start(&self, req: StartRequest) -> Result<Box<dyn Run>, Error>;
    /// Whether the provider's CLI is installed.
    fn available(&self) -> bool {
        true
    }
    /// The models this provider offers the signed-in account, asked of the
    /// provider itself where it can say (may spawn it; callers cache).
    /// Empty means "only the provider's default".
    fn models(&self) -> Result<Vec<ModelInfo>, Error> {
        Ok(Vec::new())
    }
}

/// One selectable model.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelInfo {
    /// What to pass as `StartRequest::model`.
    pub id: String,
    pub name: String,
    /// The provider's own default.
    pub default: bool,
}

/// Whether `program` resolves on PATH (or is a path that exists).
pub fn on_path(program: &std::path::Path) -> bool {
    if program.components().count() > 1 {
        return program.exists();
    }
    std::env::var_os("PATH").is_some_and(|paths| std::env::split_paths(&paths).any(|d| d.join(program).is_file()))
}

/// One event from a provider: its normalized meaning plus the provider's
/// own JSON, kept verbatim for the record.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub kind: EventKind,
    /// The raw wire line (JSON), if the provider has one.
    pub raw: Option<Vec<u8>>,
    /// The provider's id for the message this event belongs to (what
    /// native forks are addressed by).
    pub native_message: Option<String>,
}

impl Event {
    pub fn new(kind: EventKind) -> Self {
        Event { kind, raw: None, native_message: None }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum EventKind {
    /// The native session id is known (first event of a process).
    SessionStarted {
        native_id: String,
    },
    /// A complete text block of the reply.
    Text {
        text: String,
    },
    /// Streamed text ahead of the complete block (the block is authoritative).
    TextDelta {
        text: String,
    },
    Reasoning {
        text: String,
    },
    ReasoningDelta {
        text: String,
    },
    ToolStarted {
        id: String,
        name: String,
        input: serde_json::Value,
    },
    ToolFinished {
        id: String,
        output: String,
        is_error: bool,
        stdout: Option<String>,
        stderr: Option<String>,
    },
    Usage {
        input_tokens: u64,
        output_tokens: u64,
        cost_usd: Option<f64>,
    },
    /// The turn is over; the process may stay up for the next one.
    TurnEnded {
        ok: bool,
        error: Option<String>,
    },
    /// Anything else the provider said (recorded, not interpreted).
    Other {
        kind: String,
    },
}

impl EventKind {
    pub fn name(&self) -> &str {
        match self {
            EventKind::SessionStarted { .. } => "session_started",
            EventKind::Text { .. } => "text",
            EventKind::TextDelta { .. } => "text_delta",
            EventKind::Reasoning { .. } => "reasoning",
            EventKind::ReasoningDelta { .. } => "reasoning_delta",
            EventKind::ToolStarted { .. } => "tool_started",
            EventKind::ToolFinished { .. } => "tool_finished",
            EventKind::Usage { .. } => "usage",
            EventKind::TurnEnded { .. } => "turn_ended",
            EventKind::Other { kind } => kind,
        }
    }
}
