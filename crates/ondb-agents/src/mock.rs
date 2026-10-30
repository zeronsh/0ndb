//! A scripted provider: deterministic turns that really write files, for
//! tests and demos. It records what it was asked (prompts, resumes, forks).

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use crate::Error;
use crate::provider::{Capabilities, Event, EventKind, Interrupter, Provider, Run, StartRequest};

/// One step of a scripted turn.
#[derive(Clone, Debug)]
pub enum Step {
    Text(String),
    /// A tool call that writes `content` to `path` (relative to the cwd).
    Write {
        path: String,
        content: String,
    },
    /// The turn fails.
    Fail(String),
}

/// What the mock was asked to do, for assertions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Call {
    pub native_session: String,
    pub resumed: Option<String>,
    pub forked_at: Option<String>,
    pub prompt: String,
}

type Script = dyn Fn(&str) -> Vec<Step> + Send + Sync;

#[derive(Clone)]
pub struct Mock {
    id: &'static str,
    caps: Capabilities,
    script: Arc<Script>,
    calls: Arc<Mutex<Vec<Call>>>,
    live: Arc<AtomicUsize>,
    spawned: Arc<AtomicUsize>,
}

impl Mock {
    /// `script` maps each prompt to the turn's steps.
    pub fn new(id: &'static str, caps: Capabilities, script: impl Fn(&str) -> Vec<Step> + Send + Sync + 'static) -> Self {
        Mock { id, caps, script: Arc::new(script), calls: Arc::default(), live: Arc::default(), spawned: Arc::default() }
    }

    pub fn calls(&self) -> Vec<Call> {
        self.calls.lock().unwrap().clone()
    }

    /// Processes currently alive.
    pub fn live(&self) -> usize {
        self.live.load(Ordering::SeqCst)
    }

    /// Processes ever started.
    pub fn spawned(&self) -> usize {
        self.spawned.load(Ordering::SeqCst)
    }
}

impl Provider for Mock {
    fn id(&self) -> &'static str {
        self.id
    }

    fn capabilities(&self) -> Capabilities {
        self.caps
    }

    fn start(&self, req: StartRequest) -> Result<Box<dyn Run>, Error> {
        if req.fork_at.is_some() && !self.caps.fork_at_message {
            return Err(Error::Provider("mock can't fork".into()));
        }
        let native = match (&req.resume, &req.fork_at) {
            (Some(id), None) if self.caps.resume => id.clone(),
            _ => uuid::Uuid::new_v4().simple().to_string(),
        };
        self.live.fetch_add(1, Ordering::SeqCst);
        self.spawned.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(MockRun {
            mock: self.clone(),
            cwd: req.cwd,
            native,
            resumed: req.resume,
            forked_at: req.fork_at,
            queue: VecDeque::new(),
            started: false,
            turns: 0,
            closed: false,
        }))
    }
}

enum Pending {
    Event(Event),
    WriteThenFinish { path: String, content: String, id: String },
}

struct MockRun {
    mock: Mock,
    cwd: PathBuf,
    native: String,
    resumed: Option<String>,
    forked_at: Option<String>,
    queue: VecDeque<Pending>,
    started: bool,
    turns: usize,
    closed: bool,
}

impl MockRun {
    fn ev(&self, kind: EventKind) -> Pending {
        let raw = serde_json::to_vec(&serde_json::json!({ "mock": kind.name(), "session": self.native })).ok();
        Pending::Event(Event { kind, raw, native_message: Some(format!("{}-t{}", self.native, self.turns)) })
    }
}

impl Run for MockRun {
    fn send(&mut self, prompt: &str) -> Result<(), Error> {
        if self.closed {
            return Err(Error::Provider("mock process closed".into()));
        }
        self.turns += 1;
        self.mock.calls.lock().unwrap().push(Call {
            native_session: self.native.clone(),
            resumed: self.resumed.clone(),
            forked_at: self.forked_at.clone(),
            prompt: prompt.to_string(),
        });
        if !std::mem::replace(&mut self.started, true) {
            let e = self.ev(EventKind::SessionStarted { native_id: self.native.clone() });
            self.queue.push_back(e);
        }
        let steps = (self.mock.script)(prompt);
        let mut ok = true;
        let mut error = None;
        for (i, step) in steps.into_iter().enumerate() {
            match step {
                Step::Text(text) => {
                    let e = self.ev(EventKind::Text { text });
                    self.queue.push_back(e);
                }
                Step::Write { path, content } => {
                    let id = format!("tool-{}-{i}", self.turns);
                    let input = serde_json::json!({ "path": path, "content": content });
                    let e = self.ev(EventKind::ToolStarted { id: id.clone(), name: "Write".into(), input });
                    self.queue.push_back(e);
                    self.queue.push_back(Pending::WriteThenFinish { path, content, id });
                }
                Step::Fail(msg) => {
                    ok = false;
                    error = Some(msg);
                    break;
                }
            }
        }
        let e = self.ev(EventKind::TurnEnded { ok, error });
        self.queue.push_back(e);
        Ok(())
    }

    fn next(&mut self) -> Option<Event> {
        match self.queue.pop_front()? {
            Pending::Event(e) => Some(e),
            // The write happens only when the turn loop asks for the result,
            // i.e. after it has seen the tool start: like a real tool.
            Pending::WriteThenFinish { path, content, id } => {
                let full = self.cwd.join(&path);
                if let Some(dir) = full.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                let r = std::fs::write(&full, &content);
                let Pending::Event(e) = self.ev(EventKind::ToolFinished {
                    id,
                    output: format!("wrote {path}"),
                    is_error: r.is_err(),
                    stdout: None,
                    stderr: None,
                }) else {
                    unreachable!()
                };
                Some(e)
            }
        }
    }

    fn interrupter(&self) -> Interrupter {
        Arc::new(|| {})
    }

    fn close(&mut self) {
        if !std::mem::replace(&mut self.closed, true) {
            self.mock.live.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

impl Drop for MockRun {
    fn drop(&mut self) {
        self.close();
    }
}
