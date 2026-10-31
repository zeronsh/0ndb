//! Agents spoken to over the Agent Client Protocol (JSON-RPC over stdio):
//! Devin (`devin acp`), Grok (`grok agent stdio`), Hermes (`hermes acp`),
//! Antigravity (`agy_acp_server`), Cursor (`cursor-agent acp`) and opencode
//! (`opencode acp`). One persistent process per session; resumed with
//! `session/resume` or `session/load`; models chosen through the session's
//! `configOptions` (category `model`) or its `models` list, whichever the
//! agent offers. Permission requests are answered from [`Access`].

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
use serde_json::{Value, json};

use crate::Error;
use crate::claude::Access;
use crate::provider::{Capabilities, Event, EventKind, Interrupter, ModelInfo, Provider, Run, StartRequest, on_path};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

/// One ACP agent.
#[derive(Clone, Debug)]
pub struct Acp {
    id: &'static str,
    name: &'static str,
    program: PathBuf,
    args: Vec<String>,
    access: Access,
}

impl Acp {
    pub fn new(id: &'static str, name: &'static str, program: &str, args: &[&str], access: Access) -> Self {
        Acp { id, name, program: program.into(), args: args.iter().map(|a| a.to_string()).collect(), access }
    }

    pub fn devin(access: Access) -> Self {
        Self::new("devin", "Devin", "devin", &["acp"], access)
    }

    pub fn grok(access: Access) -> Self {
        Self::new("grok", "Grok", "grok", &["agent", "stdio"], access)
    }

    pub fn hermes(access: Access) -> Self {
        Self::new("hermes", "Hermes", "hermes", &["acp"], access)
    }

    pub fn antigravity(access: Access) -> Self {
        Self::new("antigravity", "Antigravity", "agy_acp_server", &[], access)
    }

    pub fn cursor(access: Access) -> Self {
        Self::new("cursor", "Cursor", "cursor-agent", &["acp"], access)
    }

    pub fn opencode(access: Access) -> Self {
        Self::new("opencode", "opencode", "opencode", &["acp"], access)
    }

    pub fn with_program(mut self, program: impl Into<PathBuf>) -> Self {
        self.program = program.into();
        self
    }

    fn connect(&self, cwd: &std::path::Path, env: &[(String, String)]) -> Result<Conn, Error> {
        Conn::spawn(&self.program, &self.args, cwd, env, self.access)
    }
}

impl Provider for Acp {
    fn id(&self) -> &'static str {
        self.id
    }

    fn name(&self) -> &'static str {
        self.name
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities { resume: true, fork_at_message: false, persistent: true }
    }

    fn available(&self) -> bool {
        on_path(&self.program)
    }

    fn start(&self, req: StartRequest) -> Result<Box<dyn Run>, Error> {
        let conn = self.connect(&req.cwd, &req.env)?;
        let session = conn.open_session(&req)?;
        let id = session.lock().unwrap_or_else(|p| p.into_inner()).clone().unwrap_or_default();
        let first = Some(Event::new(EventKind::SessionStarted { native_id: id }));
        Ok(Box::new(AcpRun { conn, session, first }))
    }

    fn models(&self) -> Result<Vec<ModelInfo>, Error> {
        // A throwaway session in a scratch directory, deleted afterwards
        // where the agent supports it (some persist sessions on creation).
        let dir = std::env::temp_dir().join(format!("ondb-models-{}", self.id));
        std::fs::create_dir_all(&dir)?;
        let conn = self.connect(&dir, &[])?;
        let created = conn.request("session/new", json!({ "cwd": dir, "mcpServers": [] }))?;
        let models = model_options(&created).map(|(_, m)| m).unwrap_or_default();
        if let Some(id) = created["sessionId"].as_str()
            && conn.caps["sessionCapabilities"].get("delete").is_some()
        {
            let _ = conn.request("session/delete", json!({ "sessionId": id }));
        }
        conn.close();
        Ok(models)
    }
}

/// How the agent lets a client pick a model.
#[derive(Clone, Debug)]
enum ModelControl {
    /// `session/set_config_option` with this config id.
    Config(String),
    /// `session/set_model`.
    SetModel,
}

/// The models a `session/new` (or load) response offers, and how to pick one.
fn model_options(session: &Value) -> Option<(ModelControl, Vec<ModelInfo>)> {
    if let Some(opt) = session["configOptions"].as_array()?.iter().find(|o| o["category"] == "model" || o["id"] == "model") {
        let current = opt["currentValue"].as_str().unwrap_or_default();
        let models = opt["options"]
            .as_array()
            .map(|os| {
                os.iter()
                    .filter_map(|o| {
                        let id = o["value"].as_str()?.to_string();
                        Some(ModelInfo { name: o["name"].as_str().unwrap_or(&id).to_string(), default: id == current, id })
                    })
                    .collect()
            })
            .unwrap_or_default();
        return Some((ModelControl::Config(opt["id"].as_str().unwrap_or("model").to_string()), models));
    }
    None
}

fn listed_models(session: &Value) -> Option<(ModelControl, Vec<ModelInfo>)> {
    model_options(session).or_else(|| {
        let m = &session["models"];
        let current = m["currentModelId"].as_str().unwrap_or_default();
        let models: Vec<ModelInfo> = m["availableModels"]
            .as_array()?
            .iter()
            .filter_map(|o| {
                let id = o["modelId"].as_str()?.to_string();
                Some(ModelInfo { name: o["name"].as_str().unwrap_or(&id).to_string(), default: id == current, id })
            })
            .collect();
        Some((ModelControl::SetModel, models))
    })
}

enum Waiter {
    Reply(Sender<Result<Value, String>>),
    /// The pending `session/prompt`: its response ends the turn.
    Turn,
}

/// A connection to one agent process.
struct Conn {
    child: Arc<Mutex<Option<Child>>>,
    stdin: Arc<Mutex<ChildStdin>>,
    next: AtomicU64,
    pending: Arc<Mutex<HashMap<u64, Waiter>>>,
    events: Receiver<Event>,
    /// Session updates are dropped while set (history replayed by a load).
    quiet: Arc<AtomicBool>,
    caps: Value,
}

fn write_line(stdin: &Mutex<ChildStdin>, v: &Value) -> std::io::Result<()> {
    let mut w = stdin.lock().unwrap_or_else(|p| p.into_inner());
    let mut line = serde_json::to_vec(v).unwrap_or_default();
    line.push(b'\n');
    w.write_all(&line)?;
    w.flush()
}

impl Conn {
    fn spawn(
        program: &PathBuf,
        args: &[String],
        cwd: &std::path::Path,
        env: &[(String, String)],
        access: Access,
    ) -> Result<Conn, Error> {
        let mut cmd = Command::new(program);
        cmd.args(args).current_dir(cwd).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        for (k, v) in env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => Error::Provider(format!("{} is not installed", program.display())),
            _ => Error::Io(e),
        })?;
        let stdin = Arc::new(Mutex::new(child.stdin.take().ok_or_else(|| Error::Provider("no stdin".into()))?));
        let stdout = child.stdout.take().ok_or_else(|| Error::Provider("no stdout".into()))?;
        let stderr = child.stderr.take();
        let (tx, rx) = unbounded();
        let pending: Arc<Mutex<HashMap<u64, Waiter>>> = Arc::default();
        let quiet = Arc::new(AtomicBool::new(false));
        if let Some(stderr) = stderr {
            let tx = tx.clone();
            thread::Builder::new().name("acp-err".into()).spawn(move || {
                for line in BufReader::new(stderr).split(b'\n').map_while(Result::ok) {
                    let ev = Event { kind: EventKind::Other { kind: "stderr".into() }, raw: Some(line), native_message: None };
                    if tx.send(ev).is_err() {
                        return;
                    }
                }
            })?;
        }
        {
            let (pending, quiet, stdin) = (pending.clone(), quiet.clone(), stdin.clone());
            thread::Builder::new().name("acp-out".into()).spawn(move || {
                let mut state = Mapper::default();
                for line in BufReader::new(stdout).split(b'\n').map_while(Result::ok) {
                    let Ok(msg) = serde_json::from_slice::<Value>(&line) else { continue };
                    let raw = Some(line);
                    let method = msg["method"].as_str().map(str::to_string);
                    match (method, msg.get("id").cloned()) {
                        // A response to one of our requests.
                        (None, Some(id)) => {
                            let waiter = id.as_u64().and_then(|id| pending.lock().unwrap_or_else(|p| p.into_inner()).remove(&id));
                            let result = match msg.get("error") {
                                Some(e) => Err(e["message"].as_str().map(str::to_string).unwrap_or_else(|| e.to_string())),
                                None => Ok(msg["result"].clone()),
                            };
                            match waiter {
                                Some(Waiter::Reply(reply)) => {
                                    let _ = reply.send(result);
                                }
                                Some(Waiter::Turn) => {
                                    for ev in state.flush() {
                                        let _ = tx.send(ev);
                                    }
                                    let (ok, error) = match &result {
                                        Ok(r) => {
                                            let reason = r["stopReason"].as_str().unwrap_or("end_turn");
                                            (
                                                !matches!(reason, "refusal" | "error"),
                                                (reason != "end_turn").then(|| reason.to_string()),
                                            )
                                        }
                                        Err(e) => (false, Some(e.clone())),
                                    };
                                    let _ =
                                        tx.send(Event { kind: EventKind::TurnEnded { ok, error }, raw, native_message: None });
                                }
                                None => {}
                            }
                        }
                        // The agent asks us something.
                        (Some(method), Some(id)) => {
                            let reply = match method.as_str() {
                                "session/request_permission" => json!({
                                    "jsonrpc": "2.0", "id": id,
                                    "result": { "outcome": permission(&msg["params"], access) },
                                }),
                                _ => json!({
                                    "jsonrpc": "2.0", "id": id,
                                    "error": { "code": -32601, "message": format!("{method} is not supported by this client") },
                                }),
                            };
                            let _ = write_line(&stdin, &reply);
                            let _ = tx.send(Event { kind: EventKind::Other { kind: method }, raw, native_message: None });
                        }
                        (Some(method), None) => {
                            if method == "session/update" && !quiet.load(Ordering::SeqCst) {
                                let evs = state.map(&msg["params"]["update"]);
                                let n = evs.len();
                                for (i, mut ev) in evs.into_iter().enumerate() {
                                    // The raw line goes with the last event it produced.
                                    if i + 1 == n {
                                        ev.raw = raw.clone();
                                    }
                                    let _ = tx.send(ev);
                                }
                                if n == 0 {
                                    let _ = tx.send(Event {
                                        kind: EventKind::Other { kind: "session/update".into() },
                                        raw,
                                        native_message: None,
                                    });
                                }
                            } else {
                                let _ = tx.send(Event { kind: EventKind::Other { kind: method }, raw, native_message: None });
                            }
                        }
                        (None, None) => {}
                    }
                }
                // The process is gone: wake whoever waits.
                for (_, w) in pending.lock().unwrap_or_else(|p| p.into_inner()).drain() {
                    if let Waiter::Reply(r) = w {
                        let _ = r.send(Err("the agent exited".into()));
                    }
                }
            })?;
        }
        let mut conn = Conn {
            child: Arc::new(Mutex::new(Some(child))),
            stdin,
            next: AtomicU64::new(1),
            pending,
            events: rx,
            quiet,
            caps: Value::Null,
        };
        let init = conn.request(
            "initialize",
            json!({
                "protocolVersion": 1,
                "clientCapabilities": { "fs": { "readTextFile": false, "writeTextFile": false }, "terminal": false },
                "clientInfo": { "name": "0ndb", "version": env!("CARGO_PKG_VERSION") },
            }),
        )?;
        conn.caps = init["agentCapabilities"].clone();
        Ok(conn)
    }

    fn request(&self, method: &str, params: Value) -> Result<Value, Error> {
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = bounded(1);
        self.pending.lock().unwrap_or_else(|p| p.into_inner()).insert(id, Waiter::Reply(tx));
        write_line(&self.stdin, &json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))?;
        match rx.recv_timeout(REQUEST_TIMEOUT) {
            Ok(r) => r.map_err(|e| Error::Provider(format!("{method}: {e}"))),
            Err(_) => Err(Error::Provider(format!("{method}: no answer from the agent"))),
        }
    }

    /// Opens (or resumes) the session and selects the model.
    fn open_session(&self, req: &StartRequest) -> Result<Arc<Mutex<Option<String>>>, Error> {
        let cwd = req.cwd.to_string_lossy().into_owned();
        let (id, response) = match &req.resume {
            Some(id) => {
                let resume = self.caps["sessionCapabilities"].get("resume").is_some();
                let method = if resume { "session/resume" } else { "session/load" };
                // A load replays the conversation as updates: not this turn's.
                self.quiet.store(true, Ordering::SeqCst);
                let r = self.request(method, json!({ "sessionId": id, "cwd": cwd, "mcpServers": [] }));
                self.quiet.store(false, Ordering::SeqCst);
                (id.clone(), r?)
            }
            None => {
                let r = self.request("session/new", json!({ "cwd": cwd, "mcpServers": [] }))?;
                let id = r["sessionId"].as_str().ok_or_else(|| Error::Provider("session/new returned no sessionId".into()))?;
                (id.to_string(), r)
            }
        };
        if let Some(model) = &req.model
            && let Some((control, models)) = listed_models(&response)
            && !models.iter().any(|m| m.default && &m.id == model)
        {
            match control {
                ModelControl::Config(config) => {
                    self.request("session/set_config_option", json!({ "sessionId": id, "configId": config, "value": model }))?
                }
                ModelControl::SetModel => self.request("session/set_model", json!({ "sessionId": id, "modelId": model }))?,
            };
        }
        Ok(Arc::new(Mutex::new(Some(id))))
    }

    fn close(&self) {
        if let Some(mut c) = self.child.lock().unwrap_or_else(|p| p.into_inner()).take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// The option to pick for a permission request, per access level.
fn permission(params: &Value, access: Access) -> Value {
    let options = params["options"].as_array().cloned().unwrap_or_default();
    let prefer: &[&str] = match access {
        Access::Plan => &["reject_once", "reject_always"],
        Access::AcceptEdits | Access::Full => &["allow_always", "allow_once"],
    };
    for kind in prefer {
        if let Some(o) = options.iter().find(|o| o["kind"] == *kind) {
            return json!({ "outcome": "selected", "optionId": o["optionId"] });
        }
    }
    json!({ "outcome": "cancelled" })
}

/// Maps `session/update`s to events, assembling streamed text into blocks.
#[derive(Default)]
struct Mapper {
    text: String,
    thought: String,
}

fn content_text(c: &Value) -> Option<String> {
    match c["type"].as_str()? {
        "text" => c["text"].as_str().map(str::to_string),
        _ => None,
    }
}

impl Mapper {
    fn flush(&mut self) -> Vec<Event> {
        let mut out = Vec::new();
        if !self.thought.is_empty() {
            out.push(Event::new(EventKind::Reasoning { text: std::mem::take(&mut self.thought) }));
        }
        if !self.text.is_empty() {
            out.push(Event::new(EventKind::Text { text: std::mem::take(&mut self.text) }));
        }
        out
    }

    fn map(&mut self, u: &Value) -> Vec<Event> {
        match u["sessionUpdate"].as_str().unwrap_or_default() {
            "agent_message_chunk" => content_text(&u["content"])
                .map(|t| {
                    self.text.push_str(&t);
                    vec![Event::new(EventKind::TextDelta { text: t })]
                })
                .unwrap_or_default(),
            "agent_thought_chunk" => content_text(&u["content"])
                .map(|t| {
                    self.thought.push_str(&t);
                    vec![Event::new(EventKind::ReasoningDelta { text: t })]
                })
                .unwrap_or_default(),
            "tool_call" => {
                let mut out = self.flush();
                let id = u["toolCallId"].as_str().unwrap_or_default().to_string();
                let name = u["kind"].as_str().filter(|k| *k != "other").or(u["title"].as_str()).unwrap_or("tool").to_string();
                let mut input = u["rawInput"].clone();
                if input.is_null() {
                    input = json!({ "title": u["title"] });
                }
                out.push(Event::new(EventKind::ToolStarted { id: id.clone(), name, input }));
                if matches!(u["status"].as_str(), Some("completed" | "failed")) {
                    out.push(Event::new(tool_finished(id, u)));
                }
                out
            }
            "tool_call_update" if matches!(u["status"].as_str(), Some("completed" | "failed")) => {
                vec![Event::new(tool_finished(u["toolCallId"].as_str().unwrap_or_default().to_string(), u))]
            }
            _ => Vec::new(),
        }
    }
}

fn tool_finished(id: String, u: &Value) -> EventKind {
    let mut parts = Vec::new();
    for c in u["content"].as_array().into_iter().flatten() {
        match c["type"].as_str() {
            Some("content") => parts.extend(content_text(&c["content"])),
            Some("diff") => parts.push(format!("edited {}", c["path"].as_str().unwrap_or("a file"))),
            _ => {}
        }
    }
    let output = if parts.is_empty() {
        match &u["rawOutput"] {
            Value::Null => String::new(),
            Value::String(s) => s.clone(),
            v => v.to_string(),
        }
    } else {
        parts.join("\n")
    };
    EventKind::ToolFinished { id, output, is_error: u["status"] == "failed", stdout: None, stderr: None }
}

struct AcpRun {
    conn: Conn,
    session: Arc<Mutex<Option<String>>>,
    /// The session's id, reported with the first turn.
    first: Option<Event>,
}

impl Run for AcpRun {
    fn send(&mut self, prompt: &str) -> Result<(), Error> {
        let session = self.session.lock().unwrap_or_else(|p| p.into_inner()).clone();
        let session = session.ok_or_else(|| Error::Provider("no session".into()))?;
        let id = self.conn.next.fetch_add(1, Ordering::SeqCst);
        self.conn.pending.lock().unwrap_or_else(|p| p.into_inner()).insert(id, Waiter::Turn);
        write_line(
            &self.conn.stdin,
            &json!({
                "jsonrpc": "2.0", "id": id, "method": "session/prompt",
                "params": { "sessionId": session, "prompt": [{ "type": "text", "text": prompt }] },
            }),
        )?;
        Ok(())
    }

    fn next(&mut self) -> Option<Event> {
        if let Some(e) = self.first.take() {
            return Some(e);
        }
        self.conn.events.recv().ok()
    }

    fn interrupter(&self) -> Interrupter {
        let (stdin, session) = (self.conn.stdin.clone(), self.session.clone());
        Arc::new(move || {
            if let Some(id) = session.lock().unwrap_or_else(|p| p.into_inner()).clone() {
                let _ =
                    write_line(&stdin, &json!({ "jsonrpc": "2.0", "method": "session/cancel", "params": { "sessionId": id } }));
            }
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
    fn models_from_config_options_and_models_list() {
        let config = json!({ "configOptions": [{
            "id": "model", "category": "model", "currentValue": "b",
            "options": [{ "value": "a", "name": "A" }, { "value": "b" }],
        }]});
        let (control, models) = listed_models(&config).unwrap();
        assert!(matches!(control, ModelControl::Config(id) if id == "model"));
        assert_eq!(
            models.iter().map(|m| (m.id.as_str(), m.name.as_str(), m.default)).collect::<Vec<_>>(),
            [("a", "A", false), ("b", "b", true)]
        );

        let listed = json!({ "models": { "currentModelId": "x", "availableModels": [{ "modelId": "x", "name": "X" }] } });
        let (control, models) = listed_models(&listed).unwrap();
        assert!(matches!(control, ModelControl::SetModel));
        assert!(models[0].default && models[0].name == "X");
    }

    #[test]
    fn permissions_follow_access() {
        let params = json!({ "options": [
            { "optionId": "y", "kind": "allow_once" },
            { "optionId": "n", "kind": "reject_once" },
        ]});
        assert_eq!(permission(&params, Access::Full)["optionId"], "y");
        assert_eq!(permission(&params, Access::Plan)["optionId"], "n");
        assert_eq!(permission(&json!({}), Access::Full)["outcome"], "cancelled");
    }

    #[test]
    fn streamed_text_becomes_one_block_before_a_tool() {
        let mut m = Mapper::default();
        for t in ["he", "llo"] {
            m.map(&json!({ "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": t } }));
        }
        let evs = m.map(&json!({ "sessionUpdate": "tool_call", "toolCallId": "1", "kind": "edit", "status": "completed",
            "content": [{ "type": "diff", "path": "a.txt" }] }));
        let kinds: Vec<_> = evs.iter().map(|e| &e.kind).collect();
        assert!(matches!(kinds[0], EventKind::Text { text } if text == "hello"));
        assert!(matches!(kinds[1], EventKind::ToolStarted { name, .. } if name == "edit"));
        assert!(matches!(kinds[2], EventKind::ToolFinished { output, .. } if output == "edited a.txt"));
    }
}
