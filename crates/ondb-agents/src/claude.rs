//! Claude Code over its stream-json protocol (`claude --print
//! --input-format stream-json --output-format stream-json`). One process
//! serves many turns: prompts go in on stdin, events come out on stdout.
//! Native forks use `--resume <id> --resume-session-at <message> --fork-session`.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, unbounded};
use serde_json::{Value, json};

use crate::Error;
use crate::provider::{Capabilities, Event, EventKind, Interrupter, Provider, Run, StartRequest};

/// What Claude Code may do without asking. In non-interactive mode there is
/// nobody to ask, so anything outside the mode is refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    /// Explore and plan only.
    Plan,
    /// Edit files; other tools need approval (refused).
    AcceptEdits,
    /// Everything.
    Full,
}

#[derive(Clone, Debug)]
pub struct ClaudeCode {
    program: PathBuf,
    access: Access,
}

impl ClaudeCode {
    pub fn new(access: Access) -> Self {
        ClaudeCode { program: "claude".into(), access }
    }

    pub fn with_program(mut self, program: impl Into<PathBuf>) -> Self {
        self.program = program.into();
        self
    }
}

impl Provider for ClaudeCode {
    fn id(&self) -> &'static str {
        "claude-code"
    }

    fn name(&self) -> &'static str {
        "Claude Code"
    }

    fn available(&self) -> bool {
        crate::provider::on_path(&self.program)
    }

    /// Claude Code takes model aliases that always track the latest model
    /// of each tier; it has no listing command.
    fn models(&self) -> Result<Vec<crate::provider::ModelInfo>, Error> {
        Ok([("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
            .into_iter()
            .map(|(id, name)| crate::provider::ModelInfo { id: id.into(), name: name.into(), default: false })
            .collect())
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities { resume: true, fork_at_message: true, persistent: true }
    }

    fn start(&self, req: StartRequest) -> Result<Box<dyn Run>, Error> {
        let mut cmd = Command::new(&self.program);
        cmd.args([
            "--print",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
        ])
        .args([
            "--permission-mode",
            match self.access {
                Access::Plan => "plan",
                Access::AcceptEdits => "acceptEdits",
                Access::Full => "bypassPermissions",
            },
        ])
        .current_dir(&req.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
        if let Some(m) = &req.model {
            cmd.args(["--model", m]);
        }
        if let Some(id) = &req.resume {
            cmd.arg(format!("--resume={id}"));
            if let Some(at) = &req.fork_at {
                cmd.args(["--resume-session-at", at, "--fork-session"]);
            }
        }
        for (k, v) in &req.env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => Error::Provider(format!("{} is not installed", self.program.display())),
            _ => Error::Io(e),
        })?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().ok_or_else(|| Error::Provider("no stdout".into()))?;
        let stderr = child.stderr.take();
        let (tx, rx) = unbounded();
        let tail: Arc<Mutex<VecDeque<String>>> = Arc::default();
        if let Some(stderr) = stderr {
            // Stderr is recorded too (CLI output), and its tail explains a crash.
            let (tx, tail) = (tx.clone(), tail.clone());
            thread::Builder::new().name("claude-err".into()).spawn(move || {
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
        thread::Builder::new().name("claude-out".into()).spawn(move || {
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
        Ok(Box::new(ClaudeRun { child: Arc::new(Mutex::new(child)), stdin, events: rx, tail, ended: false }))
    }
}

struct ClaudeRun {
    child: Arc<Mutex<Child>>,
    stdin: Option<ChildStdin>,
    events: Receiver<Event>,
    tail: Arc<Mutex<VecDeque<String>>>,
    ended: bool,
}

impl ClaudeRun {
    fn child(&self) -> std::sync::MutexGuard<'_, Child> {
        self.child.lock().unwrap_or_else(|p| p.into_inner())
    }
}

impl Run for ClaudeRun {
    fn send(&mut self, prompt: &str) -> Result<(), Error> {
        let msg = json!({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": prompt}]}});
        let stdin = self.stdin.as_mut().ok_or_else(|| Error::Provider("claude's input is closed".into()))?;
        let mut line = serde_json::to_vec(&msg).map_err(|e| Error::Provider(e.to_string()))?;
        line.push(b'\n');
        stdin.write_all(&line)?;
        stdin.flush()?;
        Ok(())
    }

    fn next(&mut self) -> Option<Event> {
        match self.events.recv() {
            Ok(ev) => Some(ev),
            Err(_) => {
                // Stdout closed: report an abnormal exit once.
                if std::mem::replace(&mut self.ended, true) {
                    return None;
                }
                let status = self.child().wait().ok();
                if status.is_some_and(|s| s.success()) {
                    return None;
                }
                let tail = self.tail.lock().unwrap_or_else(|p| p.into_inner());
                let msg = tail.iter().rev().find(|l| !l.trim().is_empty()).cloned().unwrap_or_else(|| "claude exited".into());
                Some(Event::new(EventKind::TurnEnded { ok: false, error: Some(msg) }))
            }
        }
    }

    fn interrupter(&self) -> Interrupter {
        let child = self.child.clone();
        Arc::new(move || {
            let _ = child.lock().unwrap_or_else(|p| p.into_inner()).kill();
        })
    }

    fn close(&mut self) {
        self.stdin = None; // EOF: claude exits after the current turn
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if matches!(self.child().try_wait(), Ok(Some(_))) {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let mut child = self.child();
        let _ = child.kill();
        let _ = child.wait();
    }
}

impl Drop for ClaudeRun {
    fn drop(&mut self) {
        let mut child = self.child();
        if matches!(child.try_wait(), Ok(None)) {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Maps one stream-json line to events. Every line yields at least one
/// event so the raw wire is recorded in full.
pub fn parse_line(line: &[u8]) -> Vec<Event> {
    let raw = Some(line.to_vec());
    let Ok(v) = serde_json::from_slice::<Value>(line) else {
        return vec![Event { kind: EventKind::Other { kind: "unparsed".into() }, raw, native_message: None }];
    };
    let ty = v["type"].as_str().unwrap_or("");
    // Only transcript messages are fork points (`--resume-session-at`);
    // results, partial-message and system events carry other ids.
    let native = matches!(ty, "assistant" | "user").then(|| v["uuid"].as_str().map(str::to_string)).flatten();
    let mut kinds = Vec::new();
    match ty {
        "stream_event" => {
            let e = &v["event"];
            match (e["type"].as_str(), e["delta"]["type"].as_str()) {
                (Some("content_block_delta"), Some("text_delta")) => {
                    kinds.push(EventKind::TextDelta { text: e["delta"]["text"].as_str().unwrap_or("").to_string() })
                }
                (Some("content_block_delta"), Some("thinking_delta")) => {
                    kinds.push(EventKind::ReasoningDelta { text: e["delta"]["thinking"].as_str().unwrap_or("").to_string() })
                }
                (Some(t), _) => kinds.push(EventKind::Other { kind: format!("stream/{t}") }),
                _ => {}
            }
        }
        "system" if v["subtype"] == "init" => {
            if let Some(id) = v["session_id"].as_str() {
                kinds.push(EventKind::SessionStarted { native_id: id.to_string() });
            }
        }
        "assistant" => {
            for c in v["message"]["content"].as_array().into_iter().flatten() {
                match c["type"].as_str() {
                    Some("text") => kinds.push(EventKind::Text { text: c["text"].as_str().unwrap_or("").to_string() }),
                    Some("thinking") => {
                        kinds.push(EventKind::Reasoning { text: c["thinking"].as_str().unwrap_or("").to_string() })
                    }
                    Some("tool_use") => kinds.push(EventKind::ToolStarted {
                        id: c["id"].as_str().unwrap_or("").to_string(),
                        name: c["name"].as_str().unwrap_or("").to_string(),
                        input: c["input"].clone(),
                    }),
                    _ => {}
                }
            }
        }
        "user" => {
            for c in v["message"]["content"].as_array().into_iter().flatten() {
                if c["type"] == "tool_result" {
                    let output = match &c["content"] {
                        Value::String(s) => s.clone(),
                        Value::Array(parts) => parts.iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("\n"),
                        _ => String::new(),
                    };
                    let r = &v["tool_use_result"];
                    kinds.push(EventKind::ToolFinished {
                        id: c["tool_use_id"].as_str().unwrap_or("").to_string(),
                        output,
                        is_error: c["is_error"].as_bool().unwrap_or(false),
                        stdout: r["stdout"].as_str().map(str::to_string),
                        stderr: r["stderr"].as_str().map(str::to_string),
                    });
                }
            }
        }
        "result" => {
            let ok = v["subtype"] == "success" && !v["is_error"].as_bool().unwrap_or(false);
            if let Some(u) = v.get("usage") {
                kinds.push(EventKind::Usage {
                    input_tokens: u["input_tokens"].as_u64().unwrap_or(0),
                    output_tokens: u["output_tokens"].as_u64().unwrap_or(0),
                    cost_usd: v["total_cost_usd"].as_f64(),
                });
            }
            let error = (!ok).then(|| v["result"].as_str().or(v["subtype"].as_str()).unwrap_or("failed").to_string());
            kinds.push(EventKind::TurnEnded { ok, error });
        }
        _ => {}
    }
    if kinds.is_empty() {
        let name = match v["subtype"].as_str() {
            Some(st) => format!("{ty}/{st}"),
            None => ty.to_string(),
        };
        kinds.push(EventKind::Other { kind: name });
    }
    // The raw line rides on the first event only.
    let mut raw = raw;
    kinds.into_iter().map(|kind| Event { kind, raw: raw.take(), native_message: native.clone() }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_real_stream_json() {
        let lines = [
            r#"{"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"d4d5f2c0-1","tools":[],"model":"claude-haiku"}"#,
            r#"{"type":"rate_limit_event","rate_limit_info":{},"uuid":"r1","session_id":"d4d5f2c0-1"}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"cat a.txt"}}]},"uuid":"u1","session_id":"d4d5f2c0-1"}"#,
            r#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"hello","is_error":false}]},"uuid":"u2","tool_use_result":{"stdout":"hello","stderr":""}}"#,
            r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"do"}},"uuid":"s1"}"#,
            r#"{"type":"stream_event","event":{"type":"message_stop"},"uuid":"s2"}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]},"uuid":"u3"}"#,
            r#"{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"input_tokens":10,"output_tokens":3},"total_cost_usd":0.001}"#,
        ];
        let evs: Vec<Event> = lines.iter().flat_map(|l| parse_line(l.as_bytes())).collect();
        let kinds: Vec<&str> = evs.iter().map(|e| e.kind.name()).collect();
        assert_eq!(
            kinds,
            [
                "session_started",
                "rate_limit_event",
                "tool_started",
                "tool_finished",
                "text_delta",
                "stream/message_stop",
                "text",
                "usage",
                "turn_ended"
            ]
        );
        assert_eq!(evs[4].native_message, None, "stream events aren't fork points");
        assert!(matches!(&evs[0].kind, EventKind::SessionStarted { native_id } if native_id == "d4d5f2c0-1"));
        assert!(matches!(&evs[3].kind, EventKind::ToolFinished { stdout: Some(s), .. } if s == "hello"));
        assert_eq!(evs[6].native_message.as_deref(), Some("u3"));
        assert!(matches!(&evs[8].kind, EventKind::TurnEnded { ok: true, .. }));
        assert!(evs.iter().filter(|e| e.raw.is_some()).count() == lines.len(), "every line recorded once");
    }
}
