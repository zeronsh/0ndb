//! Running `git` and provider CLIs: bounded time, bounded output, never
//! interactive, never holding locks a user's own git would trip on.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::Error;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);
const DEFAULT_LIMIT: usize = 8 << 20;

/// One subprocess invocation.
#[derive(Clone, Debug)]
pub struct Cmd {
    program: String,
    args: Vec<String>,
    cwd: Option<PathBuf>,
    env: Vec<(String, String)>,
    stdin: Option<Vec<u8>>,
    timeout: Duration,
    limit: usize,
}

#[derive(Clone, Debug)]
pub struct Output {
    pub stdout: Vec<u8>,
    pub stderr: String,
    pub code: Option<i32>,
}

impl Output {
    pub fn success(&self) -> bool {
        self.code == Some(0)
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    /// Stdout split on NUL (for `-z` output), empty fields dropped.
    pub fn fields(&self) -> impl Iterator<Item = String> + '_ {
        self.stdout.split(|b| *b == 0).filter(|f| !f.is_empty()).map(|f| String::from_utf8_lossy(f).into_owned())
    }
}

impl Cmd {
    pub fn new(program: impl Into<String>) -> Self {
        Cmd {
            program: program.into(),
            args: Vec::new(),
            cwd: None,
            env: Vec::new(),
            stdin: None,
            timeout: DEFAULT_TIMEOUT,
            limit: DEFAULT_LIMIT,
        }
    }

    /// `git` with the environment every invocation gets: no prompts, no
    /// optional locks (read-only commands never take `index.lock`), stable
    /// output.
    pub fn git() -> Self {
        Cmd::new("git")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GCM_INTERACTIVE", "never")
            .env("LC_ALL", "C")
    }

    pub fn arg(mut self, a: impl Into<String>) -> Self {
        self.args.push(a.into());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn cwd(mut self, dir: impl AsRef<Path>) -> Self {
        self.cwd = Some(dir.as_ref().to_path_buf());
        self
    }

    pub fn env(mut self, k: impl Into<String>, v: impl Into<String>) -> Self {
        self.env.push((k.into(), v.into()));
        self
    }

    pub fn stdin(mut self, bytes: impl Into<Vec<u8>>) -> Self {
        self.stdin = Some(bytes.into());
        self
    }

    pub fn timeout(mut self, t: Duration) -> Self {
        self.timeout = t;
        self
    }

    pub fn limit(mut self, bytes: usize) -> Self {
        self.limit = bytes;
        self
    }

    fn describe(&self) -> String {
        let mut s = self.program.clone();
        for a in self.args.iter().take(4) {
            s.push(' ');
            s.push_str(a);
        }
        s
    }

    /// Runs to completion. A nonzero exit is not an error here; see
    /// [`Cmd::ok`].
    pub fn output(self) -> Result<Output, Error> {
        let mut c = Command::new(&self.program);
        c.args(&self.args)
            .stdin(if self.stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(d) = &self.cwd {
            c.current_dir(d);
        }
        for (k, v) in &self.env {
            c.env(k, v);
        }
        let mut child = c.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => Error::Missing(self.program.clone()),
            _ => Error::Io(e),
        })?;
        if let Some(input) = self.stdin.clone()
            && let Some(mut w) = child.stdin.take()
        {
            thread::spawn(move || {
                let _ = w.write_all(&input);
            });
        }
        let limit = self.limit;
        let out = child.stdout.take().map(|r| thread::spawn(move || read_capped(r, limit)));
        let err = child.stderr.take().map(|r| thread::spawn(move || read_capped(r, 64 << 10)));
        let code = wait(&mut child, self.timeout).ok_or_else(|| Error::Timeout(self.describe()))?;
        let stdout = out.and_then(|h| h.join().ok()).unwrap_or_default();
        let stderr = err.and_then(|h| h.join().ok()).unwrap_or_default();
        Ok(Output { stdout, stderr: String::from_utf8_lossy(&stderr).trim().to_string(), code })
    }

    /// Runs and requires success.
    pub fn ok(self) -> Result<Output, Error> {
        let what = self.describe();
        let out = self.output()?;
        if out.success() { Ok(out) } else { Err(Error::Failed { command: what, code: out.code, stderr: out.stderr }) }
    }
}

/// Reads up to `limit` bytes and discards the rest (so the child never
/// blocks on a full pipe).
fn read_capped(mut r: impl Read, limit: usize) -> Vec<u8> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 16 << 10];
    loop {
        match r.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let room = limit.saturating_sub(buf.len());
                buf.extend_from_slice(&chunk[..n.min(room)]);
            }
        }
    }
    buf
}

/// Waits with a deadline; kills the child when it passes. Polls with
/// backoff only while a command runs.
fn wait(child: &mut Child, timeout: Duration) -> Option<Option<i32>> {
    let deadline = Instant::now() + timeout;
    let mut nap = Duration::from_millis(1);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status.code()),
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => {
                thread::sleep(nap);
                nap = (nap * 2).min(Duration::from_millis(50));
            }
            Err(_) => return Some(None),
        }
    }
}
