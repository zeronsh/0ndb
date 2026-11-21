use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::time::Instant;

use ondb::{AccountRecord, CancelToken, Ecosystem, PasskeyOutput, PlugError, PlugResult, RegisterRequest, RegisteredPasskey, SealedStore, Unlock, UnlockRequest};

pub struct DirStore {
    pub dir: PathBuf,
}

impl DirStore {
    fn path(&self, subject: &[u8], suffix: &str) -> PathBuf {
        self.dir.join(format!("{}{suffix}", ondb::hex(subject)))
    }
}

impl SealedStore for DirStore {
    fn get(&self, subject: &[u8], _cancel: &CancelToken) -> PlugResult<Option<AccountRecord>> {
        let record = match std::fs::read(self.path(subject, ".record")) {
            Ok(r) => r,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(PlugError::IO),
        };
        let raw = std::fs::read(self.path(subject, ".entries")).unwrap_or_default();
        let mut entries = Vec::new();
        let mut pos = 0;
        while pos + 4 <= raw.len() {
            let n = u32::from_le_bytes(raw[pos..pos + 4].try_into().expect("4 bytes")) as usize;
            if pos + 4 + n > raw.len() {
                break;
            }
            entries.push(raw[pos + 4..pos + 4 + n].to_vec());
            pos += 4 + n;
        }
        Ok(Some(AccountRecord { record, entries }))
    }

    fn put(&self, subject: &[u8], record: &[u8], prev_seq: u64, seq: u64, _cancel: &CancelToken) -> PlugResult<()> {
        let path = self.path(subject, ".record");
        let seq_path = self.path(subject, ".seq");
        let stored: u64 = std::fs::read_to_string(&seq_path).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0);
        if std::fs::read(&path).ok().as_deref() == Some(record) {
            return Ok(());
        }
        if stored != prev_seq {
            return Err(PlugError::CONFLICT);
        }
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, record).map_err(|_| PlugError::IO)?;
        std::fs::rename(&tmp, &path).map_err(|_| PlugError::IO)?;
        std::fs::write(&seq_path, seq.to_string()).map_err(|_| PlugError::IO)
    }

    fn add(&self, subject: &[u8], entry: &[u8], _cancel: &CancelToken) -> PlugResult<()> {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(self.path(subject, ".entries")).map_err(|_| PlugError::IO)?;
        f.write_all(&(entry.len() as u32).to_le_bytes()).map_err(|_| PlugError::IO)?;
        f.write_all(entry).map_err(|_| PlugError::IO)?;
        f.sync_data().map_err(|_| PlugError::IO)
    }
}

pub struct TestPasskey {
    pub path: PathBuf,
}

impl TestPasskey {
    fn load_or_create(&self) -> PlugResult<(Vec<u8>, [u8; 32])> {
        if let Ok(b) = std::fs::read(&self.path) {
            if b.len() == 48 {
                let mut seed = [0u8; 32];
                seed.copy_from_slice(&b[16..]);
                return Ok((b[..16].to_vec(), seed));
            }
        }
        let mut b = [0u8; 48];
        let now = Instant::now();
        for (i, x) in b.iter_mut().enumerate() {
            let mut h = DefaultHasher::new();
            (std::process::id(), i, format!("{now:?}"), std::time::SystemTime::now()).hash(&mut h);
            *x = h.finish() as u8;
        }
        std::fs::write(&self.path, b).map_err(|_| PlugError::IO)?;
        let mut seed = [0u8; 32];
        seed.copy_from_slice(&b[16..]);
        Ok((b[..16].to_vec(), seed))
    }

    fn prf(seed: &[u8; 32], salt: &[u8; 32]) -> [u8; 32] {
        let mut out = [0u8; 32];
        for (i, chunk) in out.chunks_mut(8).enumerate() {
            let mut h = DefaultHasher::new();
            (seed, salt, i).hash(&mut h);
            chunk.copy_from_slice(&h.finish().to_le_bytes());
        }
        out
    }
}

impl Unlock for TestPasskey {
    fn unlock(&self, req: &UnlockRequest, _cancel: &CancelToken) -> PlugResult<PasskeyOutput> {
        let (cred, seed) = self.load_or_create()?;
        let opt = req.options.iter().find(|o| o.credential == cred).ok_or(PlugError::NOT_FOUND)?;
        Ok(PasskeyOutput {
            credential: cred,
            prf: Self::prf(&seed, &opt.salt),
        })
    }

    fn register(&self, req: &RegisterRequest, _cancel: &CancelToken) -> PlugResult<RegisteredPasskey> {
        let (cred, seed) = self.load_or_create()?;
        Ok(RegisteredPasskey {
            credential: cred,
            prf: Self::prf(&seed, &req.salt),
            ecosystem: Ecosystem::Test,
        })
    }
}


pub fn arg_or_env(i: usize, env: &str, default: &str) -> String {
    std::env::args().nth(i).or_else(|| std::env::var(env).ok()).unwrap_or_else(|| default.to_string())
}
