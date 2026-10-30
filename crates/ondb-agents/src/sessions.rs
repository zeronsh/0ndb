//! Provider sessions over managed worktrees.
//!
//! * A **thread** is a tree of messages; its `leaf` selects the branch
//!   shown. Editing a user message adds a sibling (`<1/2>`), and switching
//!   branches moves the leaf and, optionally, the worktree's files.
//! * Every message is pinned to a worktree version, and every turn and tool
//!   call is an attribution scope, so files can be restored to any message
//!   and each line traced to the tool call that wrote it.
//! * Provider sessions are chosen per turn: continue the session that last
//!   saw this branch; else fork a native session at the branch point when
//!   the provider can; else start fresh. Whatever the chosen session hasn't
//!   seen (turns by another provider, or another branch) is replayed in
//!   front of the prompt, so providers can be switched mid-thread.
//! * Every provider event is recorded verbatim, alongside the tool calls
//!   and their output.
//! * At most `warm_limit` provider processes stay alive between turns, each
//!   for `warm_idle`; a parked session resumes natively on its next turn.
//!   Nothing runs or wakes while no process is warm.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, bounded, unbounded};
use ondb::{ActorKind, Recorder, ScopeKind, Worktrees};
use ondb_core::{BatchId, Version};

use crate::Error;
use crate::provider::{EventKind, Interrupter, Provider, Run, StartRequest};
use crate::store::{Message, ProviderSession, RecordedEvent, Role, Status, Store, Thread, ToolCall};

#[derive(Clone, Debug)]
pub struct SessionOptions {
    /// Provider processes kept alive between turns.
    pub warm_limit: usize,
    /// How long a parked process stays alive without a new turn.
    pub warm_idle: Duration,
    /// Characters of replayed history put in front of a prompt.
    pub history_chars: usize,
}

impl Default for SessionOptions {
    fn default() -> Self {
        SessionOptions { warm_limit: 2, warm_idle: Duration::from_secs(90), history_chars: 60_000 }
    }
}

/// What happens to the worktree's files when editing a message or
/// switching branches.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Restore {
    /// Leave the files alone.
    Keep,
    /// Files exactly as they were at the message (git checkouts excepted).
    Full,
    /// Undo only what agents changed since; edits made by people stay.
    AgentOnly,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Update {
    /// The user message of a turn that just started (and its assistant id).
    TurnStarted {
        thread: String,
        user: String,
        message: String,
    },
    /// Streamed text.
    TextDelta {
        thread: String,
        message: String,
        text: String,
    },
    ReasoningDelta {
        thread: String,
        message: String,
        text: String,
    },
    /// A complete text block.
    Text {
        thread: String,
        message: String,
        text: String,
    },
    ToolStarted {
        thread: String,
        message: String,
        id: String,
        name: String,
    },
    ToolFinished {
        thread: String,
        message: String,
        id: String,
        is_error: bool,
    },
    TurnEnded {
        thread: String,
        message: String,
        status: Status,
    },
}

/// A turn in progress.
pub struct Turn {
    pub thread: String,
    pub user: String,
    pub assistant: String,
    done: Receiver<Result<Message, Error>>,
    control: Arc<TurnControl>,
}

#[derive(Default)]
struct TurnControl {
    interrupted: AtomicBool,
    interrupter: Mutex<Option<Interrupter>>,
}

impl Turn {
    /// Blocks until the turn ends; returns the assistant message.
    pub fn wait(self) -> Result<Message, Error> {
        self.done.recv().map_err(|_| Error::Invalid("turn thread vanished".into()))?
    }

    pub fn interrupt(&self) {
        self.control.interrupted.store(true, Ordering::SeqCst);
        if let Some(i) = self.control.interrupter.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
            i();
        }
    }
}

struct Warm {
    session: String,
    model: Option<String>,
    run: Box<dyn Run>,
    since: Instant,
}

struct Inner {
    store: Store,
    worktrees: Worktrees,
    providers: HashMap<&'static str, Arc<dyn Provider>>,
    opts: SessionOptions,
    warm: Mutex<Vec<Warm>>,
    reaper: Sender<()>,
    busy: Mutex<HashSet<String>>,
    /// Running turns by thread, for interrupting.
    active: Mutex<HashMap<String, Arc<TurnControl>>>,
    /// Text streamed so far for running assistant messages.
    live: Mutex<HashMap<String, String>>,
    subs: Mutex<Vec<Sender<Update>>>,
}

/// One page of a thread's selected branch, oldest first.
#[derive(Clone, Debug, serde::Serialize)]
pub struct Page {
    pub messages: Vec<Message>,
    /// Older messages exist before the first one.
    pub has_more: bool,
}

#[derive(Clone)]
pub struct Sessions {
    inner: Arc<Inner>,
}

fn now_ms() -> u64 {
    ondb_core::now_ms()
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..16].to_string()
}

fn clip(s: &str, max: usize) -> String {
    match s.char_indices().nth(max) {
        Some((i, _)) => format!("{}…", &s[..i]),
        None => s.to_string(),
    }
}

impl Sessions {
    pub fn open(
        db: impl AsRef<std::path::Path>,
        worktrees: Worktrees,
        providers: Vec<Arc<dyn Provider>>,
        opts: SessionOptions,
    ) -> Result<Sessions, Error> {
        let (tx, rx) = unbounded();
        let inner = Arc::new(Inner {
            store: Store::open(db)?,
            worktrees,
            providers: providers.into_iter().map(|p| (p.id(), p)).collect(),
            opts,
            warm: Mutex::default(),
            reaper: tx,
            busy: Mutex::default(),
            active: Mutex::default(),
            live: Mutex::default(),
            subs: Mutex::default(),
        });
        let weak = Arc::downgrade(&inner);
        thread::Builder::new().name("ondb-reaper".into()).spawn(move || reap(weak, rx))?;
        Ok(Sessions { inner })
    }

    pub fn store(&self) -> &Store {
        &self.inner.store
    }

    pub fn create_thread(&self, worktree: &str, title: &str) -> Result<Thread, Error> {
        if self.inner.worktrees.get(worktree).is_none() {
            return Err(Error::Invalid(format!("no managed worktree {worktree}")));
        }
        let t = Thread { id: new_id(), worktree: worktree.into(), title: title.into(), leaf: None, created_ms: now_ms() };
        self.inner.store.insert_thread(&t)?;
        Ok(t)
    }

    pub fn thread(&self, id: &str) -> Result<Thread, Error> {
        self.inner.store.thread(id)?.ok_or_else(|| Error::Invalid(format!("no thread {id}")))
    }

    pub fn threads(&self) -> Result<Vec<Thread>, Error> {
        self.inner.store.threads()
    }

    /// The selected branch, root to leaf.
    pub fn path(&self, thread: &str) -> Result<Vec<Message>, Error> {
        match self.thread(thread)?.leaf {
            Some(leaf) => self.inner.store.path(&leaf),
            None => Ok(Vec::new()),
        }
    }

    /// The message and its alternatives (same parent), oldest first: what a
    /// `<i/n>` switcher shows.
    pub fn siblings(&self, message: &str) -> Result<Vec<Message>, Error> {
        let m = self.message(message)?;
        self.inner.store.children(&m.thread, m.parent.as_deref())
    }

    pub fn message(&self, id: &str) -> Result<Message, Error> {
        self.inner.store.message(id)?.ok_or_else(|| Error::Invalid(format!("no message {id}")))
    }

    pub fn tool_calls(&self, message: &str) -> Result<Vec<ToolCall>, Error> {
        self.inner.store.tool_calls(message)
    }

    /// Every provider event of a message, verbatim, in order.
    pub fn events(&self, message: &str) -> Result<Vec<RecordedEvent>, Error> {
        self.inner.store.events(Some(message), None)
    }

    pub fn provider_sessions(&self, thread: &str) -> Result<Vec<ProviderSession>, Error> {
        self.inner.store.sessions(thread)
    }

    /// Records CLI output (a terminal or command run on the agent's behalf)
    /// against a message, optionally one of its tool calls.
    pub fn record_output(&self, message: &str, tool_call: Option<&str>, stream: &str, data: &[u8]) -> Result<(), Error> {
        self.inner.store.append_output(message, tool_call, stream, now_ms(), data)
    }

    /// Up to `limit` messages of the selected branch ending just before
    /// `before` (default: the leaf, inclusive).
    pub fn page(&self, thread: &str, before: Option<&str>, limit: usize) -> Result<Page, Error> {
        let end = match before {
            Some(b) => self.message(b)?.parent,
            None => self.thread(thread)?.leaf,
        };
        let Some(end) = end else { return Ok(Page { messages: Vec::new(), has_more: false }) };
        let mut messages = self.inner.store.path_tail(&end, limit + 1)?;
        let has_more = messages.len() > limit;
        if has_more {
            messages.remove(0);
        }
        Ok(Page { messages, has_more })
    }

    /// A page of a message's recorded events after sequence `after`.
    pub fn events_page(&self, message: &str, after: i64, limit: usize) -> Result<Vec<RecordedEvent>, Error> {
        self.inner.store.events_after(message, after, limit)
    }

    /// Text streamed so far by a running assistant message.
    pub fn live_text(&self, message: &str) -> Option<String> {
        self.inner.live.lock().unwrap_or_else(|p| p.into_inner()).get(message).cloned()
    }

    /// Stops the thread's running turn, if any.
    pub fn interrupt(&self, thread: &str) -> bool {
        let control = self.inner.active.lock().unwrap_or_else(|p| p.into_inner()).get(thread).cloned();
        match control {
            Some(c) => {
                c.interrupted.store(true, Ordering::SeqCst);
                if let Some(i) = c.interrupter.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
                    i();
                }
                true
            }
            None => false,
        }
    }

    pub fn subscribe(&self) -> Receiver<Update> {
        let (tx, rx) = unbounded();
        self.inner.subs.lock().unwrap_or_else(|p| p.into_inner()).push(tx);
        rx
    }

    /// Provider processes alive between turns.
    pub fn warm_processes(&self) -> usize {
        self.inner.warm.lock().unwrap_or_else(|p| p.into_inner()).len()
    }

    /// Ends every parked provider process.
    pub fn close_idle(&self) {
        let runs: Vec<Warm> = std::mem::take(&mut *self.inner.warm.lock().unwrap_or_else(|p| p.into_inner()));
        for mut w in runs {
            w.run.close();
        }
    }

    /// Sends a prompt on the thread's selected branch.
    pub fn send(&self, thread: &str, prompt: &str, provider: &str, model: Option<&str>) -> Result<Turn, Error> {
        let leaf = self.thread(thread)?.leaf;
        self.start_turn(thread, leaf, prompt, provider, model)
    }

    /// Replaces a user message: a sibling with `prompt` becomes the selected
    /// branch, the worktree is restored per `restore` to how it was when the
    /// original was sent, and the agent runs from there.
    pub fn edit(
        &self,
        message: &str,
        prompt: &str,
        provider: &str,
        model: Option<&str>,
        restore: Restore,
    ) -> Result<Turn, Error> {
        let m = self.message(message)?;
        if m.role != Role::User {
            return Err(Error::Invalid("only user messages can be edited".into()));
        }
        let t = self.thread(&m.thread)?;
        self.check_idle(&t.id)?;
        self.restore(&t.worktree, m.version.as_ref(), restore)?;
        self.start_turn(&t.id, m.parent.clone(), prompt, provider, model)
    }

    /// Selects the branch through `message` (its most recent continuation)
    /// and restores the worktree to that branch's last state per `restore`.
    pub fn switch_branch(&self, message: &str, restore: Restore) -> Result<Message, Error> {
        let mut leaf = self.message(message)?;
        let t = self.thread(&leaf.thread)?;
        self.check_idle(&t.id)?;
        while let Some(next) = self.inner.store.children(&t.id, Some(&leaf.id))?.pop() {
            leaf = next;
        }
        self.restore(&t.worktree, leaf.version.as_ref(), restore)?;
        self.inner.store.set_leaf(&t.id, &leaf.id)?;
        Ok(leaf)
    }

    fn check_idle(&self, thread: &str) -> Result<(), Error> {
        if self.inner.busy.lock().unwrap_or_else(|p| p.into_inner()).contains(thread) {
            return Err(Error::Busy(thread.into()));
        }
        Ok(())
    }

    /// Makes the worktree's files match `target` (all of it, or only what
    /// agents changed), never undoing git checkouts.
    fn restore(&self, worktree: &str, target: Option<&Version>, mode: Restore) -> Result<(), Error> {
        let Some(target) = target.filter(|_| mode != Restore::Keep) else { return Ok(()) };
        let (ws, mount) = self
            .inner
            .worktrees
            .workspace(worktree)
            .ok_or_else(|| Error::Invalid(format!("worktree {worktree} isn't mounted")))?;
        mount.fence()?;
        let restorer = ws.actor("restore", ActorKind::Agent)?;
        let agent_scoped: HashSet<BatchId> = if mode == Restore::AgentOnly {
            ondb::attrib::scopes(&ws).into_iter().filter(|s| s.agent.is_some()).flat_map(|s| s.batches).collect()
        } else {
            HashSet::new()
        };
        let mut undo = HashSet::new();
        for b in ws.batches_missing_from(target)? {
            let id = b.id();
            let s = ws.summary(&id)?;
            if s.git_checkout || s.is_annotation_only() {
                continue;
            }
            let by_agent = || {
                s.actor == restorer
                    || agent_scoped.contains(&id)
                    || ws.actor_info(&s.actor).is_some_and(|i| i.kind == ActorKind::Agent)
            };
            if mode == Restore::Full || by_agent() {
                undo.insert(id);
            }
        }
        if ondb::revert::revert_batches(&ws, restorer, &undo)?.is_some() {
            mount.fence()?;
        }
        Ok(())
    }

    fn start_turn(
        &self,
        thread: &str,
        parent: Option<String>,
        prompt: &str,
        provider: &str,
        model: Option<&str>,
    ) -> Result<Turn, Error> {
        let provider =
            self.inner.providers.get(provider).cloned().ok_or_else(|| Error::Invalid(format!("unknown provider {provider}")))?;
        if !self.inner.busy.lock().unwrap_or_else(|p| p.into_inner()).insert(thread.to_string()) {
            return Err(Error::Busy(thread.into()));
        }
        let guard = BusyGuard { inner: self.inner.clone(), thread: thread.to_string() };
        let t = self.thread(thread)?;
        let wt = self.inner.worktrees.get(&t.worktree).ok_or_else(|| Error::Invalid(format!("no worktree {}", t.worktree)))?;
        let (ws, mount) =
            self.inner.worktrees.workspace(&wt.id).ok_or_else(|| Error::Invalid(format!("worktree {} isn't mounted", wt.id)))?;
        mount.fence()?;
        let user = Message {
            id: new_id(),
            thread: t.id.clone(),
            parent,
            role: Role::User,
            provider: None,
            model: None,
            text: prompt.to_string(),
            version: Some(ws.heads()),
            scope: None,
            session: None,
            native: None,
            status: Status::Done,
            error: None,
            created_ms: now_ms(),
        };
        self.inner.store.insert_message(&user)?;
        self.inner.store.set_leaf(&t.id, &user.id)?;
        let assistant = new_id();
        let control = Arc::new(TurnControl::default());
        self.inner.active.lock().unwrap_or_else(|p| p.into_inner()).insert(t.id.clone(), control.clone());
        self.inner.emit(Update::TurnStarted { thread: t.id.clone(), user: user.id.clone(), message: assistant.clone() });
        let (tx, rx) = bounded(1);
        let job = TurnJob {
            inner: self.inner.clone(),
            thread: t.id.clone(),
            cwd: wt.path.clone(),
            ws,
            mount,
            user: user.clone(),
            assistant: assistant.clone(),
            provider,
            model: model.map(str::to_string),
            control: control.clone(),
        };
        thread::Builder::new().name("ondb-turn".into()).spawn(move || {
            let _guard = guard;
            let r = job.run();
            let _ = tx.send(r);
        })?;
        Ok(Turn { thread: t.id, user: user.id, assistant, done: rx, control })
    }
}

struct BusyGuard {
    inner: Arc<Inner>,
    thread: String,
}

impl Drop for BusyGuard {
    fn drop(&mut self) {
        self.inner.busy.lock().unwrap_or_else(|p| p.into_inner()).remove(&self.thread);
        self.inner.active.lock().unwrap_or_else(|p| p.into_inner()).remove(&self.thread);
    }
}

impl Inner {
    fn emit(&self, u: Update) {
        self.subs.lock().unwrap_or_else(|p| p.into_inner()).retain(|s| s.send(u.clone()).is_ok());
    }

    /// A parked process for `session` (closing one parked with another model).
    fn take_warm(&self, session: &str, model: &Option<String>) -> Option<Box<dyn Run>> {
        let mut warm = self.warm.lock().unwrap_or_else(|p| p.into_inner());
        let i = warm.iter().position(|w| w.session == session)?;
        let mut w = warm.remove(i);
        drop(warm);
        if &w.model == model {
            Some(w.run)
        } else {
            w.run.close();
            None
        }
    }

    fn park(&self, session: String, model: Option<String>, run: Box<dyn Run>) {
        let evicted: Vec<Warm> = {
            let mut warm = self.warm.lock().unwrap_or_else(|p| p.into_inner());
            warm.push(Warm { session, model, run, since: Instant::now() });
            let excess = warm.len().saturating_sub(self.opts.warm_limit);
            warm.drain(..excess).collect()
        };
        for mut w in evicted {
            w.run.close();
        }
        let _ = self.reaper.send(());
    }
}

/// Closes parked processes once idle. Sleeps without a deadline (no
/// wakeups at all) while nothing is parked.
fn reap(inner: Weak<Inner>, wake: Receiver<()>) {
    loop {
        let deadline = {
            let Some(inner) = inner.upgrade() else { return };
            let warm = inner.warm.lock().unwrap_or_else(|p| p.into_inner());
            warm.iter().map(|w| w.since + inner.opts.warm_idle).min()
        };
        let r = match deadline {
            Some(d) => wake.recv_timeout(d.saturating_duration_since(Instant::now())),
            None => wake.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match r {
            Ok(()) => continue,
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }
        let Some(inner) = inner.upgrade() else { return };
        let expired: Vec<Warm> = {
            let mut warm = inner.warm.lock().unwrap_or_else(|p| p.into_inner());
            let now = Instant::now();
            let (gone, keep): (Vec<Warm>, Vec<Warm>) = warm.drain(..).partition(|w| now >= w.since + inner.opts.warm_idle);
            *warm = keep;
            gone
        };
        for mut w in expired {
            w.run.close();
        }
    }
}

struct TurnJob {
    inner: Arc<Inner>,
    thread: String,
    cwd: std::path::PathBuf,
    ws: ondb::Workspace,
    mount: ondb::MountHandle,
    user: Message,
    assistant: String,
    provider: Arc<dyn Provider>,
    model: Option<String>,
    control: Arc<TurnControl>,
}

/// How a turn reaches a provider session.
enum Plan {
    /// Continue `session`, replaying `history[from..]`.
    Continue {
        session: ProviderSession,
        from: usize,
    },
    /// Fork `session` at its native message `at`, replaying `history[from..]`.
    Fork {
        session: ProviderSession,
        at: String,
        from: usize,
    },
    Fresh,
}

impl TurnJob {
    fn plan(&self, history: &[Message]) -> Result<Plan, Error> {
        let caps = self.provider.capabilities();
        let sessions = self.inner.store.sessions(&self.thread)?;
        for (i, m) in history.iter().enumerate().rev() {
            if m.role != Role::Assistant || m.status != Status::Done || m.provider.as_deref() != Some(self.provider.id()) {
                continue;
            }
            let Some(s) = m.session.as_ref().and_then(|id| sessions.iter().find(|s| &s.id == id)) else { continue };
            if s.native.is_none() || !caps.resume {
                continue;
            }
            if s.seen.as_deref() == Some(m.id.as_str()) {
                return Ok(Plan::Continue { session: s.clone(), from: i + 1 });
            }
            if caps.fork_at_message
                && let Some(at) = &m.native
            {
                return Ok(Plan::Fork { session: s.clone(), at: at.clone(), from: i + 1 });
            }
        }
        Ok(Plan::Fresh)
    }

    fn history_prompt(&self, history: &[Message], prompt: &str) -> String {
        if history.is_empty() {
            return prompt.to_string();
        }
        let mut lines: Vec<String> = Vec::new();
        let mut budget = self.inner.opts.history_chars;
        for m in history.iter().rev() {
            let who = match (m.role, &m.provider) {
                (Role::User, _) => "User".to_string(),
                (Role::Assistant, Some(p)) => format!("Assistant ({p})"),
                (Role::Assistant, None) => "Assistant".to_string(),
            };
            let entry = format!("{who}: {}", clip(&m.text, 8_000));
            if entry.len() > budget {
                lines.push("[earlier messages omitted]".into());
                break;
            }
            budget -= entry.len();
            lines.push(entry);
        }
        lines.reverse();
        format!(
            "<previous-conversation>\nThe conversation so far (from another agent session or branch); use it as context.\n\n{}\n</previous-conversation>\n\n{prompt}",
            lines.join("\n\n")
        )
    }

    fn run(self) -> Result<Message, Error> {
        let store = &self.inner.store;
        let path = store.path(&self.user.id)?;
        let history = &path[..path.len().saturating_sub(1)];
        let plan = self.plan(history)?;
        let now = now_ms();
        let fresh_session = |forked_from: Option<String>| ProviderSession {
            id: new_id(),
            thread: self.thread.clone(),
            provider: self.provider.id().to_string(),
            native: None,
            cwd: self.cwd.to_string_lossy().into_owned(),
            seen: None,
            forked_from,
        };
        let (mut session, mut req, from, warm) = match plan {
            Plan::Continue { session, from } => {
                let warm = self.inner.take_warm(&session.id, &self.model);
                let req = StartRequest {
                    cwd: self.cwd.clone(),
                    model: self.model.clone(),
                    resume: session.native.clone(),
                    ..Default::default()
                };
                (session, req, from, warm)
            }
            Plan::Fork { session, at, from } => {
                let forked = fresh_session(Some(session.id.clone()));
                store.insert_session(&forked, now)?;
                let req = StartRequest {
                    cwd: self.cwd.clone(),
                    model: self.model.clone(),
                    resume: session.native.clone(),
                    fork_at: Some(at),
                    ..Default::default()
                };
                (forked, req, from, None)
            }
            Plan::Fresh => {
                let s = fresh_session(None);
                store.insert_session(&s, now)?;
                (s, StartRequest { cwd: self.cwd.clone(), model: self.model.clone(), ..Default::default() }, 0, None)
            }
        };
        let mut full_prompt = self.history_prompt(&history[from.min(history.len())..], &self.user.text);
        store.insert_message(&Message {
            id: self.assistant.clone(),
            thread: self.thread.clone(),
            parent: Some(self.user.id.clone()),
            role: Role::Assistant,
            provider: Some(self.provider.id().to_string()),
            model: self.model.clone(),
            text: String::new(),
            version: None,
            scope: None,
            session: Some(session.id.clone()),
            native: None,
            status: Status::Running,
            error: None,
            created_ms: now_ms(),
        })?;

        let actor = self.ws.actor(self.provider.id(), ActorKind::Agent)?;
        let recorder = Recorder::new(&self.ws, vec![self.mount.clone()])?;
        let turn_scope = recorder.begin(ScopeKind::Turn, &clip(&self.user.text, 80), Some(actor), None)?;
        let turn_scope_id = turn_scope.id();
        let mut warm = warm;
        let mut forking = req.fork_at.is_some();
        let mut text = String::new();
        let mut native: Option<String> = None;
        let mut open_tools: HashMap<String, ondb::Scope> = HashMap::new();
        let mut status: Status;
        let mut error: Option<String>;
        let mut alive: bool;
        let mut run = loop {
            let mut run = match warm.take() {
                Some(r) => r,
                None => match self.provider.start(req) {
                    Ok(r) => r,
                    Err(e) => {
                        let rec = recorder.end(turn_scope)?;
                        self.finish(&session, "", Status::Failed, Some(&e.to_string()), Some(rec.id.to_string()), None)?;
                        return Err(e);
                    }
                },
            };
            *self.control.interrupter.lock().unwrap_or_else(|p| p.into_inner()) = Some(run.interrupter());

            status = Status::Failed;
            error = None;
            alive = true;
            let mut started = false;
            let mut tools_seen = false;
            if let Err(e) = run.send(&full_prompt) {
                error = Some(e.to_string());
                alive = false;
            }
            while alive {
                let Some(ev) = run.next() else {
                    alive = false;
                    if self.control.interrupted.load(Ordering::SeqCst) {
                        status = Status::Interrupted;
                    } else {
                        error.get_or_insert_with(|| "the provider process exited".into());
                    }
                    break;
                };
                store.record_event(
                    &session.id,
                    Some(&self.assistant),
                    now_ms(),
                    ev.kind.name(),
                    ev.native_message.as_deref(),
                    ev.raw.as_deref(),
                )?;
                if let Some(n) = &ev.native_message
                    && !matches!(&ev.kind, EventKind::Other { kind } if kind == "stderr")
                {
                    native = Some(n.clone());
                }
                match ev.kind {
                    EventKind::SessionStarted { native_id } => {
                        started = true;
                        store.update_session(&session.id, Some(&native_id), None, now_ms())?
                    }
                    EventKind::TextDelta { text: t } => {
                        self.inner
                            .live
                            .lock()
                            .unwrap_or_else(|p| p.into_inner())
                            .entry(self.assistant.clone())
                            .or_default()
                            .push_str(&t);
                        self.inner.emit(Update::TextDelta {
                            thread: self.thread.clone(),
                            message: self.assistant.clone(),
                            text: t,
                        });
                    }
                    EventKind::ReasoningDelta { text: t } => {
                        self.inner.emit(Update::ReasoningDelta {
                            thread: self.thread.clone(),
                            message: self.assistant.clone(),
                            text: t,
                        });
                    }
                    EventKind::Text { text: t } => {
                        if !text.is_empty() {
                            text.push_str("\n\n");
                        }
                        text.push_str(&t);
                        // The complete block replaces what was streamed of it.
                        self.inner
                            .live
                            .lock()
                            .unwrap_or_else(|p| p.into_inner())
                            .insert(self.assistant.clone(), format!("{text}\n\n"));
                        self.inner.emit(Update::Text { thread: self.thread.clone(), message: self.assistant.clone(), text: t });
                    }
                    EventKind::ToolStarted { id, name, input } => {
                        tools_seen = true;
                        let scope = recorder.begin(ScopeKind::ToolCall, &name, Some(actor), Some(turn_scope_id))?;
                        store.start_tool(&ToolCall {
                            message: self.assistant.clone(),
                            id: id.clone(),
                            session: session.id.clone(),
                            name: name.clone(),
                            input: input.to_string(),
                            output: None,
                            stdout: None,
                            stderr: None,
                            is_error: None,
                            scope: Some(scope.id().to_string()),
                            started_ms: now_ms(),
                            ended_ms: None,
                        })?;
                        open_tools.insert(id.clone(), scope);
                        self.inner.emit(Update::ToolStarted {
                            thread: self.thread.clone(),
                            message: self.assistant.clone(),
                            id,
                            name,
                        });
                    }
                    EventKind::ToolFinished { id, output, is_error, stdout, stderr } => {
                        let scope = match open_tools.remove(&id) {
                            Some(s) => Some(recorder.end(s)?.id.to_string()),
                            None => None,
                        };
                        store.finish_tool(
                            &self.assistant,
                            &id,
                            &output,
                            stdout.as_deref(),
                            stderr.as_deref(),
                            is_error,
                            scope.as_deref(),
                            now_ms(),
                        )?;
                        self.inner.emit(Update::ToolFinished {
                            thread: self.thread.clone(),
                            message: self.assistant.clone(),
                            id,
                            is_error,
                        });
                    }
                    EventKind::TurnEnded { ok, error: e } => {
                        status = if self.control.interrupted.load(Ordering::SeqCst) {
                            Status::Interrupted
                        } else if ok {
                            Status::Done
                        } else {
                            Status::Failed
                        };
                        error = e;
                        break;
                    }
                    _ => {}
                }
            }
            // A native fork the provider refused before starting (e.g. it no
            // longer has the fork point): fall back to a fresh session with the
            // branch's history replayed, once.
            if forking && !started && !tools_seen && status == Status::Failed && text.is_empty() {
                tracing::warn!(error = ?error, "native fork failed; starting a fresh session");
                run.close();
                forking = false;
                session = fresh_session(None);
                store.insert_session(&session, now_ms())?;
                req = StartRequest { cwd: self.cwd.clone(), model: self.model.clone(), ..Default::default() };
                full_prompt = self.history_prompt(history, &self.user.text);
                continue;
            }
            break run;
        };
        for (_, s) in open_tools.drain() {
            recorder.end(s)?;
        }
        let streamed = self.inner.live.lock().unwrap_or_else(|p| p.into_inner()).remove(&self.assistant);
        if text.is_empty()
            && let Some(s) = streamed
        {
            text = s.trim_end().to_string();
        }
        // Providers often explain a failure in the turn's text (limits,
        // auth); keep that with the error code.
        if status == Status::Failed && !text.is_empty() {
            error = Some(match error {
                Some(code) if !text.contains(&code) => format!("{code}: {}", clip(&text, 500)),
                _ => clip(&text, 500),
            });
        }
        let rec = recorder.end(turn_scope)?;
        let message = self.finish(&session, &text, status, error.as_deref(), Some(rec.id.to_string()), native.as_deref())?;
        if alive && status == Status::Done && self.provider.capabilities().persistent {
            self.inner.park(session.id.clone(), self.model.clone(), run);
        } else {
            run.close();
        }
        Ok(message)
    }

    fn finish(
        &self,
        session: &ProviderSession,
        text: &str,
        status: Status,
        error: Option<&str>,
        scope: Option<String>,
        native: Option<&str>,
    ) -> Result<Message, Error> {
        let store = &self.inner.store;
        let version = self.ws.heads();
        store.finish_message(&self.assistant, text, status, error, Some(&version), scope.as_deref(), native, &session.id)?;
        if status == Status::Done {
            store.update_session(&session.id, None, Some(&self.assistant), now_ms())?;
        }
        store.set_leaf(&self.thread, &self.assistant)?;
        self.inner.emit(Update::TurnEnded { thread: self.thread.clone(), message: self.assistant.clone(), status });
        store.message(&self.assistant)?.ok_or_else(|| Error::Invalid("assistant message vanished".into()))
    }
}
