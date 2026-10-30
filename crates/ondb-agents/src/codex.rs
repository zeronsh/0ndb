//! Codex over `codex exec --json`: one process per turn, continued with
//! `codex exec resume <thread>`. (`codex exec fork` copies a whole thread,
//! not up to a message, so forks at a message are emulated by replay.)

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

use crossbeam_channel::{Receiver, unbounded};
use serde_json::{Value, json};

use crate::Error;
use crate::claude::Access;
use crate::provider::{Capabilities, Event, EventKind, Interrupter, Provider, Run, StartRequest};

#[derive(Clone, Debug)]
pub struct Codex {
    program: PathBuf,
    access: Access,
}

impl Codex {
    pub fn new(access: Access) -> Self {
        Codex { program: "codex".into(), access }
    }

    pub fn with_program(mut self, program: impl Into<PathBuf>) -> Self {
        self.program = program.into();
        self
    }
}

impl Provider for Codex {
    fn id(&self) -> &'static str {
        "codex"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities { resume: true, fork_at_message: false, persistent: false }
    }

    fn start(&self, req: StartRequest) -> Result<Box<dyn Run>, Error> {
        Ok(Box::new(CodexRun {
            program: self.program.clone(),
            access: self.access,
            req,
            thread: None,
            child: Arc::default(),
            events: None,
            tail: Arc::default(),
            ended: false,
        }))
    }
}

struct CodexRun {
    program: PathBuf,
    access: Access,
    req: StartRequest,
    /// The thread id, once known (later turns resume it).
    thread: Option<String>,
    child: Arc<Mutex<Option<Child>>>,
    events: Option<Receiver<Event>>,
    tail: Arc<Mutex<VecDeque<String>>>,
    ended: bool,
}

impl Run for CodexRun {
    fn send(&mut self, prompt: &str) -> Result<(), Error> {
        let mut cmd = Command::new(&self.program);
        cmd.arg("exec");
        let resume = self.thread.clone().or_else(|| self.req.resume.clone());
        if let Some(id) = &resume {
            cmd.args(["resume", id]);
        }
        cmd.args(["--json", "--skip-git-repo-check"]);
        match self.access {
            Access::Plan => cmd.args(["--sandbox", "read-only"]),
            Access::AcceptEdits => cmd.args(["--sandbox", "workspace-write"]),
            Access::Full => cmd.arg("--dangerously-bypass-approvals-and-sandbox"),
        };
        if let Some(m) = &self.req.model {
            cmd.args(["--model", m]);
        }
        cmd.arg("-").current_dir(&self.req.cwd).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        for (k, v) in &self.req.env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => Error::Provider(format!("{} is not installed", self.program.display())),
            _ => Error::Io(e),
        })?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(prompt.as_bytes())?;
        }
        let (tx, rx) = unbounded();
        if let Some(stderr) = child.stderr.take() {
            let (tx, tail) = (tx.clone(), self.tail.clone());
            thread::Builder::new().name("codex-err".into()).spawn(move || {
                for line in BufReader::new(stderr).split(b'\n').map_while(Result::ok) {
                    let text = String::from_utf8_lossy(&line).into_owned();
                    {
                        let mut t = tail.lock().unwrap_or_else(|p| p.into_inner());
                        t.push_back(text);
                        if t.len() > 20 {
                            t.pop_front();
                        }
                    }
                    let ev = Event { kind: EventKind::Other { kind: "stderr".into() }, raw: Some(line), native_message: None };
                    if tx.send(ev).is_err() {
                        return;
                    }
                }
            })?;
        }
        let stdout = child.stdout.take().ok_or_else(|| Error::Provider("no stdout".into()))?;
        thread::Builder::new().name("codex-out".into()).spawn(move || {
            for line in BufReader::new(stdout).split(b'\n').map_while(Result::ok) {
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                for ev in parse_line(&line) {
                    if tx.send(ev).is_err() {
                        return;
                    }
                }
            }
        })?;
        *self.child.lock().unwrap_or_else(|p| p.into_inner()) = Some(child);
        self.events = Some(rx);
        self.ended = false;
        Ok(())
    }

    fn next(&mut self) -> Option<Event> {
        let rx = self.events.as_ref()?;
        match rx.recv() {
            Ok(ev) => {
                if let EventKind::SessionStarted { native_id } = &ev.kind {
                    self.thread = Some(native_id.clone());
                }
                if matches!(ev.kind, EventKind::TurnEnded { .. }) {
                    self.ended = true;
                }
                Some(ev)
            }
            Err(_) => {
                self.events = None;
                let status = self.child.lock().unwrap_or_else(|p| p.into_inner()).take().and_then(|mut c| c.wait().ok());
                if self.ended || status.is_some_and(|s| s.success()) {
                    return None;
                }
                let tail = self.tail.lock().unwrap_or_else(|p| p.into_inner());
                let msg = tail.iter().rev().find(|l| !l.trim().is_empty()).cloned().unwrap_or_else(|| "codex exited".into());
                Some(Event::new(EventKind::TurnEnded { ok: false, error: Some(msg) }))
            }
        }
    }

    fn interrupter(&self) -> Interrupter {
        let child = self.child.clone();
        Arc::new(move || {
            if let Some(c) = child.lock().unwrap_or_else(|p| p.into_inner()).as_mut() {
                let _ = c.kill();
            }
        })
    }

    fn close(&mut self) {
        if let Some(mut c) = self.child.lock().unwrap_or_else(|p| p.into_inner()).take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

impl Drop for CodexRun {
    fn drop(&mut self) {
        self.close();
    }
}

fn tool_name(ty: &str) -> &str {
    match ty {
        "command_execution" => "Bash",
        "file_change" => "Edit",
        "mcp_tool_call" => "MCP",
        "web_search" => "WebSearch",
        other => other,
    }
}

fn is_tool(ty: &str) -> bool {
    matches!(ty, "command_execution" | "file_change" | "mcp_tool_call" | "web_search")
}

/// Maps one `codex exec --json` line to events (at least one per line, so
/// the wire is recorded in full).
pub fn parse_line(line: &[u8]) -> Vec<Event> {
    let raw = Some(line.to_vec());
    let Ok(v) = serde_json::from_slice::<Value>(line) else {
        return vec![Event { kind: EventKind::Other { kind: "unparsed".into() }, raw, native_message: None }];
    };
    let ty = v["type"].as_str().unwrap_or("");
    let item = &v["item"];
    let item_ty = item["type"].as_str().unwrap_or("");
    let id = item["id"].as_str().unwrap_or("").to_string();
    let mut kinds = Vec::new();
    match (ty, item_ty) {
        ("thread.started", _) => {
            if let Some(t) = v["thread_id"].as_str() {
                kinds.push(EventKind::SessionStarted { native_id: t.to_string() });
            }
        }
        ("item.completed", "agent_message") => {
            kinds.push(EventKind::Text { text: item["text"].as_str().unwrap_or("").to_string() })
        }
        ("item.completed", "reasoning") => {
            kinds.push(EventKind::Reasoning { text: item["text"].as_str().unwrap_or("").to_string() })
        }
        ("item.started", t) if is_tool(t) => {
            kinds.push(EventKind::ToolStarted { id: id.clone(), name: tool_name(t).to_string(), input: tool_input(item) })
        }
        ("item.completed", t) if is_tool(t) => {
            let output = match t {
                "command_execution" => item["aggregated_output"].as_str().unwrap_or("").to_string(),
                "file_change" => item["changes"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|c| format!("{} {}", c["kind"].as_str().unwrap_or("update"), c["path"].as_str().unwrap_or("")))
                    .collect::<Vec<_>>()
                    .join("\n"),
                _ => item.get("result").or(item.get("output")).map(|r| r.to_string()).unwrap_or_default(),
            };
            let failed = item["status"] == "failed" || item["exit_code"].as_i64().is_some_and(|c| c != 0);
            kinds.push(EventKind::ToolFinished {
                id,
                stdout: (t == "command_execution").then(|| output.clone()),
                output,
                is_error: failed,
                stderr: None,
            });
        }
        ("turn.completed", _) => {
            let u = &v["usage"];
            kinds.push(EventKind::Usage {
                input_tokens: u["input_tokens"].as_u64().unwrap_or(0),
                output_tokens: u["output_tokens"].as_u64().unwrap_or(0),
                cost_usd: None,
            });
            kinds.push(EventKind::TurnEnded { ok: true, error: None });
        }
        ("turn.failed", _) => kinds.push(EventKind::TurnEnded {
            ok: false,
            error: Some(v["error"]["message"].as_str().unwrap_or("codex turn failed").to_string()),
        }),
        _ => {}
    }
    if kinds.is_empty() {
        let name = if item_ty.is_empty() { ty.to_string() } else { format!("{ty}/{item_ty}") };
        kinds.push(EventKind::Other { kind: name });
    }
    let mut raw = raw;
    kinds.into_iter().map(|kind| Event { kind, raw: raw.take(), native_message: None }).collect()
}

fn tool_input(item: &Value) -> Value {
    match item["type"].as_str() {
        Some("command_execution") => json!({ "command": item["command"] }),
        Some("file_change") => json!({ "changes": item["changes"] }),
        _ => item.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_real_exec_json() {
        let lines = [
            r#"{"type":"thread.started","thread_id":"01a18f00-8a48"}"#,
            r#"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"ignoring config"}}"#,
            r#"{"type":"turn.started"}"#,
            r#"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"I'll run it.\n"}}"#,
            r#"{"type":"item.started","item":{"id":"item_4","type":"command_execution","command":"/bin/zsh -lc 'cat a.txt'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
            r#"{"type":"item.completed","item":{"id":"item_4","type":"command_execution","command":"/bin/zsh -lc 'cat a.txt'","aggregated_output":"hello\n","exit_code":0,"status":"completed"}}"#,
            r#"{"type":"item.completed","item":{"id":"item_5","type":"agent_message","text":"done"}}"#,
            r#"{"type":"turn.completed","usage":{"input_tokens":51441,"output_tokens":102}}"#,
        ];
        let evs: Vec<Event> = lines.iter().flat_map(|l| parse_line(l.as_bytes())).collect();
        let kinds: Vec<&str> = evs.iter().map(|e| e.kind.name()).collect();
        assert_eq!(
            kinds,
            [
                "session_started",
                "item.completed/error",
                "turn.started",
                "text",
                "tool_started",
                "tool_finished",
                "text",
                "usage",
                "turn_ended"
            ]
        );
        assert!(
            matches!(&evs[4].kind, EventKind::ToolStarted { name, input, .. } if name == "Bash" && input["command"].as_str().unwrap().contains("cat a.txt"))
        );
        assert!(matches!(&evs[5].kind, EventKind::ToolFinished { output, is_error: false, .. } if output == "hello\n"));
        let failed = parse_line(br#"{"type":"turn.failed","error":{"message":"model not supported"}}"#);
        assert!(matches!(&failed[0].kind, EventKind::TurnEnded { ok: false, error: Some(e) } if e == "model not supported"));
    }
}
