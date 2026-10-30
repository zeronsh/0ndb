mod agents;

use std::collections::HashSet;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand, ValueEnum};
use ondb::report::{Reporter, foreign_changes};
use ondb::{ActorKind, Event, Mount, MountOptions, Recorder, ScopeId, ScopeKind, Workspace, attrib};
use ondb_core::{ActorId, Batch, BatchId, History, InodeId, Op};
use ondb_sync::transport::{TcpTransport, run_client, serve_tcp};
use ondb_sync::{Client, Relay, RelayConfig};

#[derive(Parser)]
#[command(name = "0ndb", version, about = "Tracked, attributed, syncable worktrees")]
struct Cli {
    /// Worktree root (default: nearest ancestor with a .0ndb directory, else the current directory).
    #[arg(long, short = 'C', global = true)]
    dir: Option<PathBuf>,
    /// Database to use (default: <root>/.0ndb/0ndb.db). Separate databases
    /// can track the same directory side by side, e.g. a test build next to
    /// production.
    #[arg(long, global = true, env = "ONDB_DB")]
    db: Option<PathBuf>,
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Clone, Copy, ValueEnum)]
enum Kind {
    Command,
    Turn,
    Tool,
}

#[derive(Subcommand)]
enum Cmd {
    /// Managed git worktrees (create, adopt, remove, change requests).
    #[command(subcommand)]
    Worktree(agents::WorktreeCmd),
    /// Agent threads: send, edit (branch), switch branches, inspect events.
    #[command(subcommand)]
    Thread(agents::ThreadCmd),
    /// Start tracking a directory (adopts everything not gitignored).
    Init,
    /// Watch the directory and ingest changes live; optionally sync with a relay.
    Watch {
        /// Relay address (host:port) to sync with.
        #[arg(long)]
        sync: Option<String>,
    },
    /// Run a command as an agent; every disk change it causes is attributed to it.
    Run {
        #[arg(long, default_value = "agent")]
        agent: String,
        #[arg(long, value_enum, default_value = "command")]
        kind: Kind,
        #[arg(long)]
        label: Option<String>,
        #[arg(trailing_var_arg = true, required = true)]
        command: Vec<String>,
    },
    /// Show recent batches with authors, scopes and touched paths.
    Log {
        #[arg(short = 'n', default_value_t = 20)]
        count: usize,
    },
    /// Per-line provenance of a file.
    Blame { path: String },
    /// Changes an agent hasn't seen and didn't make itself.
    Changes {
        #[arg(long, default_value = "agent")]
        agent: String,
        /// Don't advance the agent's cursor.
        #[arg(long)]
        peek: bool,
    },
    /// List attribution scopes.
    Scopes,
    /// Undo everything a scope changed, keeping later changes by others.
    Revert {
        scope: String,
        #[arg(long, default_value = "agent")]
        agent: String,
        /// Revert even if the scope never settled.
        #[arg(long)]
        force: bool,
    },
    /// Run a relay server.
    Relay {
        #[arg(long, default_value = "127.0.0.1:7420")]
        listen: String,
        /// Validate every batch by applying it before admission.
        #[arg(long)]
        validate: bool,
        /// Auto-advance the concurrency cutoff, with this grace period in seconds.
        #[arg(long)]
        cutoff_after: Option<u64>,
    },
    /// Summary of the local history.
    Status,
    /// Checks that the history's current state matches the disk exactly.
    Verify,
}

fn find_root(dir: Option<PathBuf>, external_db: bool) -> Result<PathBuf> {
    if let Some(d) = dir {
        return std::fs::canonicalize(&d).with_context(|| format!("no such directory {}", d.display()));
    }
    let cwd = std::env::current_dir()?;
    let mut cur = cwd.as_path();
    // With an external database the folder holds only mount state.
    let marker = if external_db { ".0ndb" } else { ".0ndb/0ndb.db" };
    loop {
        if cur.join(marker).exists() {
            return Ok(cur.to_path_buf());
        }
        match cur.parent() {
            Some(p) => cur = p,
            None => return Ok(cwd),
        }
    }
}

fn open(root: &Path, db: Option<PathBuf>) -> Result<Workspace> {
    let db = match db {
        Some(db) => db,
        None => root.join(".0ndb/0ndb.db"),
    };
    if let Some(parent) = db.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Workspace::open(&db, None).with_context(|| format!("opening {}", db.display()))
}

/// Brings the store up to date with the disk unless a `0ndb watch` is
/// already doing that.
fn refresh(ws: &Workspace, root: &Path) -> Result<()> {
    match Mount::start(ws, root, MountOptions::default()) {
        Ok(m) => m.stop(),
        Err(ondb::Error::Invalid(msg)) if msg.contains("already mounted") => {}
        Err(e) => return Err(e.into()),
    }
    Ok(())
}

fn exclusive_mount(ws: &Workspace, root: &Path) -> Result<Mount> {
    Mount::start(ws, root, MountOptions::default()).map_err(|e| match e {
        ondb::Error::Invalid(msg) if msg.contains("already mounted") => {
            anyhow::anyhow!("{msg}; stop `0ndb watch` first")
        }
        e => e.into(),
    })
}

fn actor_name(ws: &Workspace, actor: &ActorId) -> String {
    match ws.actor_info(actor) {
        Some(i) if i.kind == ActorKind::Ingestion => "disk".to_string(),
        Some(i) => i.name,
        None => actor.short(),
    }
}

fn actor_label(ws: &Workspace, actor: &ActorId) -> String {
    match ws.actor_info(actor) {
        Some(i) => format!("{} ({:?})", actor_name(ws, actor), i.kind).to_lowercase(),
        None => actor.short(),
    }
}

fn ago(ms: u64) -> String {
    let secs = ondb_core::now_ms().saturating_sub(ms) / 1000;
    match secs {
        0..60 => format!("{secs}s ago"),
        60..3600 => format!("{}m ago", secs / 60),
        3600..86400 => format!("{}h ago", secs / 3600),
        _ => format!("{}d ago", secs / 86400),
    }
}

/// Path of an inode even if it's gone (last known placement).
fn any_path(h: &History, inode: InodeId) -> String {
    if let Some(p) = h.path_of(&inode) {
        return p;
    }
    let mut parts = Vec::new();
    let mut cur = inode;
    while !cur.is_root() && parts.len() < 256 {
        let Some(p) = h.inode(&cur).and_then(|n| n.placement.get()) else { break };
        parts.push(p.name.clone());
        cur = p.parent;
    }
    parts.reverse();
    parts.join("/")
}

fn describe(h: &History, batch: &Batch) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for (id, op) in batch.ops_with_ids() {
        let line = match op {
            Op::CreateFile { .. } | Op::CreateDir { .. } | Op::CreateSymlink { .. } => {
                format!("A {}", any_path(h, InodeId::new(id, 0)))
            }
            Op::Import { entries } => format!("I {} entries", entries.len()),
            Op::Rename { inode, .. } => format!("R {}", any_path(h, *inode)),
            Op::Remove { inode } => format!("D {}", any_path(h, *inode)),
            Op::Restore { inode } => format!("U {}", any_path(h, *inode)),
            Op::EditText { inode, .. } | Op::SetContent { inode, .. } => format!("M {}", any_path(h, *inode)),
            Op::SetMode { inode, .. } | Op::SetLineEnding { inode, .. } | Op::SetSymlinkTarget { inode, .. } => {
                format!("m {}", any_path(h, *inode))
            }
            Op::GitCheckout { to, .. } => format!("H git checkout {to}"),
            Op::GitWrite { operation, .. } => format!("H git {operation} wrote files"),
            Op::Meta { .. } => continue,
        };
        if seen.insert(line.clone()) {
            out.push(line);
        }
    }
    out
}

fn print_batch(ws: &Workspace, id: &BatchId, scopes: &std::collections::HashMap<BatchId, ondb::ScopeRecord>) -> Result<()> {
    let Some(batch) = ws.batch(id)? else { return Ok(()) };
    let lines = ws.read(|h| describe(h, &batch));
    if lines.is_empty() {
        return Ok(());
    }
    let scope = scopes.get(id).map(|s| format!("  [{:?} {} \"{}\"]", s.kind, s.id, s.label).to_lowercase()).unwrap_or_default();
    println!("{:<20} {:<28} {:>8}{scope}", format!("{id:?}"), actor_label(ws, &batch.header.actor), ago(batch.header.wall_ms));
    for l in lines {
        println!("    {l}");
    }
    Ok(())
}

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_env("ONDB_LOG").unwrap_or_else(|_| "warn".into()))
        .with_writer(std::io::stderr)
        .init();
    match run(Cli::parse()) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("0ndb: {e:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<ExitCode> {
    match cli.command {
        Cmd::Worktree(c) => return agents::worktree(c).map(|_| ExitCode::SUCCESS),
        Cmd::Thread(c) => return agents::thread(c).map(|_| ExitCode::SUCCESS),
        _ => {}
    }
    if let Cmd::Relay { listen, validate, cutoff_after } = &cli.command {
        let listener = TcpListener::bind(listen)?;
        eprintln!("relay listening on {}", listener.local_addr()?);
        let config = RelayConfig { validate: *validate, cutoff_after: cutoff_after.map(Duration::from_secs) };
        serve_tcp(listener, Arc::new(Mutex::new(Relay::in_memory(config))), Arc::new(AtomicBool::new(false)))?;
        return Ok(ExitCode::SUCCESS);
    }
    let root = find_root(cli.dir, cli.db.is_some())?;
    let ws = open(&root, cli.db)?;
    match cli.command {
        Cmd::Relay { .. } | Cmd::Worktree(_) | Cmd::Thread(_) => unreachable!(),
        Cmd::Init => {
            exclusive_mount(&ws, &root)?.stop();
            let files = ws.read(|h| h.walk().len());
            println!("tracking {} ({files} entries, history {})", root.display(), ws.id());
        }
        Cmd::Watch { sync } => {
            let mount = exclusive_mount(&ws, &root)?;
            let events = ws.subscribe();
            if let Some(addr) = sync {
                let ws = ws.clone();
                std::thread::spawn(move || {
                    loop {
                        let changes = ws.subscribe();
                        match TcpTransport::connect(&addr) {
                            Ok(mut t) => {
                                eprintln!("syncing with {addr}");
                                let mut client = Client::new(ws.clone());
                                if let Err(e) = run_client(&mut client, &mut t, &changes, &AtomicBool::new(false)) {
                                    eprintln!("sync: {e}; reconnecting");
                                }
                            }
                            Err(e) => eprintln!("sync: {e}; retrying"),
                        }
                        std::thread::sleep(Duration::from_secs(1));
                    }
                });
            }
            eprintln!("watching {} (ingestion actor {})", root.display(), mount.ingestion_actor().short());
            let scopes = attrib::scope_index(&ws);
            for ev in events {
                if let Event::Committed(c) = ev {
                    print_batch(&ws, &c.batch, &scopes)?;
                }
            }
        }
        Cmd::Run { agent, kind, label, command } => {
            let mount = exclusive_mount(&ws, &root)?;
            let agent_id = ws.actor(&agent, ActorKind::Agent)?;
            let recorder = Recorder::new(&ws, vec![mount.handle()])?;
            let kind = match kind {
                Kind::Command => ScopeKind::Command,
                Kind::Turn => ScopeKind::Turn,
                Kind::Tool => ScopeKind::ToolCall,
            };
            let label = label.unwrap_or_else(|| command.join(" "));
            let (status, record) = recorder.scoped(kind, &label, Some(agent_id), None, |_| {
                std::process::Command::new(&command[0]).args(&command[1..]).current_dir(&root).status()
            })?;
            let status = status.with_context(|| format!("running {}", command[0]))?;
            let scopes = attrib::scope_index(&ws);
            eprintln!(
                "scope {} by {agent}: {} batch(es){}",
                record.id,
                record.batches.len(),
                if record.settled { "" } else { " (unsettled)" }
            );
            for b in &record.batches {
                print_batch(&ws, b, &scopes)?;
            }
            mount.stop();
            return Ok(ExitCode::from(status.code().unwrap_or(1).clamp(0, 255) as u8));
        }
        Cmd::Log { count } => {
            refresh(&ws, &root)?;
            let scopes = attrib::scope_index(&ws);
            let mut ids: Vec<(u64, BatchId)> = ws.read(|h| h.dag().headers().map(|hd| (hd.start, hd.id())).collect());
            ids.sort_by(|a, b| b.cmp(a));
            let mut shown = 0;
            for (_, id) in ids {
                if shown >= count {
                    break;
                }
                if ws.summary(&id)?.is_annotation_only() {
                    continue;
                }
                print_batch(&ws, &id, &scopes)?;
                shown += 1;
            }
        }
        Cmd::Blame { path } => {
            refresh(&ws, &root)?;
            let abs = std::env::current_dir()?.join(&path);
            let rel = std::fs::canonicalize(&abs)
                .ok()
                .and_then(|p| p.strip_prefix(&root).ok().map(|r| r.to_string_lossy().into_owned()))
                .unwrap_or(path);
            for l in ondb::blame::blame(&ws, &rel)? {
                let who = actor_name(&ws, &l.actor);
                let scope = l.scope.as_ref().map(|s| s.label.clone()).unwrap_or_default();
                let scope: String = scope.chars().take(18).collect();
                println!("{:>4} {:<14} {:<18} {:>8} │ {}", l.line, who, scope, ago(l.wall_ms), l.text);
            }
        }
        Cmd::Changes { agent, peek } => {
            refresh(&ws, &root)?;
            let agent_id = ws.actor(&agent, ActorKind::Agent)?;
            let reporter = Reporter::new(&ws, agent_id);
            let report = if peek { foreign_changes(&ws, &reporter.cursor()?, agent_id)? } else { reporter.take()? };
            if report.is_empty() {
                println!("no changes since {agent} last looked");
            } else {
                let name = root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                print!("{}", report.render(&name));
            }
        }
        Cmd::Scopes => {
            for s in attrib::scopes(&ws) {
                let agent = s.agent.map(|a| actor_label(&ws, &a)).unwrap_or_default();
                let state = match (s.ended_ms, s.settled) {
                    (None, _) => "open",
                    (Some(_), true) => "settled",
                    (Some(_), false) => "unsettled",
                };
                println!(
                    "{}  {:<10} {:<9} {:>3} batch(es)  {:<22} {}  \"{}\"",
                    s.id,
                    format!("{:?}", s.kind).to_lowercase(),
                    state,
                    s.batches.len(),
                    agent,
                    ago(s.started_ms),
                    s.label
                );
            }
        }
        Cmd::Revert { scope, agent, force } => {
            let all = attrib::scopes(&ws);
            let matches: Vec<&ondb::ScopeRecord> =
                all.iter().filter(|s| s.id.0.simple().to_string().starts_with(&scope)).collect();
            let target: ScopeId = match matches.as_slice() {
                [one] => one.id,
                [] => bail!("no scope matches {scope}"),
                _ => bail!("{scope} is ambiguous"),
            };
            let mount = exclusive_mount(&ws, &root)?;
            let agent_id = ws.actor(&agent, ActorKind::Agent)?;
            let recorder = Recorder::new(&ws, vec![mount.handle()])?;
            let (batch, record) = recorder.revert(&target, agent_id, force)?;
            mount.fence()?;
            match batch {
                Some(b) => {
                    println!("reverted {target} as scope {}", record.id);
                    print_batch(&ws, &b, &attrib::scope_index(&ws))?;
                }
                None => println!("nothing to revert"),
            }
            mount.stop();
        }
        Cmd::Verify => {
            refresh(&ws, &root)?;
            let problems = verify(&ws, &root)?;
            for p in &problems {
                println!("{p}");
            }
            let entries = ws.read(|h| h.walk().len());
            if !problems.is_empty() {
                println!("{} mismatches across {entries} entries", problems.len());
                return Ok(ExitCode::from(1));
            }
            println!("ok: {entries} entries match disk");
        }
        Cmd::Status => {
            refresh(&ws, &root)?;
            let (heads, batches, entries) = ws.read(|h| (h.heads().clone(), h.dag().len(), h.walk().len()));
            println!("root      {}", root.display());
            println!("history   {}", ws.id());
            println!("replica   {}", ws.replica());
            println!("heads     {heads}");
            println!("batches   {batches} ({} unpushed)", ws.unpushed()?.len());
            println!("entries   {entries}");
            println!("actors");
            for (id, info) in ws.actors() {
                println!("  {}  {:<10} {}", id.short(), format!("{:?}", info.kind).to_lowercase(), info.name);
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

/// Every difference between the current history state and the disk: content,
/// mode, symlink targets, and (in git checkouts) unignored files the history
/// doesn't know about.
fn verify(ws: &Workspace, root: &Path) -> Result<Vec<String>> {
    use ondb_core::{FileMode, FileState};
    use std::os::unix::fs::PermissionsExt;
    let entries = ws.read(|h| {
        let view = h.current();
        h.walk()
            .into_iter()
            .map(|(path, id)| {
                let file = h.file_state(&view, &id);
                let link = h.symlink_target(&view, &id);
                (path, file, link)
            })
            .collect::<Vec<_>>()
    });
    let mut problems = Vec::new();
    let mut known = HashSet::new();
    for (path, file, link) in entries {
        let abs = root.join(&path);
        let meta = std::fs::symlink_metadata(&abs);
        known.insert(path.clone());
        match (file, link, meta) {
            (_, _, Err(_)) => problems.push(format!("missing   {path}")),
            (Some(state), _, Ok(meta)) => {
                let (expected, mode) = match state {
                    FileState::Text { bytes, ending, mode } => (ondb::mount::smudge(&bytes, ending), mode),
                    FileState::Binary { blob, mode } => match ws.blob(&blob.oid)? {
                        Some(b) => (b, mode),
                        None => {
                            problems.push(format!("no blob   {path}"));
                            continue;
                        }
                    },
                };
                if !meta.is_file() {
                    problems.push(format!("not file  {path}"));
                } else if std::fs::read(&abs)? != expected {
                    problems.push(format!("content   {path}"));
                } else if (meta.permissions().mode() & 0o111 != 0) != (mode == FileMode::Executable) {
                    problems.push(format!("mode      {path}"));
                }
            }
            (None, Some(target), Ok(_)) => {
                if std::fs::read_link(&abs).ok().map(|t| t.to_string_lossy().into_owned()) != Some(target) {
                    problems.push(format!("symlink   {path}"));
                }
            }
            (None, None, Ok(meta)) if !meta.is_dir() => problems.push(format!("not dir   {path}")),
            _ => {}
        }
    }
    let listed = std::process::Command::new("git")
        .args(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        .current_dir(root)
        .output()?;
    if listed.status.success() {
        for p in listed.stdout.split(|b| *b == 0).filter(|p| !p.is_empty()) {
            let p = String::from_utf8_lossy(p).into_owned();
            if !known.contains(&p) && !p.starts_with(".0ndb/") && root.join(&p).exists() {
                problems.push(format!("untracked {p}"));
            }
        }
    }
    problems.sort();
    Ok(problems)
}
