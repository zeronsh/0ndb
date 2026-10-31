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

#[derive(Clone, Debug, PartialEq, serde::Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Update {
    /// Restoring a message moved git back to where it was then: onto
    /// `branch` (`created` when 0ndb had to make it), or detached.
    GitMoved {
        thread: String,
        branch: Option<String>,
        commit: String,
        created: bool,
    },
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

/// Characters of one replayed message, and of one replayed tool output.
const HISTORY_MESSAGE_CHARS: usize = 8_000;
const HISTORY_TOOL_OUTPUT_CHARS: usize = 600;

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

    /// Picks up turns a crash cut short, as zeron does: each reply found
    /// running when the store opened that is recent (12 h) and hasn't been
    /// revived 3 times in a row is re-run against the same provider
    /// session with its prompt, the new reply continuing the interrupted
    /// one (so the transcript stays linear). Call once at startup from a
    /// long-running host; returns the resumed turns.
    pub fn resume_interrupted(&self) -> Vec<Turn> {
        const MAX_RESUMES: usize = 3;
        const FRESH_MS: u64 = 12 * 60 * 60 * 1000;
        let store = &self.inner.store;
        let mut out = Vec::new();
        for id in store.take_interrupted() {
            let resumed = (|| -> Result<Option<Turn>, Error> {
                let Some(msg) = store.message(&id)? else { return Ok(None) };
                let path = store.path(&id)?;
                // Consecutive revivals: interrupted replies directly above.
                let revivals = path.iter().rev().skip(1).take_while(|m| m.role == Role::Assistant).count();
                let Some(user) = path.iter().rev().find(|m| m.role == Role::User).cloned() else { return Ok(None) };
                let fresh = now_ms().saturating_sub(msg.created_ms) < FRESH_MS;
                let Some(provider) = msg.provider.as_deref().and_then(|p| self.inner.providers.get(p)).cloned() else {
                    return Ok(None);
                };
                if msg.role != Role::Assistant || !fresh || revivals >= MAX_RESUMES {
                    return Ok(None);
                }
                if !self.inner.busy.lock().unwrap_or_else(|p| p.into_inner()).insert(msg.thread.clone()) {
                    return Ok(None);
                }
                let guard = BusyGuard { inner: self.inner.clone(), thread: msg.thread.clone() };
                let t = self.thread(&msg.thread)?;
                let wt =
                    self.inner.worktrees.get(&t.worktree).ok_or_else(|| Error::Invalid(format!("no worktree {}", t.worktree)))?;
                let (ws, mount) = self
                    .inner
                    .worktrees
                    .workspace(&wt.id)
                    .ok_or_else(|| Error::Invalid(format!("worktree {} isn't mounted", wt.id)))?;
                mount.fence()?;
                store.set_error(&id, "interrupted by a restart; resumed below")?;
                let turn =
                    self.launch(&t.id, wt.path.clone(), ws, mount, user, id.clone(), provider, msg.model.as_deref(), guard)?;
                Ok(Some(turn))
            })();
            match resumed {
                Ok(Some(t)) => out.push(t),
                Ok(None) => {}
                Err(e) => tracing::warn!(message = %id, error = %e, "resuming an interrupted turn failed"),
            }
        }
        out
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
    /// branch, the worktree's files become exactly what they were when the
    /// original was sent, and the agent runs from there.
    pub fn edit(&self, message: &str, prompt: &str, provider: &str, model: Option<&str>) -> Result<Turn, Error> {
        let m = self.message(message)?;
        if m.role != Role::User {
            return Err(Error::Invalid("only user messages can be edited".into()));
        }
        let t = self.thread(&m.thread)?;
        self.check_idle(&t.id)?;
        self.restore(&t, &m)?;
        self.start_turn(&t.id, m.parent.clone(), prompt, provider, model)
    }

    /// Selects the branch through `message` (its most recent continuation);
    /// the worktree's files become exactly that branch's last state.
    pub fn switch_branch(&self, message: &str) -> Result<Message, Error> {
        let mut leaf = self.message(message)?;
        let t = self.thread(&leaf.thread)?;
        self.check_idle(&t.id)?;
        while let Some(next) = self.inner.store.children(&t.id, Some(&leaf.id))?.pop() {
            leaf = next;
        }
        self.restore(&t, &leaf)?;
        self.inner.store.set_leaf(&t.id, &leaf.id)?;
        Ok(leaf)
    }

    fn check_idle(&self, thread: &str) -> Result<(), Error> {
        if self.inner.busy.lock().unwrap_or_else(|p| p.into_inner()).contains(thread) {
            return Err(Error::Busy(thread.into()));
        }
        Ok(())
    }

    /// Makes the worktree exactly what it was at `target`: its files, and
    /// git's position. One fixed rule, so branches are predictable:
    /// everything since is undone, people's edits included. When git has
    /// moved since (another branch, or commits), HEAD goes back to that
    /// commit on its branch if the branch still points there, otherwise on
    /// a new `ondb/<thread>` branch made at it; existing branches are never
    /// moved or deleted. If git is where it was, git checkouts in between
    /// are kept (as before).
    fn restore(&self, thread: &Thread, target: &Message) -> Result<(), Error> {
        let Some(version) = target.version.as_ref() else { return Ok(()) };
        let wt = self
            .inner
            .worktrees
            .get(&thread.worktree)
            .ok_or_else(|| Error::Invalid(format!("no worktree {}", thread.worktree)))?;
        let (ws, mount) = self
            .inner
            .worktrees
            .workspace(&thread.worktree)
            .ok_or_else(|| Error::Invalid(format!("worktree {} isn't mounted", thread.worktree)))?;
        mount.fence()?;
        // Decide (and check) the git move before touching any file.
        let git_move = self.git_move(&wt.path, thread, target)?;
        let restorer = ws.actor("restore", ActorKind::Agent)?;
        let mut undo = HashSet::new();
        for b in ws.batches_missing_from(version)? {
            let id = b.id();
            let s = ws.summary(&id)?;
            if s.is_annotation_only() || (s.git_checkout && git_move.is_none()) {
                continue;
            }
            undo.insert(id);
        }
        if ondb::revert::revert_batches(&ws, restorer, &undo)?.is_some() {
            mount.fence()?;
        }
        if let Some(m) = git_move {
            let repo = ondb::git::Repo::open(&wt.path)?;
            if m.create {
                repo.create_branch(m.branch.as_deref().expect("created branches have names"), &m.commit)?;
            }
            let reason = format!("moving to {} (0ndb restored a message)", m.branch.as_deref().unwrap_or(&m.commit));
            repo.move_head(m.branch.as_deref(), &m.commit, &reason)?;
            mount.fence()?;
            self.inner.emit(Update::GitMoved {
                thread: thread.id.clone(),
                branch: m.branch,
                commit: m.commit,
                created: m.create,
            });
        }
        Ok(())
    }

    /// Where git must go to be where it was at `target`, or `None` if it is
    /// already there (or the message predates git tracking).
    fn git_move(&self, path: &std::path::Path, thread: &Thread, target: &Message) -> Result<Option<GitMove>, Error> {
        let Some(commit) = target.git_commit.clone() else { return Ok(None) };
        let Ok(repo) = ondb::git::Repo::open(path) else { return Ok(None) };
        let head = repo.head()?;
        if head.oid.as_deref() == Some(commit.as_str()) && head.branch == target.git_branch {
            return Ok(None);
        }
        if let Some(op) = repo.operation() {
            return Err(Error::Invalid(format!("a git {op} is in progress; finish or abort it first")));
        }
        if !repo.commit_exists(&commit)? {
            return Err(Error::Invalid(format!(
                "the commit this message was on ({}) no longer exists",
                &commit[..commit.len().min(12)]
            )));
        }
        Ok(Some(match &target.git_branch {
            None => GitMove { branch: None, commit, create: false },
            Some(b) if repo.branch_tip(b)?.as_deref() == Some(commit.as_str()) && !repo.branch_checked_out_elsewhere(b)? => {
                GitMove { branch: Some(b.clone()), commit, create: false }
            }
            Some(_) => GitMove { branch: Some(repo.unique_branch("ondb/", &thread.title)?), commit, create: true },
        }))
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
        let git_at = git_head(&wt.path);
        let user = Message {
            id: new_id(),
            thread: t.id.clone(),
            parent,
            role: Role::User,
            provider: None,
            model: None,
            text: prompt.to_string(),
            version: Some(ws.heads()),
            git_branch: git_at.branch,
            git_commit: git_at.oid,
            scope: None,
            session: None,
            native: None,
            status: Status::Done,
            error: None,
            created_ms: now_ms(),
            switched_from: None,
        };
        self.inner.store.insert_message(&user)?;
        self.inner.store.set_leaf(&t.id, &user.id)?;
        // A thread's first message (on each root branch) is the oldest
        // version it can navigate back to; keep it from being pruned.
        if user.parent.is_none() {
            ws.retain(&format!("thread:{}:{}", t.id, user.id), user.version.as_ref())?;
        }
        let reply_to = user.id.clone();
        self.launch(&t.id, wt.path.clone(), ws, mount, user, reply_to, provider, model, guard)
    }

    /// Runs a turn for `user`, its reply placed under `reply_to` (the user
    /// message, or the interrupted reply a resumed turn continues).
    #[allow(clippy::too_many_arguments)]
    fn launch(
        &self,
        thread: &str,
        cwd: std::path::PathBuf,
        ws: ondb::Workspace,
        mount: ondb::MountHandle,
        user: Message,
        reply_to: String,
        provider: Arc<dyn Provider>,
        model: Option<&str>,
        guard: BusyGuard,
    ) -> Result<Turn, Error> {
        let t = self.thread(thread)?;
        let assistant = new_id();
        let control = Arc::new(TurnControl::default());
        self.inner.active.lock().unwrap_or_else(|p| p.into_inner()).insert(t.id.clone(), control.clone());
        self.inner.emit(Update::TurnStarted { thread: t.id.clone(), user: user.id.clone(), message: assistant.clone() });
        let (tx, rx) = bounded(1);
        let job = TurnJob {
            inner: self.inner.clone(),
            thread: t.id.clone(),
            cwd,
            ws,
            mount,
            user: user.clone(),
            reply_to,
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

/// How `restore` moves git (see `Sessions::git_move`).
struct GitMove {
    branch: Option<String>,
    commit: String,
    create: bool,
}

/// Where git is in `path` (nothing outside a repository).
fn git_head(path: &std::path::Path) -> ondb::git::Head {
    ondb::git::Repo::open(path).and_then(|r| r.head()).unwrap_or(ondb::git::Head { branch: None, oid: None })
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
    /// The reply's parent: `user`, or the interrupted reply being resumed.
    reply_to: String,
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
            // Owner-gated (above) and cwd-gated: provider session stores are
            // keyed by directory, so one made elsewhere is never resumed.
            if s.native.is_none() || !caps.resume || s.cwd != self.cwd.to_string_lossy() {
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

    /// `prompt` with what the chosen session hasn't seen in front of it
    /// (zeron's replay rules): nothing for native commands (`/name`) or when
    /// it has seen everything; otherwise the missing messages, tool calls
    /// included with clipped output, newest first within the budget, under
    /// an intro saying why they're there.
    fn history_prompt(&self, history: &[Message], prompt: &str, continued: bool) -> String {
        if history.is_empty() || prompt.trim_start().starts_with('/') {
            return prompt.to_string();
        }
        let me = self.provider.id();
        let entries: Vec<String> = history
            .iter()
            .filter_map(|m| {
                let mut text = m.text.clone();
                if m.role == Role::Assistant {
                    for tc in self.inner.store.tool_calls(&m.id).unwrap_or_default() {
                        let out = tc.output.as_deref().unwrap_or("");
                        text.push_str(&format!("\nTool: {} {}\n{}", tc.name, tc.input, clip(out, HISTORY_TOOL_OUTPUT_CHARS)));
                    }
                }
                let text = clip(text.trim(), HISTORY_MESSAGE_CHARS);
                (!text.is_empty()).then(|| {
                    let role = if m.role == Role::User { "user" } else { "assistant" };
                    serde_json::json!({ "role": role, "provider": m.provider, "text": text }).to_string()
                })
            })
            .collect();
        let mut budget = self.inner.opts.history_chars;
        let kept = entries
            .iter()
            .rev()
            .take_while(|e| {
                let fits = e.len() <= budget;
                budget = budget.saturating_sub(e.len());
                fits
            })
            .count()
            .max(1.min(entries.len()));
        let omitted = entries.len() - kept;
        if kept == 0 {
            return prompt.to_string();
        }
        let other = history.iter().any(|m| m.role == Role::Assistant && m.provider.as_deref().is_some_and(|p| p != me));
        let intro = if continued && other {
            "While you were away, this conversation continued with a different AI provider. The messages you missed are below; answer the final request as the continuation of the whole conversation. Tool calls listed below ran on the other provider; do not assume their state is still live."
        } else if other {
            "This conversation was started with a different AI provider and you are now taking over. The earlier messages are below as context; answer the final request as the continuation of that conversation. Tool calls listed below ran on the previous provider; do not assume their state is still live."
        } else {
            "This conversation continues in a new session (a branch, or a session that could not be resumed). The earlier messages are below as context; answer the final request as the continuation of that conversation."
        };
        let note = if omitted > 0 { format!("({omitted} earlier messages omitted for length.)\n") } else { String::new() };
        format!("{intro}\n{note}<conversation>\n{}\n</conversation>\n\n{prompt}", entries[omitted..].join("\n"))
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
        let continued = from > 0;
        let mut full_prompt = self.history_prompt(&history[from.min(history.len())..], &self.user.text, continued);
        // The seam: the provider this reply takes over from, if it changed.
        let switched_from = history
            .iter()
            .rev()
            .find(|m| m.role == Role::Assistant)
            .and_then(|m| m.provider.clone())
            .filter(|p| p != self.provider.id());
        store.insert_message(&Message {
            id: self.assistant.clone(),
            thread: self.thread.clone(),
            parent: Some(self.reply_to.clone()),
            role: Role::Assistant,
            provider: Some(self.provider.id().to_string()),
            model: self.model.clone(),
            git_branch: None,
            git_commit: None,
            text: String::new(),
            version: None,
            scope: None,
            session: Some(session.id.clone()),
            native: None,
            status: Status::Running,
            error: None,
            created_ms: now_ms(),
            switched_from,
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
                full_prompt = self.history_prompt(history, &self.user.text, false);
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
        let git_at = git_head(&self.cwd);
        store.set_git(&self.assistant, git_at.branch.as_deref(), git_at.oid.as_deref())?;
        if status == Status::Done {
            store.update_session(&session.id, None, Some(&self.assistant), now_ms())?;
        }
        store.set_leaf(&self.thread, &self.assistant)?;
        self.inner.emit(Update::TurnEnded { thread: self.thread.clone(), message: self.assistant.clone(), status });
        store.message(&self.assistant)?.ok_or_else(|| Error::Invalid("assistant message vanished".into()))
    }
}
