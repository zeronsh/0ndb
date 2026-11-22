use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use crate::chan::Queue;
use crate::codec::{Reader, Writer};
use crate::conn::{sock_connect, socket_path, Sock};
use crate::error::{Error, Result, Status};
use crate::frame::{self, FrameReader};

const REGISTER_CODE: u64 = 1009;
const API_VERSION: u8 = 1;
const PLUG_VERSION: u8 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlugError(pub Status);

impl PlugError {
    pub const NOT_FOUND: PlugError = PlugError(Status::NOT_FOUND);
    pub const CONFLICT: PlugError = PlugError(Status::CONFLICT);
    pub const PERMISSION: PlugError = PlugError(Status::PERMISSION);
    pub const UNSUPPORTED: PlugError = PlugError(Status::UNSUPPORTED);
    pub const CANCELLED: PlugError = PlugError(Status::CANCELLED);
    pub const IO: PlugError = PlugError(Status::IO);
    pub const INVALID: PlugError = PlugError(Status::INVALID);
}

pub type PlugResult<T> = std::result::Result<T, PlugError>;

#[derive(Clone, Default)]
pub struct CancelToken(Arc<(Mutex<bool>, Condvar)>);

impl CancelToken {
    pub fn is_cancelled(&self) -> bool {
        *self.0 .0.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn wait(&self, d: Duration) -> bool {
        let g = self.0 .0.lock().unwrap_or_else(|e| e.into_inner());
        let (g, _) = self.0 .1.wait_timeout_while(g, d, |c| !*c).unwrap_or_else(|e| e.into_inner());
        *g
    }

    fn cancel(&self) {
        *self.0 .0.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.0 .1.notify_all();
    }
}

#[derive(Debug, Clone, Default)]
pub struct AccountRecord {
    pub record: Vec<u8>,
    pub entries: Vec<Vec<u8>>,
}

pub trait SealedStore: Send + Sync + 'static {
    fn get(&self, subject: &[u8], cancel: &CancelToken) -> PlugResult<Option<AccountRecord>>;
    fn put(&self, subject: &[u8], record: &[u8], prev_seq: u64, seq: u64, cancel: &CancelToken) -> PlugResult<()>;
    fn add(&self, subject: &[u8], entry: &[u8], cancel: &CancelToken) -> PlugResult<()>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnlockMode {
    ThisDevice,
    OtherDevice,
}

#[derive(Debug, Clone)]
pub struct UnlockOption {
    pub credential: Vec<u8>,
    pub salt: [u8; 32],
}

#[derive(Debug, Clone)]
pub struct UnlockRequest {
    pub rp_user: Vec<u8>,
    pub options: Vec<UnlockOption>,
    pub mode: UnlockMode,
}

#[derive(Debug, Clone)]
pub struct RegisterRequest {
    pub rp_user: Vec<u8>,
    pub label: String,
    pub salt: [u8; 32],
}

#[derive(Debug, Clone)]
pub struct PasskeyOutput {
    pub credential: Vec<u8>,
    pub prf: [u8; 32],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Ecosystem {
    Unknown = 0,
    Apple = 1,
    Google = 2,
    Microsoft = 3,
    OnePassword = 4,
    Bitwarden = 5,
    SecurityKey = 6,
    Recovery = 7,
    Test = 8,
}

#[derive(Debug, Clone)]
pub struct RegisteredPasskey {
    pub credential: Vec<u8>,
    pub prf: [u8; 32],
    pub ecosystem: Ecosystem,
}

pub trait Unlock: Send + Sync + 'static {
    fn unlock(&self, req: &UnlockRequest, cancel: &CancelToken) -> PlugResult<PasskeyOutput>;
    fn register(&self, req: &RegisterRequest, cancel: &CancelToken) -> PlugResult<RegisteredPasskey>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PublicIdentity {
    pub sign: [u8; 32],
    pub box_key: [u8; 32],
}

pub trait RunnerPool: Send + Sync + 'static {
    fn identity(&self) -> PlugResult<PublicIdentity>;
    fn verify(&self, token: &[u8], runner: &PublicIdentity, cancel: &CancelToken) -> PlugResult<u64>;
    fn attest(&self, _evidence: &[u8], _runner: &PublicIdentity, _cancel: &CancelToken) -> PlugResult<()> {
        Ok(())
    }
    fn renew(&self, _runner: &PublicIdentity, _cancel: &CancelToken) -> PlugResult<u64> {
        Err(PlugError::PERMISSION)
    }
}

#[derive(Debug, Clone)]
pub struct PoolJoined {
    pub space: [u8; 16],
    pub name: String,
    pub relay: String,
    pub relay_key: Vec<u8>,
    pub proof: Vec<u8>,
}

pub trait PoolUser: Send + Sync + 'static {
    fn identity(&self) -> PlugResult<PublicIdentity>;
    fn joined(&self, joined: PoolJoined);
}

pub trait Credentials: Send + Sync + 'static {
    fn spaces(&self) -> Vec<[u8; 16]>;
    fn produce(&self, space: &[u8; 16], binding: &[u8], cancel: &CancelToken) -> PlugResult<Vec<u8>>;
}

#[derive(Clone, Default)]
struct Plugs {
    store: Option<Arc<dyn SealedStore>>,
    unlock: Option<Arc<dyn Unlock>>,
    pool: Option<Arc<dyn RunnerPool>>,
    user: Option<Arc<dyn PoolUser>>,
    creds: Option<Arc<dyn Credentials>>,
}

impl Plugs {
    fn names(&self) -> Vec<&'static str> {
        let mut v = Vec::new();
        if self.store.is_some() {
            v.push("sealed_store");
        }
        if self.unlock.is_some() {
            v.push("unlock");
        }
        if self.pool.is_some() {
            v.push("runner_pool");
        }
        if self.user.is_some() {
            v.push("pool_user");
        }
        if self.creds.is_some() {
            v.push("credentials");
        }
        v
    }
}

#[derive(Default)]
pub struct HostBuilder {
    socket: Option<PathBuf>,
    plugs: Plugs,
    replace: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostState {
    Registered(Vec<String>),
    Refused(Status),
    Disconnected,
}

pub struct Host {
    stop: Arc<AtomicBool>,
    current: Arc<Mutex<Option<Sock>>>,
    thread: Option<JoinHandle<()>>,
    states: Arc<Queue<HostState>>,
}

impl HostBuilder {
    pub fn new() -> Self {
        HostBuilder::default()
    }

    pub fn socket(mut self, p: impl Into<PathBuf>) -> Self {
        self.socket = Some(p.into());
        self
    }

    pub fn sealed_store(mut self, s: impl SealedStore) -> Self {
        self.plugs.store = Some(Arc::new(s));
        self
    }

    pub fn unlock(mut self, u: impl Unlock) -> Self {
        self.plugs.unlock = Some(Arc::new(u));
        self
    }

    pub fn runner_pool(mut self, p: impl RunnerPool) -> Self {
        self.plugs.pool = Some(Arc::new(p));
        self
    }

    pub fn pool_user(mut self, p: impl PoolUser) -> Self {
        self.plugs.user = Some(Arc::new(p));
        self
    }

    pub fn credentials(mut self, c: impl Credentials) -> Self {
        self.plugs.creds = Some(Arc::new(c));
        self
    }

    pub fn replace(mut self, yes: bool) -> Self {
        self.replace = yes;
        self
    }

    pub fn spawn(self) -> Result<Host> {
        let path = match self.socket {
            Some(p) => p,
            None => socket_path().ok_or_else(|| Error::Protocol("cannot determine the daemon socket path".into()))?,
        };
        let stop = Arc::new(AtomicBool::new(false));
        let current = Arc::new(Mutex::new(None));
        let states = Queue::new();
        let (s2, c2, q2, plugs, replace) = (stop.clone(), current.clone(), states.clone(), self.plugs, self.replace);
        let thread = std::thread::Builder::new()
            .name("ondb-host".into())
            .spawn(move || host_loop(path, plugs, replace, s2, c2, q2))?;
        Ok(Host {
            stop,
            current,
            thread: Some(thread),
            states,
        })
    }
}

impl Host {
    pub fn next_state(&self, timeout: Option<Duration>) -> Option<HostState> {
        self.states.pop_blocking(timeout)
    }

    pub fn wait_registered(&self, timeout: Duration) -> Result<Vec<String>> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let now = std::time::Instant::now();
            if now >= deadline {
                return Err(Error::Status(Status::TIMEOUT));
            }
            match self.states.pop_blocking(Some(deadline - now)) {
                Some(HostState::Registered(p)) => return Ok(p),
                Some(HostState::Refused(s)) => return Err(Error::Status(s)),
                Some(HostState::Disconnected) => continue,
                None => return Err(Error::Status(Status::TIMEOUT)),
            }
        }
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(s) = self.current.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn host_loop(path: PathBuf, plugs: Plugs, replace: bool, stop: Arc<AtomicBool>, current: Arc<Mutex<Option<Sock>>>, states: Arc<Queue<HostState>>) {
    let mut delay = Duration::from_millis(50);
    while !stop.load(Ordering::Acquire) {
        let sock = match sock_connect(&path) {
            Ok(s) => s,
            Err(_) => {
                std::thread::sleep(delay);
                delay = (delay * 2).min(Duration::from_secs(2));
                continue;
            }
        };
        delay = Duration::from_millis(50);
        match serve(sock, &plugs, replace, &stop, &current, &states) {
            Some(st) if st == Status::UNSUPPORTED || st == Status::INVALID || st == Status::BAD_REQUEST || st == Status::UNKNOWN_OP => {
                states.push(HostState::Refused(st));
                return;
            }
            Some(st) => {
                states.push(HostState::Refused(st));
                std::thread::sleep(Duration::from_millis(500));
            }
            None => {
                if !stop.load(Ordering::Acquire) {
                    states.push(HostState::Disconnected);
                }
            }
        }
        *current.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

fn serve(mut sock: Sock, plugs: &Plugs, replace: bool, stop: &AtomicBool, current: &Mutex<Option<Sock>>, states: &Queue<HostState>) -> Option<Status> {
    let reader = sock.try_clone().ok()?;
    *current.lock().unwrap_or_else(|e| e.into_inner()) = sock.try_clone().ok();
    if stop.load(Ordering::Acquire) {
        return None;
    }
    let mut req = Writer::new();
    req.u8(API_VERSION).uvarint(REGISTER_CODE);
    let names = plugs.names();
    req.uvarint(names.len() as u64);
    for n in &names {
        req.str(n);
    }
    req.bool(replace);
    let identity = match (&plugs.pool, &plugs.user) {
        (Some(p), _) => Some(p.identity()),
        (None, Some(u)) => Some(u.identity()),
        _ => None,
    };
    match identity {
        Some(Ok(id)) => {
            let mut b = id.sign.to_vec();
            b.extend_from_slice(&id.box_key);
            req.bytes(&b);
        }
        Some(Err(e)) => return Some(e.0),
        None => {
            req.bytes(&[]);
        }
    }
    let spaces = plugs.creds.as_ref().map(|c| c.spaces()).unwrap_or_default();
    req.uvarint(spaces.len() as u64);
    for sp in &spaces {
        req.buf.extend_from_slice(sp);
    }
    let mut first = frame::hello().to_vec();
    first.extend(frame::encode(frame::CALL, &[&1u64.to_le_bytes(), &[0], &0u64.to_le_bytes(), &req.buf]));
    sock.write_all(&first).ok()?;
    let writer = Arc::new(Mutex::new(sock));
    let mut fr = FrameReader::new(reader, Default::default(), Default::default());
    let tokens: Arc<Mutex<HashMap<u64, CancelToken>>> = Default::default();
    loop {
        let f = fr.next().ok()?;
        match f.kind {
            frame::RESULT if f.tag() == Some(1) && f.payload.len() >= 9 => {
                let st = Status(f.payload[8]);
                if st != Status::OK {
                    return Some(st);
                }
                let mut r = Reader::new(&f.payload[9..]);
                let got = r.list().into_iter().map(|b| String::from_utf8_lossy(&b).into_owned()).collect();
                states.push(HostState::Registered(got));
            }
            frame::PLUG if f.payload.len() >= 8 => {
                let tag = f.tag().unwrap_or(0);
                let token = CancelToken::default();
                if tag != 0 {
                    tokens.lock().unwrap_or_else(|e| e.into_inner()).insert(tag, token.clone());
                }
                let (plugs, writer, tokens) = (plugs.clone(), writer.clone(), tokens.clone());
                let body = f.payload[8..].to_vec();
                let spawned = std::thread::Builder::new().name("ondb-plug".into()).spawn(move || {
                    let (st, reply) = handle(&plugs, &body, &token);
                    let live = tokens.lock().unwrap_or_else(|e| e.into_inner()).remove(&tag).is_some();
                    if tag == 0 || !live {
                        return;
                    }
                    let fr = frame::encode(frame::PLUG_REPLY, &[&tag.to_le_bytes(), &[st.0], &reply]);
                    let _ = writer.lock().unwrap_or_else(|e| e.into_inner()).write_all(&fr);
                });
                if spawned.is_err() {
                    return None;
                }
            }
            frame::PLUG_CANCEL => {
                if let Some(tag) = f.tag() {
                    if let Some(t) = tokens.lock().unwrap_or_else(|e| e.into_inner()).remove(&tag) {
                        t.cancel();
                    }
                }
            }
            _ => {}
        }
    }
}

fn arr32(b: &[u8]) -> Option<[u8; 32]> {
    b.try_into().ok()
}

fn handle(p: &Plugs, body: &[u8], cancel: &CancelToken) -> (Status, Vec<u8>) {
    match run(p, body, cancel) {
        Ok(w) => (Status::OK, w.buf),
        Err(e) => (e.0, Vec::new()),
    }
}

fn run(p: &Plugs, body: &[u8], cancel: &CancelToken) -> PlugResult<Writer> {
    let mut r = Reader::new(body);
    if r.u8() != PLUG_VERSION {
        return Err(PlugError(Status::BAD_REQUEST));
    }
    let code = r.uvarint();
    let mut w = Writer::new();
    let bad = PlugError(Status::BAD_REQUEST);
    match code {
        1..=3 => {
            let s = p.store.as_ref().ok_or(PlugError::UNSUPPORTED)?;
            let subject = r.bytes();
            match code {
                1 => {
                    if !r.done() {
                        return Err(bad);
                    }
                    let rec = s.get(&subject, cancel)?.ok_or(PlugError::NOT_FOUND)?;
                    w.bytes(&rec.record).list(&rec.entries);
                }
                2 => {
                    let record = r.bytes();
                    let prev = r.uvarint();
                    let seq = r.uvarint();
                    if !r.done() {
                        return Err(bad);
                    }
                    s.put(&subject, &record, prev, seq, cancel)?;
                }
                _ => {
                    let entry = r.bytes();
                    if !r.done() {
                        return Err(bad);
                    }
                    s.add(&subject, &entry, cancel)?;
                }
            }
        }
        4 => {
            let u = p.unlock.as_ref().ok_or(PlugError::UNSUPPORTED)?;
            let rp_user = r.bytes();
            let creds = r.list();
            let salts = r.list();
            let mode = r.uvarint();
            if !r.done() || creds.len() != salts.len() {
                return Err(bad);
            }
            let mut options = Vec::with_capacity(creds.len());
            for (c, s) in creds.into_iter().zip(salts) {
                options.push(UnlockOption { credential: c, salt: arr32(&s).ok_or(bad)? });
            }
            let mode = if mode == 1 { UnlockMode::OtherDevice } else { UnlockMode::ThisDevice };
            let out = u.unlock(&UnlockRequest { rp_user, options, mode }, cancel)?;
            w.bytes(&out.credential).bytes(&out.prf);
        }
        5 => {
            let u = p.unlock.as_ref().ok_or(PlugError::UNSUPPORTED)?;
            let rp_user = r.bytes();
            let label = r.str();
            let salt = arr32(&r.bytes()).ok_or(bad)?;
            if !r.done() {
                return Err(bad);
            }
            let out = u.register(&RegisterRequest { rp_user, label, salt }, cancel)?;
            w.bytes(&out.credential).bytes(&out.prf).uvarint(out.ecosystem as u64);
        }
        7 | 8 => {
            let pool = p.pool.as_ref().ok_or(PlugError::UNSUPPORTED)?;
            let data = r.bytes();
            let sign = arr32(&r.bytes()).ok_or(bad)?;
            let box_key = arr32(&r.bytes()).ok_or(bad)?;
            if !r.done() {
                return Err(bad);
            }
            let runner = PublicIdentity { sign, box_key };
            if code == 7 {
                let lease = pool.verify(&data, &runner, cancel)?;
                w.uvarint(lease);
            } else {
                pool.attest(&data, &runner, cancel)?;
            }
        }
        15 => {
            let pool = p.pool.as_ref().ok_or(PlugError::UNSUPPORTED)?;
            let sign = arr32(&r.bytes()).ok_or(bad)?;
            let box_key = arr32(&r.bytes()).ok_or(bad)?;
            if !r.done() {
                return Err(bad);
            }
            let lease = pool.renew(&PublicIdentity { sign, box_key }, cancel)?;
            w.uvarint(lease);
        }
        10 => {
            let user = p.user.as_ref().ok_or(PlugError::UNSUPPORTED)?;
            let space = r.id();
            let name = r.str();
            let relay = r.str();
            let relay_key = r.bytes();
            let proof = r.bytes();
            if !r.done() {
                return Err(bad);
            }
            user.joined(PoolJoined { space, name, relay, relay_key, proof });
        }
        12 => {
            let c = p.creds.as_ref().ok_or(PlugError::UNSUPPORTED)?;
            let space = r.id();
            let binding = r.bytes();
            if !r.done() {
                return Err(bad);
            }
            let cred = c.produce(&space, &binding, cancel)?;
            w.bytes(&cred);
        }
        _ => return Err(PlugError::UNSUPPORTED),
    }
    Ok(w)
}
