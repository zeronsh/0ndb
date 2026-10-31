//! Binds a history to a directory on disk.
//!
//! * Disk → history: a recursive watcher feeds changed paths into a debounced
//!   reconcile pass that compares disk against the *shadow* (what the mount
//!   last synced) and records the difference as one batch authored by the
//!   mount's ingestion actor, parented on the version the disk reflected.
//!   Edits made while remote changes were landing therefore merge through
//!   the CRDT instead of overwriting them.
//! * History → disk: changes from other actors (remote replicas, tools,
//!   reverts) are materialized with atomic writes, but only after verifying
//!   the disk still matches the shadow; un-ingested local edits are ingested
//!   first.
//! * Fences: a marker file written into the watched tree proves every event
//!   before it has been delivered and ingested, which is what lets callers
//!   attribute a command's disk effects to exactly that command.

mod disk;
mod git;
pub(crate) use git::GitObjects;
mod ignore;
mod ingest;
mod materialize;
mod shadow;
mod watch;

use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender, bounded, never, select, unbounded};
use ondb_core::{ActorId, BatchId, Version};
use ondb_store::{MountRecord, Origin};
use watch::Watch;

use crate::Error;
use crate::workspace::{ActorKind, Event, Workspace};

pub use disk::{STATE_DIR, TEMP_PREFIX, smudge};
use git::GitDirs;
use ignore::Ignore;
use shadow::Shadow;

#[derive(Clone, Debug)]
pub struct MountOptions {
    /// Quiet period after the last event before reconciling.
    pub debounce: Duration,
    /// Upper bound on how long a change waits while events keep arriving.
    pub max_latency: Duration,
    /// Files larger than this are not tracked.
    pub max_file_size: u64,
    /// How long to wait for git to release `index.lock` before reconciling
    /// anyway (avoids ingesting half-finished checkouts).
    pub git_settle: Duration,
    /// How long a fence waits for its marker before falling back to a full
    /// rescan.
    pub fence_timeout: Duration,
    /// Background passes skip files modified more recently than this, so a
    /// program's temp files and half-written output are never recorded.
    /// Fences, tool writes and shutdown ingest everything regardless.
    pub settle: Duration,
    /// After this long without activity the mount hibernates: its in-memory
    /// state and the history's are dropped and reloaded on the next change.
    /// Memory then scales with active worktrees, not mounted ones. `None`
    /// keeps everything resident.
    pub idle_unload: Option<Duration>,
    /// In a git checkout, reference content the repository's object database
    /// already holds instead of copying it into the store (pinned under
    /// `refs/0ndb/<history>` so git never garbage-collects it).
    pub git_objects: bool,
}

impl Default for MountOptions {
    fn default() -> Self {
        MountOptions {
            debounce: Duration::from_millis(40),
            max_latency: Duration::from_millis(400),
            max_file_size: 16 << 20,
            git_settle: Duration::from_secs(2),
            fence_timeout: Duration::from_secs(2),
            settle: Duration::from_millis(100),
            idle_unload: Some(Duration::from_secs(30)),
            git_objects: true,
        }
    }
}

#[derive(Clone, Debug)]
pub struct FenceOutcome {
    /// Version after every change preceding the fence was ingested.
    pub version: Version,
    /// The marker never arrived; a full rescan was used instead.
    pub rescanned: bool,
    /// Git still held its index lock; a checkout may be mid-flight.
    pub git_busy: bool,
}

impl FenceOutcome {
    pub fn settled(&self) -> bool {
        !self.git_busy
    }
}

type Reply<T> = Sender<Result<T, Error>>;

enum Cmd {
    Fence { reply: Reply<FenceOutcome> },
    Write { actor: ActorId, path: String, bytes: Vec<u8>, exec: Option<bool>, reply: Reply<Option<BatchId>> },
    Remove { actor: ActorId, path: String, reply: Reply<Option<BatchId>> },
    Rename { actor: ActorId, from: String, to: String, reply: Reply<Option<BatchId>> },
    Stop { reply: Sender<()> },
}

/// Cloneable handle to a running mount.
#[derive(Clone)]
pub struct MountHandle {
    root: PathBuf,
    ingestion_actor: ActorId,
    cmd: Sender<Cmd>,
}

impl MountHandle {
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The actor that authors changes discovered on disk.
    pub fn ingestion_actor(&self) -> ActorId {
        self.ingestion_actor
    }

    fn call<T>(&self, make: impl FnOnce(Reply<T>) -> Cmd) -> Result<T, Error> {
        let (tx, rx) = bounded(1);
        self.cmd.send(make(tx)).map_err(|_| Error::MountStopped)?;
        rx.recv().map_err(|_| Error::MountStopped)?
    }

    /// Returns once every filesystem change made before the call has been
    /// ingested.
    pub fn fence(&self) -> Result<FenceOutcome, Error> {
        self.call(|reply| Cmd::Fence { reply })
    }

    /// Writes a file as `actor` (an edit tool), recording the change under
    /// that actor rather than as an ingested disk change.
    pub fn write_file(&self, actor: ActorId, path: &str, bytes: Vec<u8>) -> Result<Option<BatchId>, Error> {
        self.call(|reply| Cmd::Write { actor, path: path.to_string(), bytes, exec: None, reply })
    }

    pub fn write_file_with_mode(&self, actor: ActorId, path: &str, bytes: Vec<u8>, exec: bool) -> Result<Option<BatchId>, Error> {
        self.call(|reply| Cmd::Write { actor, path: path.to_string(), bytes, exec: Some(exec), reply })
    }

    pub fn remove(&self, actor: ActorId, path: &str) -> Result<Option<BatchId>, Error> {
        self.call(|reply| Cmd::Remove { actor, path: path.to_string(), reply })
    }

    pub fn rename(&self, actor: ActorId, from: &str, to: &str) -> Result<Option<BatchId>, Error> {
        self.call(|reply| Cmd::Rename { actor, from: from.to_string(), to: to.to_string(), reply })
    }
}

pub struct Mount {
    handle: MountHandle,
    thread: Option<JoinHandle<()>>,
}

impl Mount {
    /// Mounts `root`: adopts or reconciles what's on disk, materializes what
    /// changed while unmounted, then watches for changes.
    pub fn start(ws: &Workspace, root: impl AsRef<Path>, opts: MountOptions) -> Result<Mount, Error> {
        let root = fs::canonicalize(root.as_ref())?;
        let root_key = root.to_string_lossy().into_owned();
        fs::create_dir_all(root.join(STATE_DIR).join("fences"))?;
        let git = GitDirs::locate(&root);
        exclude_state_dir(git.as_ref());
        // One live mount per (history, directory): a second mount of the same
        // history would ingest every disk change twice, which the CRDT keeps
        // as two concurrent inserts. Other histories may share the directory;
        // each sees the other's writes as an ordinary external process.
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(root.join(STATE_DIR).join(format!("mount-{}.lock", ws.id())))?;
        // A just-released lock can linger for a moment while a forked child
        // that inherited the descriptor is still exec'ing, so retry briefly.
        let deadline = Instant::now() + Duration::from_millis(500);
        while lock.try_lock().is_err() {
            if Instant::now() >= deadline {
                return Err(Error::Invalid(format!("{root_key} is already mounted for history {}", ws.id())));
            }
            std::thread::sleep(Duration::from_millis(10));
        }

        let existing = ws.with(|c| c.store().0.mount_record(&root_key))?;
        let (record, shadow, adopting) = match existing {
            Some(r) if r.history != ws.id() => {
                return Err(Error::Invalid(format!("{root_key} is mounted by history {}", r.history)));
            }
            Some(r) => {
                let rows = ws.with(|c| c.store().0.mount_entries(&root_key))?;
                (r, Shadow::from_rows(rows), false)
            }
            None => {
                let actor = ws.actor(&format!("disk:{root_key}"), ActorKind::Ingestion)?;
                let record = MountRecord {
                    root: root_key.clone(),
                    history: ws.id(),
                    ingestion_actor: actor,
                    synced_version: ws.heads(),
                    git_head: None,
                    git_reflog: None,
                };
                ws.with(|c| {
                    let (store, key) = c.store();
                    store.save_mount_record(key, &record)
                })?;
                (record, Shadow::default(), true)
            }
        };

        let objects = match &git {
            Some(g) if opts.git_objects => {
                let pin_ref = format!("refs/0ndb/{}", ws.id());
                let objects = Arc::new(git::GitObjects(ondb_git::Objects::open(&g.dir).pin_to(&pin_ref)));
                // The common dir outlives linked worktrees, so workspaces
                // opened later (without a mount) still find the content.
                let common = g.common.to_string_lossy().into_owned();
                ws.with(|c| {
                    let (store, key) = c.store();
                    store.set_external_record(key, "git", &common, &pin_ref)
                })?;
                ws.set_objects(Some(objects.clone()))?;
                Some(objects)
            }
            _ => None,
        };
        let (fs_tx, fs_rx) = unbounded();
        let ignore = Ignore::load(&root, git.as_ref());
        // A linked worktree's HEAD lives outside the mount; Watch covers it.
        let watcher = Watch::start(&root, git.as_ref(), &ignore, fs_tx)?;

        let mut state = MountState {
            ws: ws.clone(),
            ignore,
            git,
            objects,
            root: root.clone(),
            opts,
            record,
            shadow,
            git_head: None,
            git_index: None,
            index_stamp: None,
            reflog_pos: 0,
            fence_seq: 0,
            settling: false,
            deferred: BTreeSet::new(),
            hibernating: false,
            ignored_tracked: HashSet::new(),
            ignore_changed: false,
            _lock: lock,
        };
        // Resume from the HEAD this folder was last reconciled against, so
        // git work done while unmounted is still recognized as git's.
        state.git_head = state.record.git_head.clone().or_else(|| state.read_git_head());
        let t = Instant::now();
        if state.git_head == state.read_git_head() {
            state.snapshot_git();
        }
        crate::timing::add("start.snapshot_git", t.elapsed());
        if let Some(pos) = state.record.git_reflog {
            state.reflog_pos = pos;
        }
        let t = Instant::now();
        if adopting {
            state.adopt()?;
        } else {
            state.validate_shadow();
        }
        crate::timing::add("start.adopt/validate", t.elapsed());
        let t = Instant::now();
        state.reconcile(ingest::Scope::Full)?;
        crate::timing::add("start.reconcile", t.elapsed());
        let t = Instant::now();
        if adopting {
            state.materialize_all()?;
        } else {
            state.materialize()?;
        }
        crate::timing::add("start.materialize", t.elapsed());

        let ws_rx = ws.subscribe();
        let (cmd_tx, cmd_rx) = unbounded();
        let handle = MountHandle { root, ingestion_actor: state.record.ingestion_actor, cmd: cmd_tx };
        let thread =
            std::thread::Builder::new().name("0ndb-mount".into()).spawn(move || run(state, watcher, fs_rx, ws_rx, cmd_rx))?;
        Ok(Mount { handle, thread: Some(thread) })
    }

    pub fn handle(&self) -> MountHandle {
        self.handle.clone()
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        if let Some(t) = self.thread.take() {
            let (tx, rx) = bounded(1);
            if self.handle.cmd.send(Cmd::Stop { reply: tx }).is_ok() {
                let _ = rx.recv();
            }
            let _ = t.join();
        }
    }
}

impl std::ops::Deref for Mount {
    type Target = MountHandle;
    fn deref(&self) -> &MountHandle {
        &self.handle
    }
}

impl Drop for Mount {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Keeps the state directory out of git without touching tracked files.
fn exclude_state_dir(git: Option<&GitDirs>) {
    let Some(git) = git else { return };
    let exclude = git.exclude();
    let line = format!("/{STATE_DIR}/");
    if fs::read_to_string(&exclude).is_ok_and(|s| s.lines().any(|l| l.trim() == line)) {
        return;
    }
    let _ = fs::create_dir_all(git.common.join("info"));
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&exclude) {
        let _ = writeln!(f, "{line}");
    }
}

pub(crate) struct MountState {
    ws: Workspace,
    root: PathBuf,
    opts: MountOptions,
    record: MountRecord,
    shadow: Shadow,
    ignore: Ignore,
    git: Option<GitDirs>,
    /// The repository's object database, when content is referenced there.
    objects: Option<Arc<git::GitObjects>>,
    git_head: Option<String>,
    /// The index as of the last pass, to tell which files git just wrote.
    git_index: Option<git::CompactIndex>,
    index_stamp: Option<(std::time::SystemTime, u64)>,
    /// HEAD reflog length as of the last pass.
    reflog_pos: u64,
    fence_seq: u64,
    /// Set during background passes: young files are deferred.
    settling: bool,
    /// Paths deferred by the last settling pass.
    deferred: BTreeSet<String>,
    /// The shadow is unloaded (see `MountOptions::idle_unload`).
    hibernating: bool,
    /// While hibernating: tracked paths that ignore rules match, whose events
    /// must still wake the mount.
    ignored_tracked: HashSet<String>,
    /// Set when ignore rules were reloaded, so watches can follow.
    ignore_changed: bool,
    /// Held for the mount's lifetime; one live mount per directory.
    _lock: fs::File,
}

impl MountState {
    /// Drops the shadow and the history's in-memory state. The git index
    /// baseline (compact) and ignore rules stay, so events can still be
    /// filtered and git operations classified without waking.
    fn hibernate(&mut self) -> Result<(), Error> {
        if self.hibernating {
            return Ok(());
        }
        self.persist()?;
        self.ignored_tracked =
            self.shadow.paths().filter(|p| self.ignore.is_ignored(p, self.shadow.is_dir(p))).cloned().collect();
        self.shadow = Shadow::default();
        self.hibernating = true;
        self.ws.hibernate();
        tracing::debug!(root = %self.root.display(), "mount hibernating");
        Ok(())
    }

    /// Reloads what `hibernate` dropped.
    pub(super) fn wake(&mut self) -> Result<(), Error> {
        if !self.hibernating {
            return Ok(());
        }
        let root = self.record.root.clone();
        let rows = self.ws.with(|c| c.store().0.mount_entries(&root))?;
        self.shadow = Shadow::from_rows(rows);
        self.ignored_tracked = HashSet::new();
        self.hibernating = false;
        Ok(())
    }

    /// Whether an event at `rel` can matter: ignored paths that aren't
    /// tracked are dropped here, so build output never costs a pass.
    fn relevant(&self, rel: &str) -> bool {
        // Directory-only rules (`target/`) need the entry's kind; stat only
        // when the two answers differ.
        if !self.ignore.is_ignored(rel, false) && (!self.ignore.is_ignored(rel, true) || !self.root.join(rel).is_dir()) {
            return true;
        }
        if self.hibernating { self.ignored_tracked.contains(rel) } else { self.shadow.get(rel).is_some() }
    }

    fn persist(&mut self) -> Result<(), Error> {
        let (upserts, removals) = self.shadow.take_changes();
        self.record.git_head = self.git_head.clone();
        self.record.git_reflog = self.git.as_ref().map(|_| self.reflog_pos);
        let record = self.record.clone();
        self.ws.with(|c| {
            let (store, key) = c.store();
            store.update_mount(key, &record, &upserts, &removals)
        })?;
        Ok(())
    }

    fn read_git_head(&self) -> Option<String> {
        self.git.as_ref()?.head()
    }

    /// Records the index and reflog position as the baseline for the next
    /// pass.
    fn snapshot_git(&mut self) {
        let Some(g) = &self.git else { return };
        self.reflog_pos = g.reflog_len();
        let stamp = g.index_stamp();
        if stamp != self.index_stamp || self.git_index.is_none() {
            self.git_index = git::read_index(&self.root).as_ref().map(git::compact);
            self.index_stamp = stamp;
        }
    }

    /// Like `snapshot_git`, with an index the caller just read.
    fn adopt_git_index(&mut self, index: Option<git::CompactIndex>) {
        let Some(g) = &self.git else { return };
        self.reflog_pos = g.reflog_len();
        self.index_stamp = g.index_stamp();
        self.git_index = index;
    }

    /// Waits (bounded) for git to finish an operation. Returns whether git
    /// is still busy.
    fn settle_git(&self) -> bool {
        let Some(git) = &self.git else { return false };
        let deadline = Instant::now() + self.opts.git_settle;
        while git.busy() {
            if Instant::now() >= deadline {
                tracing::warn!(root = %self.root.display(), "git did not settle; reconciling anyway");
                return true;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        false
    }

    fn write_fence_marker(&mut self) -> std::io::Result<String> {
        self.fence_seq += 1;
        // Unique per mount: other mounts of this directory (other histories,
        // possibly in this process) must not mistake it for their own.
        let rel = format!("{STATE_DIR}/fences/{}-{}-{}", self.record.history, std::process::id(), self.fence_seq);
        fs::create_dir_all(self.root.join(STATE_DIR).join("fences"))?;
        fs::write(self.root.join(&rel), b"")?;
        Ok(rel)
    }

    fn rel(&self, path: &Path) -> Option<String> {
        let rel = path.strip_prefix(&self.root).ok()?;
        Some(rel.to_string_lossy().into_owned())
    }

    fn fence_outcome(&self, rescanned: bool, git_busy: bool) -> FenceOutcome {
        FenceOutcome { version: self.ws.heads(), rescanned, git_busy }
    }
}

struct PendingFence {
    marker: String,
    deadline: Instant,
    arrived: bool,
    reply: Reply<FenceOutcome>,
}

/// Folds an event into the pending work. Returns whether anything relevant
/// happened (filtered events neither schedule a pass nor count as activity).
fn absorb(
    st: &MountState,
    event: &notify::Event,
    pending: &mut BTreeSet<String>,
    rescan: &mut bool,
    fences: &mut [PendingFence],
) -> bool {
    let mut relevant = false;
    if event.need_rescan() {
        *rescan = true;
        relevant = true;
    }
    for p in &event.paths {
        if st.git.as_ref().is_some_and(|g| g.signals(p)) {
            pending.insert(String::new());
            relevant = true;
            continue;
        }
        let Some(rel) = st.rel(p) else { continue };
        if let Some(f) = fences.iter_mut().find(|f| f.marker == rel) {
            f.arrived = true;
            relevant = true;
        } else if !disk::is_internal(&rel) && st.relevant(&rel) {
            pending.insert(rel);
            relevant = true;
        }
    }
    relevant
}

fn run(
    mut st: MountState,
    mut watcher: Watch,
    fs_rx: Receiver<notify::Result<notify::Event>>,
    ws_rx: Receiver<Event>,
    cmd_rx: Receiver<Cmd>,
) {
    let mut pending: BTreeSet<String> = BTreeSet::new();
    let mut rescan = false;
    let mut first_event: Option<Instant> = None;
    let mut last_event: Option<Instant> = None;
    let mut need_sync = false;
    let mut fences: Vec<PendingFence> = Vec::new();
    let ingestion = st.record.ingestion_actor;
    let mut fs_rx = Some(fs_rx);
    let mut last_activity = Instant::now();

    loop {
        let now = Instant::now();
        let mut wake = now + Duration::from_secs(3600);
        if let Some(idle) = st.opts.idle_unload.filter(|_| !st.hibernating) {
            wake = wake.min(last_activity + idle);
        }
        if let (Some(first), Some(last)) = (first_event, last_event) {
            wake = wake.min((last + st.opts.debounce).min(first + st.opts.max_latency));
        }
        if need_sync {
            wake = now;
        }
        for f in &fences {
            wake = wake.min(if f.arrived { now } else { f.deadline });
        }
        let timeout = wake.saturating_duration_since(now);
        let fs_chan = fs_rx.clone().unwrap_or_else(never);
        select! {
            recv(fs_chan) -> msg => match msg {
                Ok(Ok(event)) => {
                    watcher.follow(&st.root, &st.ignore, &event);
                    let mut relevant = absorb(&st, &event, &mut pending, &mut rescan, &mut fences);
                    // Take everything already delivered, so a fence never
                    // overtakes events queued just behind its marker.
                    while let Ok(Ok(more)) = fs_chan.try_recv() {
                        watcher.follow(&st.root, &st.ignore, &more);
                        relevant |= absorb(&st, &more, &mut pending, &mut rescan, &mut fences);
                    }
                    if relevant {
                        let t = Instant::now();
                        first_event.get_or_insert(t);
                        last_event = Some(t);
                        last_activity = t;
                    }
                }
                Ok(Err(e)) => {
                    tracing::warn!(error = %e, "watcher error; scheduling rescan");
                    rescan = true;
                    first_event.get_or_insert(Instant::now());
                    last_event = Some(Instant::now());
                }
                Err(_) => fs_rx = None,
            },
            recv(ws_rx) -> ev => match ev {
                Ok(Event::Committed(c)) if st.hibernating && c.actor == ingestion && c.origin == Origin::Local => {}
                Ok(Event::Committed(c)) => {
                    last_activity = Instant::now();
                    if c.actor != ingestion || c.origin == Origin::Remote {
                        need_sync = true;
                    }
                }
                Ok(Event::Reloaded) => need_sync = true,
                Err(_) => return,
            },
            recv(cmd_rx) -> cmd => match cmd.inspect(|_| last_activity = Instant::now()) {
                Ok(Cmd::Stop { reply }) => {
                    let _ = st.flush(&mut pending, &mut rescan);
                    let _ = st.persist();
                    let _ = reply.send(());
                    return;
                }
                Ok(Cmd::Fence { reply }) => match st.write_fence_marker() {
                    Ok(marker) => fences.push(PendingFence { marker, deadline: Instant::now() + st.opts.fence_timeout, arrived: false, reply }),
                    Err(e) => { let _ = reply.send(Err(e.into())); }
                },
                Ok(Cmd::Write { actor, path, bytes, exec, reply }) => {
                    let r = st.flush(&mut pending, &mut rescan).and_then(|_| st.tool_write(actor, &path, bytes, exec));
                    let _ = reply.send(r);
                }
                Ok(Cmd::Remove { actor, path, reply }) => {
                    let r = st.flush(&mut pending, &mut rescan).and_then(|_| st.tool_remove(actor, &path));
                    let _ = reply.send(r);
                }
                Ok(Cmd::Rename { actor, from, to, reply }) => {
                    let r = st.flush(&mut pending, &mut rescan).and_then(|_| st.tool_rename(actor, &from, &to));
                    let _ = reply.send(r);
                }
                Err(_) => return,
            },
            default(timeout) => {}
        }

        let now = Instant::now();
        let due = match (first_event, last_event) {
            (Some(first), Some(last)) => now >= last + st.opts.debounce || now >= first + st.opts.max_latency,
            _ => false,
        };
        let fence_ready = fences.iter().any(|f| f.arrived || now >= f.deadline);
        if due || fence_ready {
            first_event = None;
            last_event = None;
            st.settling = !fence_ready;
            if let Err(e) = st.flush(&mut pending, &mut rescan) {
                tracing::error!(error = %e, "reconcile failed");
            }
            st.settling = false;
            if std::mem::take(&mut st.ignore_changed) {
                watcher.resync(&st.root, &st.ignore);
            }
            if !st.deferred.is_empty() {
                pending.append(&mut st.deferred);
                let t = Instant::now();
                first_event = Some(t);
                last_event = Some(t);
            }
            need_sync = true;
        }
        if need_sync {
            need_sync = false;
            if let Err(e) = st.materialize() {
                tracing::error!(error = %e, "materialize failed");
            }
        }
        if let Some(idle) = st.opts.idle_unload
            && !st.hibernating
            && fences.is_empty()
            && pending.is_empty()
            && !rescan
            && first_event.is_none()
            && !need_sync
            && Instant::now() >= last_activity + idle
            && let Err(e) = st.hibernate()
        {
            tracing::error!(error = %e, "hibernate failed");
            last_activity = Instant::now();
        }
        if fence_ready {
            let (ready, rest): (Vec<_>, Vec<_>) = fences.drain(..).partition(|f| f.arrived || now >= f.deadline);
            fences = rest;
            for f in ready {
                let mut rescanned = false;
                let mut git_busy = st.settle_git();
                if !f.arrived {
                    rescanned = true;
                    git_busy |= st.reconcile(ingest::Scope::Full).and_then(|_| st.materialize()).is_err();
                }
                let _ = fs::remove_file(st.root.join(&f.marker));
                let _ = f.reply.send(Ok(st.fence_outcome(rescanned, git_busy)));
            }
        }
    }
}

impl MountState {
    fn flush(&mut self, pending: &mut BTreeSet<String>, rescan: &mut bool) -> Result<(), Error> {
        if std::mem::take(rescan) {
            pending.clear();
            self.reconcile(ingest::Scope::Full)?;
        } else if !pending.is_empty() {
            let paths = std::mem::take(pending);
            self.reconcile(ingest::Scope::Paths(paths))?;
        }
        Ok(())
    }
}
