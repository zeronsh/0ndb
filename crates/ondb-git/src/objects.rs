//! Reading blobs from a repository's object database through one long-lived
//! `git cat-file --batch-command` process, so lookups cost a pipe round trip
//! rather than a process spawn. The process is restarted if it dies.

use std::collections::HashSet;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

use crate::Error;

struct Proc {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

/// A repository's git objects, by 20-byte object id.
pub struct Objects {
    /// The git dir (`--git-dir`): a worktree's own, or the common one.
    git_dir: PathBuf,
    proc: Mutex<Option<Proc>>,
    /// Blob ids known to exist (from the index, or seen), to answer
    /// `contains` without a round trip. Loaded on first use; dropped by
    /// [`Objects::release`].
    known: Mutex<Option<HashSet<[u8; 20]>>>,
    pins: Mutex<Pins>,
}

/// Blobs kept reachable from one ref, as a chain of commits whose trees list
/// them, so git's garbage collection never prunes content relied on.
struct Pins {
    reference: Option<String>,
    tip: Option<String>,
    pinned: HashSet<[u8; 20]>,
}

fn hex(oid: &[u8; 20]) -> String {
    oid.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(s: &str) -> Option<[u8; 20]> {
    if s.len() != 40 {
        return None;
    }
    let mut out = [0u8; 20];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

impl Objects {
    /// Objects of the repository whose git dir is `git_dir` (a linked
    /// worktree's own dir, or the common dir). Nothing runs until the first
    /// lookup.
    pub fn open(git_dir: impl AsRef<Path>) -> Objects {
        Objects {
            git_dir: git_dir.as_ref().to_path_buf(),
            proc: Mutex::new(None),
            known: Mutex::new(None),
            pins: Mutex::new(Pins { reference: None, tip: None, pinned: HashSet::new() }),
        }
    }

    fn git(&self) -> crate::cmd::Cmd {
        crate::cmd::Cmd::git().arg("--git-dir").arg(self.git_dir.to_string_lossy().into_owned())
    }

    /// Every blob the index references (one `git ls-files -s`).
    fn index_blobs(&self) -> HashSet<[u8; 20]> {
        let mut known = HashSet::new();
        let out = self.git().args(["ls-files", "-s", "-z"]).limit(512 << 20).ok();
        for f in out.iter().flat_map(|o| o.fields()) {
            // "<mode> <oid> <stage>\t<path>"
            if f.starts_with("100")
                && let Some(oid) = f.split(' ').nth(1).and_then(unhex)
            {
                known.insert(oid);
            }
        }
        known
    }

    /// Drops cached lookups and stops the `cat-file` process; both come back
    /// on the next lookup. For idle worktrees.
    pub fn release(&self) {
        *self.known.lock().unwrap_or_else(|p| p.into_inner()) = None;
        self.pins.lock().unwrap_or_else(|p| p.into_inner()).pinned = HashSet::new();
        if let Some(mut p) = self.proc.lock().unwrap_or_else(|p| p.into_inner()).take() {
            drop(p.stdin);
            let _ = p.child.wait();
        }
    }

    /// Pins go to `reference` (e.g. `refs/0ndb/<history>`), continuing any
    /// chain already there.
    pub fn pin_to(self, reference: impl Into<String>) -> Objects {
        let reference = reference.into();
        let tip = self
            .git()
            .args(["rev-parse", "-q", "--verify", &format!("{reference}^{{commit}}")])
            .output()
            .ok()
            .filter(|o| o.success())
            .map(|o| o.text().trim().to_string());
        *self.pins.lock().unwrap_or_else(|p| p.into_inner()) = Pins { reference: Some(reference), tip, pinned: HashSet::new() };
        self
    }

    /// Makes `oids` reachable from the pin ref. Already pinned ones are
    /// skipped. Without a pin ref nothing can be pinned.
    pub fn pin(&self, oids: &[[u8; 20]]) -> bool {
        let mut pins = self.pins.lock().unwrap_or_else(|p| p.into_inner());
        let Some(reference) = pins.reference.clone() else { return false };
        let mut fresh: Vec<[u8; 20]> = oids.iter().filter(|o| !pins.pinned.contains(*o)).copied().collect();
        fresh.sort();
        fresh.dedup();
        if fresh.is_empty() {
            return true;
        }
        let listing: String = fresh.iter().map(|o| format!("100644 blob {h}\t{h}\n", h = hex(o))).collect();
        let run = || -> Result<String, Error> {
            let git = || self.git();
            // Every listed blob was just confirmed present; skip mktree's
            // per-object existence check.
            let tree = git().args(["mktree", "--missing"]).stdin(listing.into_bytes()).ok()?.text().trim().to_string();
            let mut commit = git()
                .args(["commit-tree", &tree, "-m", "0ndb: keep content referenced by history"])
                .env("GIT_AUTHOR_NAME", "0ndb")
                .env("GIT_AUTHOR_EMAIL", "0ndb@localhost")
                .env("GIT_COMMITTER_NAME", "0ndb")
                .env("GIT_COMMITTER_EMAIL", "0ndb@localhost");
            if let Some(tip) = &pins.tip {
                commit = commit.args(["-p", tip]);
            }
            let commit = commit.ok()?.text().trim().to_string();
            let mut update = git().args(["update-ref", "-m", "0ndb pin", &reference, &commit]);
            if let Some(tip) = &pins.tip {
                update = update.arg(tip.clone());
            }
            update.ok()?;
            Ok(commit)
        };
        match run() {
            Ok(commit) => {
                pins.tip = Some(commit);
                pins.pinned.extend(fresh);
                true
            }
            Err(e) => {
                tracing::warn!(error = %e, "pinning git objects failed; content will be stored by 0ndb");
                false
            }
        }
    }

    fn spawn(&self) -> Result<Proc, Error> {
        let mut child = Command::new("git")
            .arg("--git-dir")
            .arg(&self.git_dir)
            .args(["cat-file", "--batch-command"])
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GIT_TERMINAL_PROMPT", "0")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child.stdin.take().ok_or_else(|| Error::Invalid("no stdin".into()))?;
        let stdout = BufReader::new(child.stdout.take().ok_or_else(|| Error::Invalid("no stdout".into()))?);
        Ok(Proc { child, stdin, stdout })
    }

    /// Runs one command; `want_body` reads the object's bytes too.
    fn query(&self, cmd: &str, oid: &[u8; 20], want_body: bool) -> Option<(u64, Option<Vec<u8>>)> {
        let mut guard = self.proc.lock().unwrap_or_else(|p| p.into_inner());
        for attempt in 0..2 {
            if guard.is_none() {
                *guard = self.spawn().ok();
            }
            let p = guard.as_mut()?;
            let r = (|| -> std::io::Result<Option<(u64, Option<Vec<u8>>)>> {
                writeln!(p.stdin, "{cmd} {}", hex(oid))?;
                p.stdin.flush()?;
                let mut header = String::new();
                p.stdout.read_line(&mut header)?;
                let parts: Vec<&str> = header.split_whitespace().collect();
                if parts.len() < 3 || parts[1] == "missing" {
                    return Ok(None);
                }
                let size: u64 = parts[2].parse().unwrap_or(0);
                if !want_body {
                    return Ok(Some((size, None)));
                }
                let mut body = vec![0u8; size as usize];
                p.stdout.read_exact(&mut body)?;
                let mut nl = [0u8; 1];
                p.stdout.read_exact(&mut nl)?;
                Ok(Some((size, Some(body))))
            })();
            match r {
                Ok(v) => return v,
                Err(_) if attempt == 0 => {
                    if let Some(mut dead) = guard.take() {
                        let _ = dead.child.kill();
                        let _ = dead.child.wait();
                    }
                }
                Err(_) => return None,
            }
        }
        None
    }

    /// Writes the file at `path` (absolute) into the object database as-is
    /// (no filters), returning its blob id.
    pub fn write_file(&self, path: &Path) -> Option<[u8; 20]> {
        let out = self
            .git()
            .args(["hash-object", "-w", "--no-filters", "--"])
            .arg(path.to_string_lossy().into_owned())
            .timeout(std::time::Duration::from_secs(600))
            .ok()
            .ok()?;
        let oid = unhex(out.text().trim())?;
        self.known.lock().unwrap_or_else(|p| p.into_inner()).get_or_insert_with(HashSet::new).insert(oid);
        Some(oid)
    }

    /// Streams a blob's bytes into `out` without holding them in memory.
    pub fn copy_to(&self, oid: &[u8; 20], out: &mut impl std::io::Write) -> std::io::Result<u64> {
        let mut child = Command::new("git")
            .arg("--git-dir")
            .arg(&self.git_dir)
            .args(["cat-file", "blob", &hex(oid)])
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let n = std::io::copy(child.stdout.as_mut().ok_or_else(|| std::io::Error::other("no stdout"))?, out)?;
        if !child.wait()?.success() {
            return Err(std::io::Error::other(format!("git cat-file blob {} failed", hex(oid))));
        }
        Ok(n)
    }

    /// Whether the object database has this blob.
    pub fn contains(&self, oid: &[u8; 20]) -> bool {
        {
            let mut known = self.known.lock().unwrap_or_else(|p| p.into_inner());
            if known.get_or_insert_with(|| self.index_blobs()).contains(oid) {
                return true;
            }
        }
        let found = self.query("info", oid, false).is_some();
        if found {
            self.known.lock().unwrap_or_else(|p| p.into_inner()).get_or_insert_with(HashSet::new).insert(*oid);
        }
        found
    }

    /// The blob's bytes, if the object database has it.
    pub fn read(&self, oid: &[u8; 20]) -> Option<Vec<u8>> {
        self.query("contents", oid, true).and_then(|(_, b)| b)
    }
}

impl Drop for Objects {
    fn drop(&mut self) {
        if let Some(mut p) = self.proc.lock().unwrap_or_else(|p| p.into_inner()).take() {
            drop(p.stdin);
            let _ = p.child.wait();
        }
    }
}
