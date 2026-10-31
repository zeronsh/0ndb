use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use ondb_core::{LineEnding, Oid};

/// Prefix of temporary files used for atomic writes; never ingested.
pub const TEMP_PREFIX: &str = ".0ndb-tmp-";
/// Per-root state directory (fences, locks); never ingested.
pub const STATE_DIR: &str = ".0ndb";

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Stat {
    pub mtime_ns: i64,
    pub size: i64,
    pub ino: i64,
}

impl Stat {
    pub fn of(meta: &fs::Metadata) -> Stat {
        Stat { mtime_ns: meta.mtime() * 1_000_000_000 + meta.mtime_nsec(), size: meta.size() as i64, ino: meta.ino() as i64 }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DiskEntry {
    Missing,
    Dir,
    File {
        stat: Stat,
        exec: bool,
    },
    Symlink {
        target: String,
    },
    /// Sockets, fifos, devices: never tracked.
    Other,
}

pub fn abs(root: &Path, rel: &str) -> PathBuf {
    if rel.is_empty() { root.to_path_buf() } else { root.join(rel) }
}

pub fn probe(root: &Path, rel: &str) -> DiskEntry {
    let path = abs(root, rel);
    let Ok(meta) = fs::symlink_metadata(&path) else { return DiskEntry::Missing };
    let ft = meta.file_type();
    if ft.is_symlink() {
        match fs::read_link(&path) {
            Ok(t) => DiskEntry::Symlink { target: t.to_string_lossy().into_owned() },
            Err(_) => DiskEntry::Missing,
        }
    } else if ft.is_dir() {
        DiskEntry::Dir
    } else if ft.is_file() {
        DiskEntry::File { stat: Stat::of(&meta), exec: meta.permissions().mode() & 0o111 != 0 }
    } else {
        DiskEntry::Other
    }
}

/// Reads a file unless it exceeds `limit` bytes.
pub fn read_limited(root: &Path, rel: &str, limit: u64) -> io::Result<Option<Vec<u8>>> {
    let path = abs(root, rel);
    let meta = fs::metadata(&path)?;
    if meta.len() > limit {
        return Ok(None);
    }
    fs::read(&path).map(Some)
}

/// Text vs binary, with newline normalization. A file whose every newline is
/// CRLF is stored with `\n` and remembers `Crlf`; anything mixed is kept
/// verbatim so the round trip is always byte-exact.
pub enum Classified {
    Text { clean: Vec<u8>, ending: LineEnding },
    Binary,
}

pub fn classify(bytes: &[u8]) -> Classified {
    if bytes.contains(&0) || std::str::from_utf8(bytes).is_err() {
        return Classified::Binary;
    }
    let lf = bytes.iter().filter(|b| **b == b'\n').count();
    let crlf = bytes.windows(2).filter(|w| w == b"\r\n").count();
    if crlf > 0 && crlf == lf {
        let mut clean = Vec::with_capacity(bytes.len() - crlf);
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'\r' && bytes.get(i + 1) == Some(&b'\n') {
                i += 1;
                continue;
            }
            clean.push(bytes[i]);
            i += 1;
        }
        Classified::Text { clean, ending: LineEnding::Crlf }
    } else {
        Classified::Text { clean: bytes.to_vec(), ending: LineEnding::Lf }
    }
}

pub fn smudge(clean: &[u8], ending: LineEnding) -> Vec<u8> {
    match ending {
        LineEnding::Lf => clean.to_vec(),
        LineEnding::Crlf => {
            let mut out = Vec::with_capacity(clean.len() + clean.len() / 32);
            for &b in clean {
                if b == b'\n' {
                    out.push(b'\r');
                }
                out.push(b);
            }
            out
        }
    }
}

pub fn oid_of(bytes: &[u8]) -> Oid {
    Oid::of_blob(bytes)
}

pub fn symlink_oid(target: &str) -> Oid {
    Oid::of_blob(target.as_bytes())
}

fn temp_path(dir: &Path) -> PathBuf {
    let n = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    dir.join(format!("{TEMP_PREFIX}{}-{n}", std::process::id()))
}

/// Writes through a temp file in the same directory and renames it into
/// place, so watchers and readers never observe a partial file.
pub fn write_atomic(root: &Path, rel: &str, bytes: &[u8], exec: bool) -> io::Result<Stat> {
    write_atomic_with(root, rel, exec, |f| f.write_all(bytes))
}

/// As [`write_atomic`], with the content written by `fill`.
pub fn write_atomic_with(
    root: &Path,
    rel: &str,
    exec: bool,
    fill: impl FnOnce(&mut fs::File) -> io::Result<()>,
) -> io::Result<Stat> {
    let path = abs(root, rel);
    let dir = path.parent().unwrap_or(root);
    fs::create_dir_all(dir)?;
    let tmp = temp_path(dir);
    let result = (|| {
        let mut f = fs::File::create(&tmp)?;
        fill(&mut f)?;
        f.sync_data()?;
        let mode = if exec { 0o755 } else { 0o644 };
        fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
        if fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir()) {
            fs::remove_dir_all(&path)?;
        }
        fs::rename(&tmp, &path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result?;
    Ok(Stat::of(&fs::metadata(&path)?))
}

pub fn write_symlink(root: &Path, rel: &str, target: &str) -> io::Result<()> {
    let path = abs(root, rel);
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = temp_path(path.parent().unwrap_or(root));
    std::os::unix::fs::symlink(target, &tmp)?;
    if fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir()) {
        fs::remove_dir_all(&path)?;
    }
    fs::rename(&tmp, &path)
}

pub fn set_exec(root: &Path, rel: &str, exec: bool) -> io::Result<Stat> {
    let path = abs(root, rel);
    let mut perms = fs::metadata(&path)?.permissions();
    let mode = perms.mode();
    perms.set_mode(if exec { mode | ((mode & 0o444) >> 2) | 0o100 } else { mode & !0o111 });
    fs::set_permissions(&path, perms)?;
    Ok(Stat::of(&fs::metadata(&path)?))
}

pub fn remove(root: &Path, rel: &str) -> io::Result<()> {
    let path = abs(root, rel);
    match fs::symlink_metadata(&path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
        Ok(m) if m.is_dir() => match fs::remove_dir(&path) {
            // Leave directories that still hold untracked files.
            Err(e) if e.kind() == io::ErrorKind::DirectoryNotEmpty => Ok(()),
            r => r,
        },
        Ok(_) => fs::remove_file(&path),
    }
}

pub fn parent_of(rel: &str) -> &str {
    rel.rsplit_once('/').map(|(p, _)| p).unwrap_or("")
}

pub fn name_of(rel: &str) -> &str {
    rel.rsplit_once('/').map(|(_, n)| n).unwrap_or(rel)
}

pub fn join(parent: &str, name: &str) -> String {
    if parent.is_empty() { name.to_string() } else { format!("{parent}/{name}") }
}

pub fn is_under(path: &str, dir: &str) -> bool {
    dir.is_empty() || path.len() > dir.len() && path.starts_with(dir) && path.as_bytes()[dir.len()] == b'/'
}

/// Paths the mount never ingests regardless of ignore rules.
pub fn is_internal(rel: &str) -> bool {
    rel.split('/').any(|c| c == ".git" || c == STATE_DIR || c.starts_with(TEMP_PREFIX))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_endings_roundtrip() {
        for input in [&b"a\r\nb\r\n"[..], b"a\nb\r\n", b"no newline", b"a\r\nb", b"\r\n"] {
            match classify(input) {
                Classified::Text { clean, ending } => assert_eq!(smudge(&clean, ending), input),
                Classified::Binary => panic!("text misclassified"),
            }
        }
        assert!(matches!(classify(b"\x00\x01"), Classified::Binary));
    }

    #[test]
    fn path_helpers() {
        assert!(is_under("a/b", "a"));
        assert!(!is_under("ab", "a"));
        assert!(is_internal(".git/HEAD"));
        assert!(is_internal("x/.0ndb-tmp-1-2"));
        assert!(!is_internal("src/main.rs"));
    }
}
