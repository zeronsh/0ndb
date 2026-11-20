//! Local playground server for 0ndb: worktrees, agent threads, streaming.
//! JSON API on http://127.0.0.1:4317/api, Server-Sent Events at /api/events.
//! State lives in $ONDB_PLAYGROUND (default ~/.0ndb-playground).

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use ondb::git::Forges;
use ondb::{MountOptions, Worktrees};
use ondb_agents::acp::Acp;
use ondb_agents::claude::{Access, ClaudeCode};
use ondb_agents::codex::Codex;
use ondb_agents::mock::{Mock, Step};
use ondb_agents::pi::Pi;
use ondb_agents::{Capabilities, Message, Provider, SessionOptions, Sessions};
use serde_json::{Value, json};

struct App {
    worktrees: Worktrees,
    sessions: Sessions,
    providers: Vec<Value>,
    /// Connected SSE clients.
    clients: Mutex<Vec<Sender<String>>>,
    /// Worktrees whose file changes are being forwarded.
    watched: Mutex<std::collections::HashSet<String>>,
}

impl App {
    fn broadcast(&self, frame: String) {
        self.clients.lock().unwrap().retain(|c| c.send(frame.clone()).is_ok());
    }
}

/// Forwards a worktree's history changes (branch switches, agent edits, any
/// process writing its files) to the UI, coalesced.
fn watch_worktree(app: &Arc<App>, id: &str) {
    if !app.watched.lock().unwrap().insert(id.to_string()) {
        return;
    }
    let Some((ws, _)) = app.worktrees.workspace(id) else { return };
    let rx = ws.subscribe();
    drop(ws);
    let (app, id) = (app.clone(), id.to_string());
    thread::spawn(move || {
        while rx.recv().is_ok() {
            thread::sleep(Duration::from_millis(40));
            while rx.try_recv().is_ok() {}
            app.broadcast(json!({ "type": "worktree_changed", "worktree": id }).to_string());
        }
        app.watched.lock().unwrap().remove(&id);
    });
}

type Res = Result<Value, String>;

fn main() {
    let home = std::env::var("ONDB_PLAYGROUND")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(std::env::var("HOME").expect("HOME")).join(".0ndb-playground"));
    let worktrees = Worktrees::open(home.join("state"), home.join("worktrees"), MountOptions::default(), Forges::default())
        .expect("open worktrees");
    let claude = ClaudeCode::new(Access::Full);
    let mock = Mock::new("mock", Capabilities { resume: true, fork_at_message: true, persistent: true }, mock_script);
    let mock_lite = Mock::new("mock-lite", Capabilities { resume: true, fork_at_message: false, persistent: false }, mock_script);
    let codex = Codex::new(Access::Full);
    let a = Access::Full;
    let all: Vec<Arc<dyn Provider>> = vec![
        Arc::new(claude),
        Arc::new(codex),
        Arc::new(Acp::devin(a)),
        Arc::new(Acp::cursor(a)),
        Arc::new(Acp::opencode(a)),
        Arc::new(Acp::grok(a)),
        Arc::new(Acp::hermes(a)),
        Arc::new(Acp::antigravity(a)),
        Arc::new(Pi::new()),
        Arc::new(mock),
        Arc::new(mock_lite),
    ];
    let sessions =
        Sessions::open(home.join("state/sessions.db"), worktrees.clone(), all, SessionOptions::default()).expect("open sessions");
    let providers = sessions
        .providers()
        .into_iter()
        .map(|p| {
            let c = p.capabilities;
            json!({
                "id": p.id, "name": p.name, "available": p.available,
                "resume": c.resume, "fork": c.fork_at_message, "persistent": c.persistent,
            })
        })
        .collect();
    // Turns a crash cut short pick up where they left off.
    for t in sessions.resume_interrupted() {
        eprintln!("resuming interrupted turn in thread {}", t.thread);
        std::thread::spawn(move || {
            let _ = t.wait();
        });
    }
    let app = Arc::new(App { worktrees, sessions, providers, clients: Mutex::default(), watched: Mutex::default() });
    for w in app.worktrees.list() {
        watch_worktree(&app, &w.id);
    }
    {
        let app = app.clone();
        let updates = app.sessions.subscribe();
        thread::spawn(move || {
            for u in updates {
                // A thread forked into a new worktree: forward its changes too.
                if let ondb_agents::Update::ThreadMoved { to, .. } = &u {
                    watch_worktree(&app, to);
                }
                app.broadcast(serde_json::to_string(&u).unwrap_or_default());
            }
        });
    }
    let addr = std::env::var("ONDB_PLAYGROUND_ADDR").unwrap_or_else(|_| "127.0.0.1:4317".into());
    let listener = TcpListener::bind(&addr).expect("bind");
    eprintln!("0ndb playground API on http://{addr} (state in {})", home.display());
    for stream in listener.incoming().flatten() {
        let app = app.clone();
        thread::spawn(move || {
            if let Err(e) = handle(&app, stream) {
                eprintln!("request failed: {e}");
            }
        });
    }
}

/// Scripted provider for trying the flow without spending API usage:
/// `write <path> <content>` writes a file inside a tool call; every reply
/// streams some markdown.
fn mock_script(prompt: &str) -> Vec<Step> {
    let last = prompt.lines().last().unwrap_or("").trim().to_string();
    let words: Vec<&str> = last.split_whitespace().collect();
    let mut steps = Vec::new();
    steps.push(Step::Think {
        text: "I'll check the request, identify the relevant files, and verify the result.\n\n**Plan:** keep the change focused and preserve the current worktree.".into(),
        chunk: 5,
        delay: Duration::from_millis(60),
    });
    if words.first() == Some(&"write") && words.len() >= 3 {
        // `\n` in the prompt writes a line break, for multi-line files.
        steps.push(Step::Write { path: words[1].into(), content: format!("{}\n", words[2..].join(" ").replace("\\n", "\n")) });
    }
    let replayed = prompt.contains("<conversation>");
    let reply = format!(
        "Here's what I did for **{}**.\n\n{}\n\n- streamed in small deltas\n- recorded as raw events\n{}\n\n```rust\nfn main() {{\n    println!(\"{}\");\n}}\n```",
        last.replace('*', ""),
        if words.first() == Some(&"write") {
            format!("I wrote `{}` inside a tool call, so its change is attributed to that call.", words[1])
        } else {
            "Nothing to change on disk, so this is just a reply.".into()
        },
        if replayed { "- I was given the earlier conversation (provider switch or fresh session)" } else { "" },
        last.replace('"', "'")
    );
    steps.push(Step::Stream { text: reply, chunk: 3, delay: Duration::from_millis(14) });
    steps
}

struct Request {
    method: String,
    path: Vec<String>,
    query: HashMap<String, String>,
    body: Value,
}

fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => {
                if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    out.push(v);
                    i += 2;
                }
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn read_request(stream: &TcpStream) -> Option<Request> {
    let mut r = BufReader::new(stream.try_clone().ok()?);
    let mut line = String::new();
    r.read_line(&mut line).ok()?;
    let mut parts = line.split_whitespace();
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();
    let mut len = 0usize;
    loop {
        let mut h = String::new();
        r.read_line(&mut h).ok()?;
        let h = h.trim_end();
        if h.is_empty() {
            break;
        }
        if let Some((k, v)) = h.split_once(':')
            && k.eq_ignore_ascii_case("content-length")
        {
            len = v.trim().parse().unwrap_or(0);
        }
    }
    let mut body = vec![0u8; len.min(16 << 20)];
    r.read_exact(&mut body).ok()?;
    let (path, q) = target.split_once('?').unwrap_or((&target, ""));
    let query = q.split('&').filter_map(|kv| kv.split_once('=')).map(|(k, v)| (decode(k), decode(v))).collect();
    Some(Request {
        method,
        path: path.split('/').filter(|s| !s.is_empty()).map(decode).collect(),
        query,
        body: if body.is_empty() { Value::Null } else { serde_json::from_slice(&body).unwrap_or(Value::Null) },
    })
}

fn respond(mut stream: TcpStream, status: u16, body: &Value) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(body).unwrap_or_default();
    write!(
        stream,
        "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        bytes.len()
    )?;
    stream.write_all(&bytes)
}

fn handle(app: &Arc<App>, stream: TcpStream) -> std::io::Result<()> {
    let Some(req) = read_request(&stream) else { return Ok(()) };
    let p: Vec<&str> = req.path.iter().map(String::as_str).collect();
    if req.method == "GET" && p == ["api", "events"] {
        return sse(app, stream);
    }
    let r = route(app, &req, &p);
    match r {
        Ok(v) => respond(stream, 200, &v),
        Err(e) => respond(stream, 400, &json!({ "error": e })),
    }
}

fn str_of<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn e<E: std::fmt::Display>(err: E) -> String {
    err.to_string()
}

fn route(app: &Arc<App>, req: &Request, p: &[&str]) -> Res {
    let s = &app.sessions;
    let b = &req.body;
    match (req.method.as_str(), p) {
        ("GET", ["api", "state"]) => Ok(json!({
            "providers": app.providers,
            "worktrees": app.worktrees.list(),
            "threads": s.threads().map_err(e)?,
            "warm": s.warm_processes(),
        })),
        ("GET", ["api", "providers", id, "models"]) => {
            let refresh = req.query.get("refresh").is_some_and(|v| v == "1");
            Ok(json!(s.models(id, refresh).map_err(e)?))
        }
        ("POST", ["api", "worktrees"]) => {
            let repo = str_of(b, "repo").ok_or("repo is required")?;
            let title = str_of(b, "title").unwrap_or("playground");
            let w = app.worktrees.create(repo, title, str_of(b, "base")).map_err(e)?;
            watch_worktree(app, &w.id);
            Ok(json!(w))
        }
        ("POST", ["api", "worktrees", "adopt"]) => {
            let path = str_of(b, "path").ok_or("path is required")?;
            let w = app.worktrees.adopt(path, str_of(b, "title").unwrap_or("folder")).map_err(e)?;
            watch_worktree(app, &w.id);
            Ok(json!(w))
        }
        ("POST", ["api", "worktrees", id, "remove"]) => {
            let force = b.get("force").and_then(Value::as_bool).unwrap_or(false);
            let branch = b.get("delete_branch").and_then(Value::as_bool).unwrap_or(false);
            app.worktrees.remove(id, force, branch).map_err(e)?;
            Ok(json!({ "ok": true }))
        }
        ("GET", ["api", "worktrees", id, "files"]) => {
            let (ws, _) = app.worktrees.workspace(id).ok_or("worktree isn't mounted")?;
            let files: Vec<String> = ws.read(|h| {
                let view = h.current();
                h.walk().into_iter().filter(|(_, ino)| h.file_state(&view, ino).is_some()).map(|(p, _)| p).collect()
            });
            Ok(json!(files))
        }
        ("GET", ["api", "worktrees", id, "file"]) => {
            let wt = app.worktrees.get(id).ok_or("no worktree")?;
            let rel = req.query.get("path").ok_or("path is required")?;
            if rel.contains("..") {
                return Err("bad path".into());
            }
            let bytes = std::fs::read(wt.path.join(rel)).map_err(e)?;
            Ok(json!({ "path": rel, "text": String::from_utf8_lossy(&bytes[..bytes.len().min(256 << 10)]) }))
        }
        ("GET", ["api", "worktrees", id, "pr"]) => Ok(json!(app.worktrees.change_request(id).map_err(e)?)),
        ("GET", ["api", "worktrees", id, "history"]) => {
            let (ws, _) = app.worktrees.workspace(id).ok_or("worktree isn't mounted")?;
            let limit = req.query.get("limit").and_then(|l| l.parse().ok()).unwrap_or(40);
            Ok(json!(ondb::timeline::entries(&ws, req.query.get("before").map(String::as_str), limit).map_err(e)?))
        }
        ("GET", ["api", "worktrees", id, "diff"]) => {
            let (ws, _) = app.worktrees.workspace(id).ok_or("worktree isn't mounted")?;
            let ids: Option<Vec<_>> =
                req.query.get("ids").map(|s| s.split(',').map(ondb::timeline::parse_batch_id).collect()).unwrap_or_default();
            Ok(json!(ondb::timeline::diff(&ws, &ids.ok_or("bad change id")?).map_err(e)?))
        }
        ("POST", ["api", "chats"]) => {
            let t = s.create_chat(str_of(b, "title").unwrap_or("New chat")).map_err(e)?;
            watch_worktree(app, &t.worktree);
            Ok(json!(t))
        }
        ("POST", ["api", "threads"]) => {
            let wt = str_of(b, "worktree").ok_or("worktree is required")?;
            Ok(json!(s.create_thread(wt, str_of(b, "title").unwrap_or("New thread")).map_err(e)?))
        }
        ("POST", ["api", "threads", id, "sync"]) => Ok(json!(sync_view(&s.sync(id).map_err(e)?))),
        ("POST", ["api", "threads", id, "land"]) => {
            let r = s.land(id).map_err(e)?;
            Ok(json!({ "landed": r.landed, "sync": sync_view(&r.sync) }))
        }
        ("GET", ["api", "threads", id, "conflicts"]) => {
            Ok(json!(s.conflicts(id).map_err(e)?.iter().map(conflict_view).collect::<Vec<_>>()))
        }
        ("POST", ["api", "threads", id, "resolve"]) => {
            let path = str_of(b, "path").ok_or("path is required")?;
            let resolution = match str_of(b, "take") {
                Some("ours") => ondb::Resolution::Ours,
                Some("theirs") => ondb::Resolution::Theirs,
                Some("content") => {
                    ondb::Resolution::Content(b.get("content").and_then(Value::as_str).map(|t| t.as_bytes().to_vec()))
                }
                _ => return Err("take must be ours, theirs or content".into()),
            };
            s.resolve(id, path, resolution).map_err(e)?;
            Ok(json!({ "ok": true }))
        }
        ("GET", ["api", "threads", id, "page"]) => {
            let limit = req.query.get("limit").and_then(|l| l.parse().ok()).unwrap_or(40);
            let page = s.page(id, req.query.get("before").map(String::as_str), limit).map_err(e)?;
            let messages: Result<Vec<Value>, String> = page.messages.iter().map(|m| view(s, m)).collect();
            Ok(json!({ "messages": messages?, "has_more": page.has_more, "sessions": s.provider_sessions(id).map_err(e)? }))
        }
        ("POST", ["api", "threads", id, "send"]) => {
            let prompt = str_of(b, "prompt").ok_or("prompt is required")?;
            let provider = str_of(b, "provider").unwrap_or("mock");
            let turn = s.send(id, prompt, provider, str_of(b, "model")).map_err(e)?;
            Ok(detach(turn))
        }
        ("POST", ["api", "threads", id, "interrupt"]) => Ok(json!({ "interrupted": s.interrupt(id) })),
        ("POST", ["api", "messages", id, "edit"]) => {
            let prompt = str_of(b, "prompt").ok_or("prompt is required")?;
            let provider = str_of(b, "provider").unwrap_or("mock");
            let turn = s.edit(id, prompt, provider, str_of(b, "model")).map_err(e)?;
            Ok(detach(turn))
        }
        ("POST", ["api", "messages", id, "switch"]) => Ok(json!(s.switch_branch(id).map_err(e)?)),
        ("GET", ["api", "messages", id, "events"]) => {
            let after = req.query.get("after").and_then(|a| a.parse().ok()).unwrap_or(0);
            let limit = req.query.get("limit").and_then(|l| l.parse().ok()).unwrap_or(100);
            let evs = s.events_page(id, after, limit).map_err(e)?;
            Ok(json!(
                evs.into_iter()
                    .map(|ev| json!({
                        "seq": ev.seq, "kind": ev.kind, "ts_ms": ev.ts_ms, "native": ev.native,
                        "raw": ev.raw.map(|r| String::from_utf8_lossy(&r).into_owned()),
                    }))
                    .collect::<Vec<_>>()
            ))
        }
        _ => Err(format!("no route {} /{}", req.method, p.join("/"))),
    }
}

fn conflict_view(c: &ondb::Conflict) -> Value {
    let text = |b: &Option<Vec<u8>>| b.as_ref().map(|b| String::from_utf8_lossy(b).into_owned());
    json!({ "path": c.path, "kind": c.kind, "ours": text(&c.ours), "theirs": text(&c.theirs) })
}

fn sync_view(r: &ondb::SyncReport) -> Value {
    json!({ "brought": r.brought, "merged": r.merged, "conflicts": r.conflicts.iter().map(conflict_view).collect::<Vec<_>>() })
}

/// A message with what the UI needs: alternatives, tool calls, live text.
fn view(s: &Sessions, m: &Message) -> Res {
    let sibs = s.siblings(&m.id).map_err(e)?;
    let index = sibs.iter().position(|x| x.id == m.id).unwrap_or(0);
    let mut v = json!(m);
    v["siblings"] = json!(sibs.iter().map(|x| &x.id).collect::<Vec<_>>());
    v["sibling_index"] = json!(index);
    v["tools"] = json!(s.tool_calls(&m.id).map_err(e)?);
    if m.role == ondb_agents::Role::Assistant {
        v["reasoning"] = json!(s.reasoning(&m.id).map_err(e)?);
    }
    if let Some(live) = s.live_text(&m.id) {
        v["live"] = json!(live);
    }
    Ok(v)
}

fn detach(turn: ondb_agents::Turn) -> Value {
    let v = json!({ "thread": turn.thread, "user": turn.user, "assistant": turn.assistant });
    thread::spawn(move || {
        if let Err(err) = turn.wait() {
            eprintln!("turn failed: {err}");
        }
    });
    v
}

fn sse(app: &App, mut stream: TcpStream) -> std::io::Result<()> {
    let (tx, rx) = channel();
    app.clients.lock().unwrap().push(tx);
    stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n: hi\n\n")?;
    loop {
        let chunk = match rx.recv_timeout(Duration::from_secs(15)) {
            Ok(frame) => format!("data: {frame}\n\n"),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => ": ping\n\n".to_string(),
            Err(_) => return Ok(()),
        };
        stream.write_all(chunk.as_bytes())?;
        stream.flush()?;
    }
}
