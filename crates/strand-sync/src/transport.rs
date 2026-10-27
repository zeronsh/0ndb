//! Byte transports and blocking drivers. These are conveniences; the client
//! and relay state machines don't depend on them.

use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};

use crate::SyncError;
use crate::client::Client;
use crate::protocol::Message;
use crate::relay::{PeerId, Relay, RelayStore};
use crate::replica::Replica;

const MAX_FRAME: usize = 256 << 20;

pub trait Transport {
    fn send(&mut self, msg: &Message) -> Result<(), SyncError>;
    /// `Ok(None)` on timeout.
    fn recv_timeout(&mut self, timeout: Duration) -> Result<Option<Message>, SyncError>;
}

/// In-process transport (tests, embedding a relay in the same process).
pub struct MemoryTransport {
    tx: Sender<Message>,
    rx: Receiver<Message>,
}

pub fn memory_pair() -> (MemoryTransport, MemoryTransport) {
    let (a_tx, a_rx) = unbounded();
    let (b_tx, b_rx) = unbounded();
    (MemoryTransport { tx: a_tx, rx: b_rx }, MemoryTransport { tx: b_tx, rx: a_rx })
}

impl Transport for MemoryTransport {
    fn send(&mut self, msg: &Message) -> Result<(), SyncError> {
        self.tx.send(msg.clone()).map_err(|_| SyncError::Closed)
    }

    fn recv_timeout(&mut self, timeout: Duration) -> Result<Option<Message>, SyncError> {
        match self.rx.recv_timeout(timeout) {
            Ok(m) => Ok(Some(m)),
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => Err(SyncError::Closed),
        }
    }
}

/// Length-prefixed frames over TCP.
pub struct TcpTransport {
    stream: TcpStream,
}

impl TcpTransport {
    pub fn connect(addr: impl ToSocketAddrs) -> Result<Self, SyncError> {
        let stream = TcpStream::connect(addr)?;
        stream.set_nodelay(true)?;
        Ok(TcpTransport { stream })
    }

    pub fn from_stream(stream: TcpStream) -> Self {
        TcpTransport { stream }
    }
}

fn write_frame(w: &mut impl Write, msg: &Message) -> io::Result<()> {
    let bytes = msg.encode();
    w.write_all(&(bytes.len() as u32).to_le_bytes())?;
    w.write_all(&bytes)?;
    w.flush()
}

fn read_frame(r: &mut impl Read) -> Result<Message, SyncError> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let len = u32::from_le_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(SyncError::Protocol(format!("frame of {len} bytes exceeds limit")));
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    Message::decode(&buf).map_err(|e| SyncError::Protocol(e.to_string()))
}

impl Transport for TcpTransport {
    fn send(&mut self, msg: &Message) -> Result<(), SyncError> {
        Ok(write_frame(&mut self.stream, msg)?)
    }

    fn recv_timeout(&mut self, timeout: Duration) -> Result<Option<Message>, SyncError> {
        self.stream.set_read_timeout(Some(timeout.max(Duration::from_millis(1))))?;
        let mut peek = [0u8; 1];
        match self.stream.peek(&mut peek) {
            Ok(0) => return Err(SyncError::Closed),
            Ok(_) => {}
            Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => return Ok(None),
            Err(e) => return Err(e.into()),
        }
        self.stream.set_read_timeout(None)?;
        read_frame(&mut self.stream).map(Some)
    }
}

/// Drives a client over a transport until `stop` is set or the transport
/// closes. `changes` wakes it to push local commits promptly.
pub fn run_client<R: Replica, T: Transport, E>(
    client: &mut Client<R>,
    transport: &mut T,
    changes: &Receiver<E>,
    stop: &AtomicBool,
) -> Result<(), SyncError> {
    for m in client.connect()? {
        transport.send(&m)?;
    }
    while !stop.load(Ordering::Relaxed) {
        if let Some(msg) = transport.recv_timeout(Duration::from_millis(25))? {
            for m in client.handle(msg)? {
                transport.send(&m)?;
            }
        }
        if changes.try_iter().count() > 0 {
            for m in client.poll()? {
                transport.send(&m)?;
            }
        }
    }
    client.disconnected();
    Ok(())
}

/// Serves a relay over TCP: one reader thread per connection, all sharing
/// the relay state machine.
pub fn serve_tcp<S: RelayStore + 'static>(
    listener: TcpListener,
    relay: Arc<Mutex<Relay<S>>>,
    stop: Arc<AtomicBool>,
) -> io::Result<()> {
    let peers: Arc<Mutex<std::collections::HashMap<PeerId, Sender<Message>>>> = Arc::default();
    let next = AtomicU64::new(1);
    listener.set_nonblocking(true)?;
    while !stop.load(Ordering::Relaxed) {
        let stream = match listener.accept() {
            Ok((s, _)) => s,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            Err(e) => return Err(e),
        };
        stream.set_nonblocking(false)?;
        stream.set_nodelay(true)?;
        let id = next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = unbounded::<Message>();
        peers.lock().unwrap_or_else(|p| p.into_inner()).insert(id, tx);
        let mut writer = stream.try_clone()?;
        std::thread::spawn(move || {
            for m in rx {
                if write_frame(&mut writer, &m).is_err() {
                    break;
                }
            }
        });
        let (relay, peers) = (relay.clone(), peers.clone());
        let mut reader = stream;
        std::thread::spawn(move || {
            while let Ok(msg) = read_frame(&mut reader) {
                let out = relay.lock().unwrap_or_else(|p| p.into_inner()).handle(id, msg);
                let peers = peers.lock().unwrap_or_else(|p| p.into_inner());
                for o in out {
                    if let Some(tx) = peers.get(&o.to) {
                        let _ = tx.send(o.message);
                    }
                }
            }
            relay.lock().unwrap_or_else(|p| p.into_inner()).disconnect(id);
            peers.lock().unwrap_or_else(|p| p.into_inner()).remove(&id);
        });
    }
    Ok(())
}
