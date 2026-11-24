use std::collections::HashMap;
use std::future::Future;
use std::io::Write;
use std::marker::PhantomData;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::task::{Context, Poll};
use std::time::Duration;

use serde::de::DeserializeOwned;

use crate::chan::{Next, Queue, QueueState};
use crate::error::{Error, Result, Status};
use crate::frame::{self, Frame, FrameReader};
use crate::types::{Delta, Deltas, Event, ForkDiff, Runners};

#[cfg(unix)]
pub(crate) type Sock = std::os::unix::net::UnixStream;
#[cfg(windows)]
pub(crate) type Sock = uds_windows::UnixStream;

pub(crate) fn sock_connect(path: &Path) -> std::io::Result<Sock> {
    Sock::connect(path)
}

fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from)
}

pub fn data_dir() -> Option<PathBuf> {
    if let Some(h) = env_dir("ONDB_HOME") {
        return Some(h);
    }
    if cfg!(windows) {
        let base = env_dir("LOCALAPPDATA").or_else(|| env_dir("USERPROFILE").map(|h| h.join("AppData").join("Local")))?;
        return Some(base.join("0ndb"));
    }
    if cfg!(target_os = "macos") {
        return env_dir("HOME").map(|h| h.join("Library").join("Application Support").join("0ndb"));
    }
    if let Some(x) = env_dir("XDG_DATA_HOME") {
        return Some(x.join("0ndb"));
    }
    env_dir("HOME").map(|h| h.join(".local").join("share").join("0ndb"))
}

pub fn socket_path() -> Option<PathBuf> {
    if let Some(d) = env_dir("ONDB_RUNTIME_DIR") {
        return Some(d.join("daemon.sock"));
    }
    if let Some(h) = env_dir("ONDB_HOME") {
        return Some(h.join("run").join("daemon.sock"));
    }
    if cfg!(target_os = "linux") {
        if let Some(x) = env_dir("XDG_RUNTIME_DIR") {
            return Some(x.join("0ndb").join("daemon.sock"));
        }
    }
    data_dir().map(|d| d.join("run").join("daemon.sock"))
}

#[derive(Debug, Clone)]
pub struct Autostart {
    pub exe: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

impl Autostart {
    pub fn new(exe: impl Into<PathBuf>) -> Self {
        Autostart {
            exe: exe.into(),
            args: Vec::new(),
            env: Vec::new(),
        }
    }

    pub fn env(mut self, k: impl Into<String>, v: impl Into<String>) -> Self {
        self.env.push((k.into(), v.into()));
        self
    }

    pub fn arg(mut self, a: impl Into<String>) -> Self {
        self.args.push(a.into());
        self
    }

    pub fn start(&self) -> Result<()> {
        let out = Command::new(&self.exe)
            .arg("daemon")
            .arg("start")
            .args(&self.args)
            .envs(self.env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .map_err(|e| Error::Start(format!("{}: {e}", self.exe.display())))?;
        if !out.status.success() {
            return Err(Error::Start(String::from_utf8_lossy(&out.stderr).trim().to_string()));
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct Options {
    pub socket: Option<PathBuf>,
    pub autostart: Option<Autostart>,
    pub reconnect: bool,
    pub queue_limit: usize,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            socket: None,
            autostart: None,
            reconnect: true,
            queue_limit: 1024,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ClientStats {
    pub socket_reads: u64,
    pub bytes_received: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnState {
    Connected,
    Disconnected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GapReason {
    Lagged,
    Overflow,
    Reconnected,
}

#[derive(Debug, Clone)]
pub struct Gap {
    pub reason: GapReason,
    pub full: bool,
    pub objects: Vec<String>,
}

#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum SubItem {
    Deltas(Vec<Delta>),
    Gap(Gap),
    Runners(Runners),
    ForkDiff(ForkDiff),
    Raw(Vec<u8>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubKind {
    Object,
    Catalog,
    Runners,
    ForkDiff,
    Raw,
}

struct SubEntry {
    req: Vec<u8>,
    object: Option<String>,
    kind: SubKind,
    queue: Arc<Queue<SubItem>>,
    tag: u64,
}

type Reply = (Status, Vec<u8>);

pub(crate) struct Link {
    writer: Mutex<Sock>,
    pending: Mutex<HashMap<u64, Arc<Queue<Reply>>>>,
    tags: Mutex<HashMap<u64, u64>>,
    next_tag: AtomicU64,
    dead: AtomicBool,
}

impl Link {
    fn send(&self, bytes: &[u8]) -> Result<()> {
        if self.dead.load(Ordering::Acquire) {
            return Err(Error::Disconnected);
        }
        let mut w = self.writer.lock().unwrap_or_else(|e| e.into_inner());
        if w.write_all(bytes).is_err() {
            self.dead.store(true, Ordering::Release);
            let _ = w.shutdown(std::net::Shutdown::Both);
            return Err(Error::Disconnected);
        }
        Ok(())
    }

    fn tag(&self) -> u64 {
        self.next_tag.fetch_add(1, Ordering::Relaxed) + 1
    }
}

pub(crate) struct Inner {
    opts: Options,
    path: PathBuf,
    link: Mutex<Option<Arc<Link>>>,
    subs: Mutex<HashMap<u64, SubEntry>>,
    next_sub: AtomicU64,
    events: Mutex<Option<Weak<Queue<Event>>>>,
    events_mask: Mutex<u64>,
    states: Mutex<Vec<Weak<Queue<ConnState>>>>,
    reads: Arc<AtomicU64>,
    bytes: Arc<AtomicU64>,
    reconnecting: AtomicBool,
}

impl Drop for Inner {
    fn drop(&mut self) {
        if let Some(l) = self.link.lock().unwrap_or_else(|e| e.into_inner()).take() {
            l.dead.store(true, Ordering::Release);
            let _ = l.writer.lock().unwrap_or_else(|e| e.into_inner()).shutdown(std::net::Shutdown::Both);
        }
    }
}

#[derive(Clone)]
pub struct Client {
    pub(crate) inner: Arc<Inner>,
}

fn open_link(path: &Path, autostart: Option<&Autostart>) -> Result<Sock> {
    match sock_connect(path) {
        Ok(s) => Ok(s),
        Err(e) => match autostart {
            Some(a) => {
                a.start()?;
                Ok(sock_connect(path)?)
            }
            None => Err(Error::Io(e)),
        },
    }
}

impl Client {
    pub fn connect() -> Result<Client> {
        Client::connect_with(Options::default())
    }

    pub fn connect_with(opts: Options) -> Result<Client> {
        let path = match &opts.socket {
            Some(p) => p.clone(),
            None => socket_path().ok_or_else(|| Error::Protocol("cannot determine the daemon socket path".into()))?,
        };
        let sock = open_link(&path, opts.autostart.as_ref())?;
        let inner = Arc::new(Inner {
            opts,
            path,
            link: Mutex::new(None),
            subs: Mutex::new(HashMap::new()),
            next_sub: AtomicU64::new(0),
            events: Mutex::new(None),
            events_mask: Mutex::new(0),
            states: Mutex::new(Vec::new()),
            reads: Arc::new(AtomicU64::new(0)),
            bytes: Arc::new(AtomicU64::new(0)),
            reconnecting: AtomicBool::new(false),
        });
        install(&inner, sock)?;
        Ok(Client { inner })
    }

    pub fn socket(&self) -> &Path {
        &self.inner.path
    }

    pub fn is_connected(&self) -> bool {
        self.inner.link.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|l| !l.dead.load(Ordering::Acquire))
    }

    pub fn stats(&self) -> ClientStats {
        ClientStats {
            socket_reads: self.inner.reads.load(Ordering::Relaxed),
            bytes_received: self.inner.bytes.load(Ordering::Relaxed),
        }
    }

    fn link(&self) -> Result<Arc<Link>> {
        let g = self.inner.link.lock().unwrap_or_else(|e| e.into_inner());
        match g.as_ref() {
            Some(l) if !l.dead.load(Ordering::Acquire) => Ok(l.clone()),
            _ => Err(Error::Disconnected),
        }
    }

    pub fn call_raw(&self, req: &[u8], json: bool, timeout_ms: u64) -> Pending<RawReply> {
        self.start(req, json, timeout_ms, Box::new(|st, p| Ok(RawReply { status: st, payload: p })))
    }

    pub fn call<T: DeserializeOwned + Send + 'static>(&self, req: &serde_json::Value) -> Pending<T> {
        self.call_timeout(req, 0)
    }

    pub fn call_timeout<T: DeserializeOwned + Send + 'static>(&self, req: &serde_json::Value, timeout_ms: u64) -> Pending<T> {
        let body = serde_json::to_vec(req).unwrap_or_default();
        self.start(&body, true, timeout_ms, Box::new(decode_json::<T>))
    }

    pub(crate) fn start<T>(&self, req: &[u8], json: bool, timeout_ms: u64, finish: Finish<T>) -> Pending<T> {
        let link = match self.link() {
            Ok(l) => l,
            Err(e) => return Pending::failed(e),
        };
        let tag = link.tag();
        let slot = Queue::new();
        link.pending.lock().unwrap_or_else(|e| e.into_inner()).insert(tag, slot.clone());
        let flags = [if json { frame::FLAG_JSON } else { 0 }];
        let f = frame::encode(frame::CALL, &[&tag.to_le_bytes(), &flags, &timeout_ms.to_le_bytes(), req]);
        if let Err(e) = link.send(&f) {
            link.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&tag);
            return Pending::failed(e);
        }
        Pending {
            slot: Some(slot),
            link: Arc::downgrade(&link),
            tag,
            finish: Some(finish),
            err: None,
            abandon: None,
            _t: PhantomData,
        }
    }

    pub fn subscribe(&self, req: &serde_json::Value, catalog: bool) -> Pending<Subscription> {
        self.subscribe_with(req, if catalog { SubKind::Catalog } else { SubKind::Object }, |sub, _| Ok(sub))
    }

    pub fn subscribe_raw_with<T: Send + 'static>(&self, req: &serde_json::Value, finish: impl FnOnce(Subscription, &[u8]) -> Result<T> + Send + 'static) -> Pending<T> {
        self.subscribe_with(req, SubKind::Raw, finish)
    }

    pub fn subscribe_with<T: Send + 'static>(&self, req: &serde_json::Value, kind: SubKind, finish: impl FnOnce(Subscription, &[u8]) -> Result<T> + Send + 'static) -> Pending<T> {
        let body = serde_json::to_vec(req).unwrap_or_default();
        let link = match self.link() {
            Ok(l) => l,
            Err(e) => return Pending::failed(e),
        };
        let id = self.inner.next_sub.fetch_add(1, Ordering::Relaxed) + 1;
        let queue = Queue::with_hook(Some(gap_popped));
        let tag = link.tag();
        let slot = Queue::new();
        link.pending.lock().unwrap_or_else(|e| e.into_inner()).insert(tag, slot.clone());
        link.tags.lock().unwrap_or_else(|e| e.into_inner()).insert(tag, id);
        self.inner.subs.lock().unwrap_or_else(|e| e.into_inner()).insert(
            id,
            SubEntry {
                req: body.clone(),
                object: req.get("object").and_then(|o| o.as_str()).map(String::from),
                kind,
                queue: queue.clone(),
                tag,
            },
        );
        let flags = if kind == SubKind::Raw { frame::FLAG_JSON } else { frame::FLAG_JSON | frame::FLAG_COMPACT };
        let f = frame::encode(frame::SUBSCRIBE, &[&tag.to_le_bytes(), &[flags], &body]);
        let weak = Arc::downgrade(&self.inner);
        let fail_weak = weak.clone();
        let done: Finish<T> = Box::new(move |st, payload| {
            if st != Status::OK {
                if let Some(inner) = fail_weak.upgrade() {
                    inner.subs.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
                }
                return Err(Error::Status(st));
            }
            finish(Subscription { id, queue, inner: weak }, &payload)
        });
        if let Err(e) = link.send(&f) {
            link.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&tag);
            self.inner.subs.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
            return Pending::failed(e);
        }
        Pending {
            slot: Some(slot),
            link: Arc::downgrade(&link),
            tag,
            finish: Some(done),
            err: None,
            abandon: None,
            _t: PhantomData,
        }
    }

    pub fn call_then<R: DeserializeOwned + Send + 'static, T: Send + 'static>(&self, req: &serde_json::Value, map: impl FnOnce(R) -> T + Send + 'static) -> Pending<T> {
        let body = serde_json::to_vec(req).unwrap_or_default();
        self.start(&body, true, 0, Box::new(move |st, p| decode_json::<R>(st, p).map(map)))
    }

    pub fn events(&self) -> Result<Events> {
        self.events_filtered(&EVENT_NAMES.iter().copied().filter(|n| *n != "durable" && *n != "uploaded").collect::<Vec<_>>())
    }

    pub fn events_filtered(&self, kinds: &[&str]) -> Result<Events> {
        let mut mask = 0u64;
        for k in kinds {
            if let Some(i) = EVENT_NAMES.iter().position(|n| n == k) {
                mask |= 1 << i;
            }
        }
        let q = Queue::new();
        *self.inner.events.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::downgrade(&q));
        *self.inner.events_mask.lock().unwrap_or_else(|e| e.into_inner()) = mask;
        self.link()?.send(&events_frame(mask))?;
        Ok(Events {
            queue: q,
            inner: Arc::downgrade(&self.inner),
        })
    }

    pub fn connection_states(&self) -> ConnStates {
        let q = Queue::new();
        self.inner.states.lock().unwrap_or_else(|e| e.into_inner()).push(Arc::downgrade(&q));
        ConnStates { queue: q }
    }
}

pub const EVENT_NAMES: [&str; 35] = [
    "connected",
    "disconnected",
    "durable",
    "uploaded",
    "quarantined",
    "refused",
    "fatal",
    "space_joined",
    "object_seen",
    "failure",
    "placement",
    "relay_misbehaving",
    "presence",
    "caught_up",
    "indexer_wanted",
    "unavailable",
    "available",
    "promoted",
    "peer_misbehaving",
    "members_changed",
    "epoch_changed",
    "access_revoked",
    "runner_enrolled",
    "runner_anomaly",
    "approval_requested",
    "login_done",
    "login_failed",
    "lease_lapsed",
    "space_left",
    "line_switched",
    "replica_redacted",
    "rename_offered",
    "redact_unreached",
    "models_changed",
    "authors_resolved",
];

fn events_frame(mask: u64) -> Vec<u8> {
    frame::encode(frame::EVENTS, &[&[frame::FLAG_JSON], &mask.to_le_bytes()])
}

pub(crate) type Finish<T> = Box<dyn FnOnce(Status, Vec<u8>) -> Result<T> + Send>;

fn decode_json<T: DeserializeOwned>(st: Status, payload: Vec<u8>) -> Result<T> {
    if st != Status::OK {
        return Err(Error::Status(st));
    }
    if payload.is_empty() {
        return Ok(serde_json::from_slice(b"{}")?);
    }
    Ok(serde_json::from_slice(&payload)?)
}

#[derive(Debug, Clone)]
pub struct RawReply {
    pub status: Status,
    pub payload: Vec<u8>,
}

pub struct Pending<T> {
    slot: Option<Arc<Queue<Reply>>>,
    link: Weak<Link>,
    tag: u64,
    finish: Option<Finish<T>>,
    err: Option<Error>,
    abandon: Option<Box<dyn FnOnce() + Send>>,
    _t: PhantomData<fn() -> T>,
}

impl<T> Pending<T> {
    fn failed(e: Error) -> Self {
        Pending {
            slot: None,
            link: Weak::new(),
            tag: 0,
            finish: None,
            err: Some(e),
            abandon: None,
            _t: PhantomData,
        }
    }

    fn complete(&mut self, r: Option<Reply>) -> Result<T> {
        self.slot = None;
        let finish = self.finish.take().ok_or(Error::Disconnected)?;
        match r {
            Some((st, p)) => finish(st, p),
            None => Err(Error::Disconnected),
        }
    }

    pub fn wait(mut self) -> Result<T> {
        if let Some(e) = self.err.take() {
            return Err(e);
        }
        let slot = match self.slot.clone() {
            Some(s) => s,
            None => return Err(Error::Disconnected),
        };
        let r = slot.pop_blocking(None);
        self.complete(r)
    }

    pub fn wait_timeout(mut self, d: Duration) -> Result<T> {
        if let Some(e) = self.err.take() {
            return Err(e);
        }
        let slot = match self.slot.clone() {
            Some(s) => s,
            None => return Err(Error::Disconnected),
        };
        match slot.pop_blocking(Some(d)) {
            Some(r) => self.complete(Some(r)),
            None => Err(Error::Status(Status::TIMEOUT)),
        }
    }

    pub fn cancel(self) {}

    pub(crate) fn on_drop(&mut self, f: impl FnOnce() + Send + 'static) {
        self.abandon = Some(Box::new(f));
    }

    pub fn try_take(&mut self) -> Option<Result<T>> {
        if let Some(e) = self.err.take() {
            return Some(Err(e));
        }
        let slot = self.slot.clone()?;
        let r = slot.try_pop()?;
        Some(self.complete(Some(r)))
    }
}

impl<T> Unpin for Pending<T> {}

impl<T> Future for Pending<T> {
    type Output = Result<T>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<T>> {
        if let Some(e) = self.err.take() {
            return Poll::Ready(Err(e));
        }
        let slot = match self.slot.clone() {
            Some(s) => s,
            None => return Poll::Ready(Err(Error::Disconnected)),
        };
        match slot.poll_pop(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(r) => Poll::Ready(self.complete(r)),
        }
    }
}

impl<T> Drop for Pending<T> {
    fn drop(&mut self) {
        if let Some(f) = self.abandon.take() {
            f();
        }
        if self.slot.is_none() {
            return;
        }
        if let Some(link) = self.link.upgrade() {
            if link.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.tag).is_some() {
                let _ = link.send(&frame::encode(frame::CANCEL, &[&self.tag.to_le_bytes()]));
            }
        }
    }
}

pub struct Subscription {
    id: u64,
    queue: Arc<Queue<SubItem>>,
    inner: Weak<Inner>,
}

impl Subscription {
    pub fn recv(&mut self) -> Next<'_, SubItem> {
        Next { queue: &self.queue }
    }

    pub fn blocking_recv(&mut self) -> Option<SubItem> {
        self.queue.pop_blocking(None)
    }

    pub fn blocking_recv_timeout(&mut self, d: Duration) -> Option<SubItem> {
        self.queue.pop_blocking(Some(d))
    }

    pub fn try_recv(&mut self) -> Option<SubItem> {
        self.queue.try_pop()
    }
}

fn gap_popped(item: &SubItem, st: &mut QueueState<SubItem>) {
    if matches!(item, SubItem::Gap(_)) && !st.items.iter().any(|i| matches!(i, SubItem::Gap(_))) {
        st.dropping = false;
    }
}

impl Drop for Subscription {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.upgrade() {
            let entry = inner.subs.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.id);
            if let Some(e) = entry {
                let link = inner.link.lock().unwrap_or_else(|e| e.into_inner()).clone();
                if let Some(l) = link {
                    l.tags.lock().unwrap_or_else(|e| e.into_inner()).remove(&e.tag);
                    let _ = l.send(&frame::encode(frame::UNSUBSCRIBE, &[&e.tag.to_le_bytes()]));
                }
            }
        }
    }
}

pub struct Events {
    queue: Arc<Queue<Event>>,
    inner: Weak<Inner>,
}

impl Events {
    pub fn recv(&mut self) -> Next<'_, Event> {
        Next { queue: &self.queue }
    }

    pub fn blocking_recv(&mut self) -> Option<Event> {
        self.queue.pop_blocking(None)
    }

    pub fn blocking_recv_timeout(&mut self, d: Duration) -> Option<Event> {
        self.queue.pop_blocking(Some(d))
    }

    pub fn try_recv(&mut self) -> Option<Event> {
        self.queue.try_pop()
    }
}

impl Drop for Events {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.upgrade() {
            *inner.events.lock().unwrap_or_else(|e| e.into_inner()) = None;
            let link = inner.link.lock().unwrap_or_else(|e| e.into_inner()).clone();
            if let Some(l) = link {
                let _ = l.send(&frame::encode(frame::EVENTS, &[&[2]]));
            }
        }
    }
}

pub struct ConnStates {
    queue: Arc<Queue<ConnState>>,
}

impl ConnStates {
    pub fn recv(&mut self) -> Next<'_, ConnState> {
        Next { queue: &self.queue }
    }

    pub fn blocking_recv(&mut self) -> Option<ConnState> {
        self.queue.pop_blocking(None)
    }

    pub fn blocking_recv_timeout(&mut self, d: Duration) -> Option<ConnState> {
        self.queue.pop_blocking(Some(d))
    }
}

fn install(inner: &Arc<Inner>, mut sock: Sock) -> Result<()> {
    sock.write_all(&frame::hello())?;
    let reader = sock.try_clone()?;
    let link = Arc::new(Link {
        writer: Mutex::new(sock),
        pending: Mutex::new(HashMap::new()),
        tags: Mutex::new(HashMap::new()),
        next_tag: AtomicU64::new(0),
        dead: AtomicBool::new(false),
    });
    *inner.link.lock().unwrap_or_else(|e| e.into_inner()) = Some(link.clone());
    let weak = Arc::downgrade(inner);
    let (reads, bytes) = (inner.reads.clone(), inner.bytes.clone());
    std::thread::Builder::new()
        .name("ondb-reader".into())
        .spawn(move || read_loop(weak, link, FrameReader::new(reader, reads, bytes)))?;
    Ok(())
}

fn read_loop(inner: Weak<Inner>, link: Arc<Link>, mut fr: FrameReader<Sock>) {
    while let Ok(f) = fr.next() {
        let Some(inner) = inner.upgrade() else { break };
        dispatch(&inner, &link, f);
    }
    link.dead.store(true, Ordering::Release);
    let slots: Vec<_> = link.pending.lock().unwrap_or_else(|e| e.into_inner()).drain().map(|(_, s)| s).collect();
    for s in slots {
        s.close();
    }
    if let Some(inner) = inner.upgrade() {
        notify_state(&inner, ConnState::Disconnected);
        if inner.opts.reconnect && !inner.reconnecting.swap(true, Ordering::AcqRel) {
            let weak = Arc::downgrade(&inner);
            drop(inner);
            let _ = std::thread::Builder::new().name("ondb-reconnect".into()).spawn(move || reconnect(weak));
        }
    }
}

fn notify_state(inner: &Inner, st: ConnState) {
    let mut g = inner.states.lock().unwrap_or_else(|e| e.into_inner());
    g.retain(|w| match w.upgrade() {
        Some(q) => {
            q.push(st);
            true
        }
        None => false,
    });
}

fn reconnect(weak: Weak<Inner>) {
    let mut delay = Duration::from_millis(50);
    loop {
        let Some(inner) = weak.upgrade() else { return };
        if let Ok(sock) = open_link(&inner.path, inner.opts.autostart.as_ref()) {
            if install(&inner, sock).is_ok() && resubscribe(&inner).is_ok() {
                inner.reconnecting.store(false, Ordering::Release);
                notify_state(&inner, ConnState::Connected);
                return;
            }
        }
        drop(inner);
        std::thread::sleep(delay);
        delay = (delay * 2).min(Duration::from_secs(2));
    }
}

fn resubscribe(inner: &Arc<Inner>) -> Result<()> {
    let link = inner.link.lock().unwrap_or_else(|e| e.into_inner()).clone().ok_or(Error::Disconnected)?;
    let events = inner.events.lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|w| w.upgrade());
    if events.is_some() {
        let mask = *inner.events_mask.lock().unwrap_or_else(|e| e.into_inner());
        link.send(&events_frame(mask))?;
    }
    let mut subs = inner.subs.lock().unwrap_or_else(|e| e.into_inner());
    for (id, e) in subs.iter_mut() {
        if e.kind == SubKind::Raw {
            let mut g = e.queue.lock();
            g.items.push_back(SubItem::Gap(Gap {
                reason: GapReason::Reconnected,
                full: true,
                objects: Vec::new(),
            }));
            e.queue.notify(g);
            continue;
        }
        let tag = link.tag();
        e.tag = tag;
        link.tags.lock().unwrap_or_else(|e| e.into_inner()).insert(tag, *id);
        link.send(&frame::encode(frame::SUBSCRIBE, &[&tag.to_le_bytes(), &[frame::FLAG_JSON | frame::FLAG_COMPACT], &e.req]))?;
        let mut g = e.queue.lock();
        g.items.retain(|i| matches!(i, SubItem::Gap(_)));
        g.items.push_back(SubItem::Gap(Gap {
            reason: GapReason::Reconnected,
            full: true,
            objects: Vec::new(),
        }));
        g.dropping = false;
        e.queue.notify(g);
    }
    Ok(())
}

fn dispatch(inner: &Inner, link: &Link, f: Frame) {
    if f.kind == frame::EVENT {
        dispatch_event(inner, &f.payload);
        return;
    }
    let Some(tag) = f.tag() else { return };
    match f.kind {
        frame::RESULT => {
            if f.payload.len() < 9 {
                return;
            }
            let slot = link.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&tag);
            if let Some(s) = slot {
                s.push((Status(f.payload[8]), f.payload[9..].to_vec()));
            }
        }
        frame::DELTAS => {
            let Some(id) = link.tags.lock().unwrap_or_else(|e| e.into_inner()).get(&tag).copied() else { return };
            let subs = inner.subs.lock().unwrap_or_else(|e| e.into_inner());
            let Some(e) = subs.get(&id) else { return };
            if e.kind == SubKind::Raw {
                push_raw(&e.queue, f.payload[8..].to_vec(), inner.opts.queue_limit);
                return;
            }
            if e.kind == SubKind::Runners {
                let Ok(r) = serde_json::from_slice::<Runners>(&f.payload[8..]) else { return };
                push_runners(&e.queue, r);
                return;
            }
            if e.kind == SubKind::ForkDiff {
                let Ok(d) = serde_json::from_slice::<ForkDiff>(&f.payload[8..]) else { return };
                push_fork_diff(&e.queue, d);
                return;
            }
            let Ok(mut d) = serde_json::from_slice::<Deltas>(&f.payload[8..]) else { return };
            if let Some(o) = &e.object {
                for x in d.deltas.iter_mut().filter(|x| x.object.is_none()) {
                    x.object = Some(o.clone());
                }
            }
            push_deltas(&e.queue, e.kind == SubKind::Catalog, d.deltas, inner.opts.queue_limit);
        }
        frame::GAP => {
            let Some(id) = link.tags.lock().unwrap_or_else(|e| e.into_inner()).get(&tag).copied() else { return };
            let v: serde_json::Value = serde_json::from_slice(&f.payload[8..]).unwrap_or_default();
            let gap = Gap {
                reason: GapReason::Lagged,
                full: v["full"].as_bool().unwrap_or(true),
                objects: v["objects"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
                    .unwrap_or_default(),
            };
            let subs = inner.subs.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(e) = subs.get(&id) {
                e.queue.push(SubItem::Gap(gap));
            }
        }
        _ => {}
    }
}

fn dispatch_event(inner: &Inner, payload: &[u8]) {
    let q = inner.events.lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|w| w.upgrade());
    let Some(q) = q else { return };
    let Ok(ev) = serde_json::from_slice::<Event>(payload) else { return };
    let mut g = q.lock();
    g.items.push_back(ev);
    if g.items.len() > inner.opts.queue_limit {
        let mut seen = std::collections::HashSet::new();
        let mut kept: Vec<Event> = Vec::with_capacity(g.items.len());
        for e in g.items.drain(..).rev() {
            let key = (e.kind.clone(), e.space.clone(), e.object.clone(), e.device.clone());
            if seen.insert(key) {
                kept.push(e);
            }
        }
        kept.reverse();
        g.items.extend(kept);
    }
    q.notify(g);
}

fn push_deltas(q: &Queue<SubItem>, catalog: bool, deltas: Vec<Delta>, limit: usize) {
    let mut g = q.lock();
    if g.dropping {
        if catalog {
            if let Some(SubItem::Gap(gap)) = g.items.back_mut() {
                for d in &deltas {
                    if let Some(o) = &d.object {
                        if !gap.objects.contains(o) {
                            gap.objects.push(o.clone());
                        }
                    }
                }
            }
        }
        return;
    }
    g.items.push_back(SubItem::Deltas(deltas));
    if g.items.len() > limit {
        let mut objects: Vec<String> = Vec::new();
        let mut kept = std::collections::VecDeque::new();
        for it in g.items.drain(..) {
            match it {
                SubItem::Deltas(ds) => {
                    for d in ds {
                        if let Some(o) = d.object {
                            if !objects.contains(&o) {
                                objects.push(o);
                            }
                        }
                    }
                }
                gap => kept.push_back(gap),
            }
        }
        kept.push_back(SubItem::Gap(Gap {
            reason: GapReason::Overflow,
            full: !catalog,
            objects: if catalog { objects } else { Vec::new() },
        }));
        g.items = kept;
        g.dropping = true;
    }
    q.notify(g);
}

fn push_runners(q: &Queue<SubItem>, r: Runners) {
    let mut g = q.lock();
    g.items.retain(|i| !matches!(i, SubItem::Runners(_)));
    g.items.push_back(SubItem::Runners(r));
    q.notify(g);
}

fn push_fork_diff(q: &Queue<SubItem>, d: ForkDiff) {
    let mut g = q.lock();
    g.items.retain(|i| !matches!(i, SubItem::ForkDiff(_)));
    g.items.push_back(SubItem::ForkDiff(d));
    q.notify(g);
}

fn push_raw(q: &Queue<SubItem>, payload: Vec<u8>, limit: usize) {
    let mut g = q.lock();
    if g.dropping {
        return;
    }
    g.items.push_back(SubItem::Raw(payload));
    if g.items.len() > limit {
        g.items.clear();
        g.items.push_back(SubItem::Gap(Gap {
            reason: GapReason::Overflow,
            full: true,
            objects: Vec::new(),
        }));
        g.dropping = true;
    }
    q.notify(g);
}
