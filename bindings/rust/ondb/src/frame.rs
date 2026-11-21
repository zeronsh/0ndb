use std::io::{self, Read};

pub(crate) const MAGIC: &[u8; 4] = b"0NDB";
pub(crate) const PROTO_VERSION: u8 = 1;
pub(crate) const FRAME_MAX: usize = 64 << 20;

pub(crate) const CALL: u8 = 1;
pub(crate) const RESULT: u8 = 2;
pub(crate) const SUBSCRIBE: u8 = 3;
pub(crate) const DELTAS: u8 = 4;
pub(crate) const UNSUBSCRIBE: u8 = 5;
pub(crate) const EVENTS: u8 = 7;
pub(crate) const EVENT: u8 = 8;
pub(crate) const CANCEL: u8 = 9;
pub(crate) const PLUG: u8 = 10;
pub(crate) const PLUG_REPLY: u8 = 11;
pub(crate) const PLUG_CANCEL: u8 = 12;
pub(crate) const GAP: u8 = 13;

pub(crate) const FLAG_JSON: u8 = 1;
pub(crate) const FLAG_COMPACT: u8 = 2;

pub(crate) fn hello() -> [u8; 5] {
    [MAGIC[0], MAGIC[1], MAGIC[2], MAGIC[3], PROTO_VERSION]
}

pub(crate) fn encode(kind: u8, parts: &[&[u8]]) -> Vec<u8> {
    let n: usize = parts.iter().map(|p| p.len()).sum();
    let mut out = Vec::with_capacity(5 + n);
    out.extend_from_slice(&(n as u32).to_le_bytes());
    out.push(kind);
    for p in parts {
        out.extend_from_slice(p);
    }
    out
}

pub(crate) struct Frame {
    pub kind: u8,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn tag(&self) -> Option<u64> {
        self.payload
            .get(..8)
            .map(|b| u64::from_le_bytes(b.try_into().expect("8 bytes")))
    }
}

pub(crate) struct FrameReader<R: Read> {
    inner: R,
    buf: Vec<u8>,
    start: usize,
    reads: std::sync::Arc<std::sync::atomic::AtomicU64>,
    bytes: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

impl<R: Read> FrameReader<R> {
    pub fn new(inner: R, reads: std::sync::Arc<std::sync::atomic::AtomicU64>, bytes: std::sync::Arc<std::sync::atomic::AtomicU64>) -> Self {
        FrameReader {
            inner,
            buf: Vec::with_capacity(64 << 10),
            start: 0,
            reads,
            bytes,
        }
    }

    pub fn next(&mut self) -> io::Result<Frame> {
        loop {
            let avail = &self.buf[self.start..];
            if avail.len() >= 5 {
                let n = u32::from_le_bytes(avail[..4].try_into().expect("4 bytes")) as usize;
                if n > FRAME_MAX {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
                }
                if avail.len() >= 5 + n {
                    let kind = avail[4];
                    let payload = avail[5..5 + n].to_vec();
                    self.start += 5 + n;
                    if self.start == self.buf.len() {
                        self.buf.clear();
                        self.start = 0;
                    }
                    return Ok(Frame { kind, payload });
                }
            }
            if self.start > 0 {
                self.buf.drain(..self.start);
                self.start = 0;
            }
            let len = self.buf.len();
            self.buf.resize(len + (64 << 10), 0);
            let got = loop {
                match self.inner.read(&mut self.buf[len..]) {
                    Ok(n) => break n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => {
                        self.buf.truncate(len);
                        return Err(e);
                    }
                }
            };
            self.reads.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.bytes.fetch_add(got as u64, std::sync::atomic::Ordering::Relaxed);
            self.buf.truncate(len + got);
            if got == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "daemon closed the connection"));
            }
        }
    }
}
