//! Pi (pi.dev) over its native JSONL RPC (`pi --mode rpc`): one persistent
//! process per session, resumed with `--session <file>` (the session file is
//! the native id). A run ends at `agent_settled`, after Pi's own retries; the
//! last assistant message's error, if any, is the turn's.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
use serde_json::{Value, json};

use crate::Error;
use crate::provider::{Capabilities, Event, EventKind, Interrupter, ModelInfo, Provider, Run, StartRequest, on_path};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Clone, Debug)]
pub struct Pi {
    program: PathBuf,
}

impl Default for Pi {
    fn default() -> Self {
        Pi { program: "pi".into() }
    }
}

impl Pi {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_program(mut self, program: impl Into<PathBuf>) -> Self {
        self.program = program.into();
        self
    }
}

impl Provider for Pi {
    fn id(&self) -> &'static str {
        "pi"
    }

    fn name(&self) -> &'static str {
        "Pi"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities { resume: true, fork_at_message: false, persistent: true }
    }

    fn available(&self) -> bool {
        on_path(&self.program)
    }

    fn start(&self, req: StartRequest) -> Result<Box<dyn Run>, Error> {
        let conn = Conn::spawn(&self.program, &req)?;
        let state = conn.request(json!({ "type": "get_state" }))?;
        let file = state["sessionFile"].as_str().unwrap_or_default().to_string();
        if let Some(model) = &req.model
            && let Some((provider, id)) = model.split_once('/')
            && state["model"]["id"] != id
        {
            conn.request(json!({ "type": "set_model", "provider": provider, "modelId": id }))?;
        }
        let first = Some(Event::new(EventKind::SessionStarted { native_id: file }));
        Ok(Box::new(PiRun { conn, first }))
    }

    fn models(&self) -> Result<Vec<ModelInfo>, Error> {
        let dir = std::env::temp_dir().join("ondb-models-pi");
        std::fs::create_dir_all(&dir)?;
        let conn = Conn::spawn(&self.program, &StartRequest { cwd: dir, ..Default::default() })?;
        let state = conn.request(json!({ "type": "get_state" }))?;
        let list = conn.request(json!({ "type": "get_available_models" }))?;
        conn.close();
        let current =
            (state["model"]["provider"].as_str().unwrap_or_default(), state["model"]["id"].as_str().unwrap_or_default());
        Ok(list["models"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|m| {
                let (provider, id) = (m["provider"].as_str()?, m["id"].as_str()?);
                Some(ModelInfo {
                    id: format!("{provider}/{id}"),
                    name: format!("{} ({provider})", m["name"].as_str().unwrap_or(id)),
                    default: (provider, id) == current,
                })
            })
            .collect())
    }
}

struct Conn {
    child: Arc<Mutex<Option<Child>>>,
    stdin: Arc<Mutex<ChildStdin>>,
    next: AtomicU64,
    pending: Arc<Mutex<HashMap<String, Sender<Value>>>>,
    events: Receiver<Event>,
}

fn write_line(stdin: &Mutex<ChildStdin>, v: &Value) -> std::io::Result<()> {
    let mut w = stdin.lock().unwrap_or_else(|p| p.into_inner());
    let mut line = serde_json::to_vec(v).unwrap_or_default();
    line.push(b'\n');
    w.write_all(&line)?;
    w.flush()
}

impl Conn {
    fn spawn(program: &PathBuf, req: &StartRequest) -> Result<Conn, Error> {
        let mut cmd = Command::new(program);
        cmd.args(["--mode", "rpc", "--no-themes"]);
        if let Some(file) = &req.resume {
            cmd.args(["--session", file]);
        }
        cmd.current_dir(&req.cwd).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        for (k, v) in &req.env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => Error::Provider(format!("{} is not installed", program.display())),
            _ => Error::Io(e),
        })?;
        let stdin = Arc::new(Mutex::new(child.stdin.take().ok_or_else(|| Error::Provider("no stdin".into()))?));
        let stdout = child.stdout.take().ok_or_else(|| Error::Provider("no stdout".into()))?;
        let (tx, rx) = unbounded();
        if let Some(stderr) = child.stderr.take() {
            let tx = tx.clone();
            thread::Builder::new().name("pi-err".into()).spawn(move || {
                for line in BufReader::new(stderr).split(b'\n').map_while(Result::ok) {
                    let ev = Event { kind: EventKind::Other { kind: "stderr".into() }, raw: Some(line), native_message: None };
                    if tx.send(ev).is_err() {
                        return;
                    }
                }
            })?;
        }
        let pending: Arc<Mutex<HashMap<String, Sender<Value>>>> = Arc::default();
        {
            let pending = pending.clone();
            thread::Builder::new().name("pi-out".into()).spawn(move || {
                let mut state = Mapper::default();
                for line in BufReader::new(stdout).split(b'\n').map_while(Result::ok) {
                    let Ok(msg) = serde_json::from_slice::<Value>(&line) else { continue };
                    if msg["type"] == "response"
                        && let Some(id) = msg["id"].as_str()
                        && let Some(reply) = pending.lock().unwrap_or_else(|p| p.into_inner()).remove(id)
                    {
                        let _ = reply.send(msg);
                        continue;
                    }
                    let evs = state.map(&msg);
                    let n = evs.len();
                    let raw = Some(line);
                    if n == 0 {
                        let kind = msg["type"].as_str().unwrap_or("event").to_string();
                        let _ = tx.send(Event { kind: EventKind::Other { kind }, raw, native_message: None });
                        continue;
                    }
                    for (i, mut ev) in evs.into_iter().enumerate() {
                        if i + 1 == n {
                            ev.raw = raw.clone();
                        }
                        let _ = tx.send(ev);
                    }
                }
            })?;
        }
        Ok(Conn { child: Arc::new(Mutex::new(Some(child))), stdin, next: AtomicU64::new(1), pending, events: rx })
    }

    fn request(&self, mut cmd: Value) -> Result<Value, Error> {
        let id = format!("ondb-{}", self.next.fetch_add(1, Ordering::SeqCst));
        cmd["id"] = json!(id);
        let what = cmd["type"].as_str().unwrap_or("command").to_string();
        let (tx, rx) = bounded(1);
        self.pending.lock().unwrap_or_else(|p| p.into_inner()).insert(id, tx);
        write_line(&self.stdin, &cmd)?;
        let r = rx.recv_timeout(REQUEST_TIMEOUT).map_err(|_| Error::Provider(format!("pi {what}: no answer")))?;
        if r["success"] == false {
            return Err(Error::Provider(format!("pi {what}: {}", r["error"].as_str().unwrap_or("failed"))));
        }
        Ok(r["data"].clone())
    }

    fn close(&self) {
        if let Some(mut c) = self.child.lock().unwrap_or_else(|p| p.into_inner()).take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// Maps Pi's events to normalized ones.
#[derive(Default)]
struct Mapper {
    /// The last assistant message's error (cleared by a good one).
    error: Option<String>,
}

impl Mapper {
    fn map(&mut self, m: &Value) -> Vec<Event> {
        match m["type"].as_str().unwrap_or_default() {
            "message_update" => {
                let e = &m["assistantMessageEvent"];
                let delta = e["delta"].as_str().unwrap_or_default().to_string();
                match e["type"].as_str() {
                    Some("text_delta") if !delta.is_empty() => vec![Event::new(EventKind::TextDelta { text: delta })],
                    Some("thinking_delta") if !delta.is_empty() => vec![Event::new(EventKind::ReasoningDelta { text: delta })],
                    _ => Vec::new(),
                }
            }
            "message_end" if m["message"]["role"] == "assistant" => {
                let msg = &m["message"];
                self.error = (msg["stopReason"] == "error")
                    .then(|| msg["errorMessage"].as_str().unwrap_or("the model call failed").to_string());
                let mut out = Vec::new();
                for part in msg["content"].as_array().into_iter().flatten() {
                    match part["type"].as_str() {
                        Some("thinking") => {
                            if let Some(t) = part["thinking"].as_str().filter(|t| !t.is_empty()) {
                                out.push(Event::new(EventKind::Reasoning { text: t.to_string() }));
                            }
                        }
                        Some("text") => {
                            if let Some(t) = part["text"].as_str().filter(|t| !t.is_empty()) {
                                out.push(Event::new(EventKind::Text { text: t.to_string() }));
                            }
                        }
                        _ => {}
                    }
                }
                let u = &msg["usage"];
                if u.is_object() {
                    out.push(Event::new(EventKind::Usage {
                        input_tokens: u["input"].as_u64().unwrap_or(0),
                        output_tokens: u["output"].as_u64().unwrap_or(0),
                        cost_usd: u["cost"]["total"].as_f64(),
                    }));
                }
                out
            }
            "tool_execution_start" => vec![Event::new(EventKind::ToolStarted {
                id: m["toolCallId"].as_str().unwrap_or_default().to_string(),
                name: m["toolName"].as_str().unwrap_or("tool").to_string(),
                input: m["args"].clone(),
            })],
            "tool_execution_end" => {
                let output: Vec<&str> =
                    m["result"]["content"].as_array().into_iter().flatten().filter_map(|c| c["text"].as_str()).collect();
                vec![Event::new(EventKind::ToolFinished {
                    id: m["toolCallId"].as_str().unwrap_or_default().to_string(),
                    output: output.join("\n"),
                    is_error: m["isError"] == true,
                    stdout: None,
                    stderr: None,
                })]
            }
            // A prompt refused before any run starts never settles.
            "response" if m["command"] == "prompt" && m["success"] == false => {
                let error = m["error"].as_str().unwrap_or("pi refused the prompt").to_string();
                vec![Event::new(EventKind::TurnEnded { ok: false, error: Some(error) })]
            }
            "agent_settled" => {
                let error = if m["aborted"] == true { Some("interrupted".to_string()) } else { self.error.take() };
                vec![Event::new(EventKind::TurnEnded { ok: error.is_none(), error })]
            }
            _ => Vec::new(),
        }
    }
}

struct PiRun {
    conn: Conn,
    first: Option<Event>,
}

impl Run for PiRun {
    fn send(&mut self, prompt: &str) -> Result<(), Error> {
        let id = format!("ondb-{}", self.conn.next.fetch_add(1, Ordering::SeqCst));
        write_line(&self.conn.stdin, &json!({ "id": id, "type": "prompt", "message": prompt }))?;
        Ok(())
    }

    fn next(&mut self) -> Option<Event> {
        if let Some(e) = self.first.take() {
            return Some(e);
        }
        self.conn.events.recv().ok()
    }

    fn interrupter(&self) -> Interrupter {
        let stdin = self.conn.stdin.clone();
        Arc::new(move || {
            let _ = write_line(&stdin, &json!({ "type": "clear_queue" }));
            let _ = write_line(&stdin, &json!({ "type": "abort" }));
        })
    }

    fn close(&mut self) {
        self.conn.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_model_call_fails_the_turn() {
        let mut m = Mapper::default();
        m.map(&json!({ "type": "message_end", "message": { "role": "assistant", "stopReason": "error", "errorMessage": "boom", "content": [] } }));
        let evs = m.map(&json!({ "type": "agent_settled" }));
        assert!(matches!(&evs[0].kind, EventKind::TurnEnded { ok: false, error: Some(e) } if e == "boom"));
        m.map(&json!({ "type": "message_end", "message": { "role": "assistant", "stopReason": "stop", "content": [{ "type": "text", "text": "hi" }] } }));
        let evs = m.map(&json!({ "type": "agent_settled" }));
        assert!(matches!(&evs[0].kind, EventKind::TurnEnded { ok: true, error: None }));
        let evs = m.map(&json!({ "type": "agent_settled", "aborted": true }));
        assert!(matches!(&evs[0].kind, EventKind::TurnEnded { ok: false, error: Some(e) } if e == "interrupted"));
    }
}
