use std::collections::HashSet;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand, ValueEnum};
use strand::report::{Reporter, foreign_changes};
use strand::{ActorKind, Event, Mount, MountOptions, Recorder, ScopeId, ScopeKind, Workspace, attrib};
use strand_core::{ActorId, Batch, BatchId, History, InodeId, Op};
use strand_sync::transport::{TcpTransport, run_client, serve_tcp};
use strand_sync::{Client, Relay, RelayConfig};

#[derive(Parser)]
#[command(name = "strand", version, about = "Tracked, attributed, syncable worktrees")]
struct Cli {
    /// Worktree root (default: nearest ancestor with a .strand directory, else the current directory).
    #[arg(long, short = 'C', global = true)]
    dir: Option<PathBuf>,
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
}

fn find_root(dir: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(d) = dir {
        return std::fs::canonicalize(&d).with_context(|| format!("no such directory {}", d.display()));
    }
    let cwd = std::env::current_dir()?;
    let mut cur = cwd.as_path();
    loop {
        if cur.join(".strand/strand.db").exists() {
            return Ok(cur.to_path_buf());
        }
        match cur.parent() {
            Some(p) => cur = p,
            None => return Ok(cwd),
        }
    }
}

fn open(root: &Path) -> Result<Workspace> {
    std::fs::create_dir_all(root.join(".strand"))?;
    Ok(Workspace::open(root.join(".strand/strand.db"), None)?)
}

/// Brings the store up to date with the disk unless a `strand watch` is
/// already doing that.
fn refresh(ws: &Workspace, root: &Path) -> Result<()> {
    match Mount::start(ws, root, MountOptions::default()) {
        Ok(m) => m.stop(),
        Err(strand::Error::Invalid(msg)) if msg.contains("already mounted") => {}
        Err(e) => return Err(e.into()),
    }
    Ok(())
}

fn exclusive_mount(ws: &Workspace, root: &Path) -> Result<Mount> {
    Mount::start(ws, root, MountOptions::default()).map_err(|e| match e {
        strand::Error::Invalid(msg) if msg.contains("already mounted") => {
            anyhow::anyhow!("{msg}; stop `strand watch` first")
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
    let secs = strand_core::now_ms().saturating_sub(ms) / 1000;
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
            Op::Meta { key, .. } if key == "git/head" => "H git HEAD moved".to_string(),
            Op::Meta { .. } => continue,
        };
        if seen.insert(line.clone()) {
            out.push(line);
        }
    }
    out
}

fn print_batch(ws: &Workspace, id: &BatchId, scopes: &std::collections::HashMap<BatchId, strand::ScopeRecord>) -> Result<()> {
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
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_env("STRAND_LOG").unwrap_or_else(|_| "warn".into()))
        .with_writer(std::io::stderr)
        .init();
    match run(Cli::parse()) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("strand: {e:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<ExitCode> {
    if let Cmd::Relay { listen, validate, cutoff_after } = &cli.command {
        let listener = TcpListener::bind(listen)?;
        eprintln!("relay listening on {}", listener.local_addr()?);
        let config = RelayConfig { validate: *validate, cutoff_after: cutoff_after.map(Duration::from_secs) };
        serve_tcp(listener, Arc::new(Mutex::new(Relay::in_memory(config))), Arc::new(AtomicBool::new(false)))?;
        return Ok(ExitCode::SUCCESS);
    }
    let root = find_root(cli.dir)?;
    let ws = open(&root)?;
    match cli.command {
        Cmd::Relay { .. } => unreachable!(),
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
            for l in strand::blame::blame(&ws, &rel)? {
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
            let matches: Vec<&strand::ScopeRecord> =
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
