//! `0ndb worktree ...` and `0ndb thread ...`: managed worktrees and agent
//! threads, stored under `$ONDB_HOME` (default `~/.0ndb`).

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use clap::{Subcommand, ValueEnum};
use ondb::git::Forges;
use ondb::{MountOptions, Worktrees};
use ondb_agents::claude::{Access, ClaudeCode};
use ondb_agents::{Provider, Role, SessionOptions, Sessions};

#[derive(Subcommand)]
pub enum WorktreeCmd {
    /// Managed worktrees.
    List,
    /// A new git worktree of REPO on a fresh `ondb/<title>` branch, mounted.
    New {
        repo: PathBuf,
        title: String,
        /// Base revision (default: the remote's default branch).
        #[arg(long)]
        base: Option<String>,
    },
    /// Manage an existing folder.
    Adopt { path: PathBuf, title: String },
    /// Stop managing; removes worktrees 0ndb created.
    Rm {
        id: String,
        #[arg(long)]
        force: bool,
        #[arg(long)]
        delete_branch: bool,
    },
    /// The branch's change request, from whichever provider hosts it.
    Pr { id: String },
    /// Push the branch and open a change request.
    PrOpen {
        id: String,
        title: String,
        #[arg(long, default_value = "")]
        body: String,
        #[arg(long)]
        base: Option<String>,
        #[arg(long)]
        draft: bool,
    },
}

#[derive(Clone, Copy, ValueEnum)]
pub enum AccessArg {
    Plan,
    Edits,
    Full,
}

#[derive(Subcommand)]
pub enum ThreadCmd {
    List,
    /// A thread in a managed worktree.
    New {
        worktree: String,
        title: String,
    },
    /// Send a prompt on the thread's selected branch.
    Send {
        thread: String,
        prompt: String,
        #[arg(long, default_value = "claude-code")]
        provider: String,
        #[arg(long)]
        model: Option<String>,
        #[arg(long, value_enum, default_value = "edits")]
        access: AccessArg,
    },
    /// Replace a user message: a new branch from there.
    Edit {
        message: String,
        prompt: String,
        #[arg(long, default_value = "claude-code")]
        provider: String,
        #[arg(long)]
        model: Option<String>,
        #[arg(long, value_enum, default_value = "edits")]
        access: AccessArg,
    },
    /// Select the branch through MESSAGE (files follow).
    Switch {
        message: String,
    },
    /// The selected branch with tool calls and `<i/n>` alternatives.
    Show {
        thread: String,
    },
    /// A message's provider events, verbatim (JSON lines).
    Events {
        message: String,
    },
}

fn home() -> Result<PathBuf> {
    if let Ok(h) = std::env::var("ONDB_HOME") {
        return Ok(PathBuf::from(h));
    }
    let home = std::env::var("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".0ndb"))
}

fn worktrees() -> Result<Worktrees> {
    let h = home()?;
    Ok(Worktrees::open(h.join("state"), h.join("worktrees"), MountOptions::default(), Forges::default())?)
}

fn sessions(wts: Worktrees, access: AccessArg) -> Result<Sessions> {
    let access = match access {
        AccessArg::Plan => Access::Plan,
        AccessArg::Edits => Access::AcceptEdits,
        AccessArg::Full => Access::Full,
    };
    let providers: Vec<Arc<dyn Provider>> = vec![Arc::new(ClaudeCode::new(access))];
    Ok(Sessions::open(home()?.join("state/sessions.db"), wts, providers, SessionOptions::default())?)
}

pub fn worktree(cmd: WorktreeCmd) -> Result<()> {
    let wts = worktrees()?;
    match cmd {
        WorktreeCmd::List => {
            for w in wts.list() {
                println!("{}  {:<28} {:<32} {}", w.id, w.title, w.branch.as_deref().unwrap_or("-"), w.path.display());
            }
        }
        WorktreeCmd::New { repo, title, base } => {
            let w = wts.create(&repo, &title, base.as_deref())?;
            println!("{}  {} on {}", w.id, w.path.display(), w.branch.unwrap_or_default());
        }
        WorktreeCmd::Adopt { path, title } => {
            let w = wts.adopt(&path, &title)?;
            println!("{}  {}", w.id, w.path.display());
        }
        WorktreeCmd::Rm { id, force, delete_branch } => wts.remove(&id, force, delete_branch)?,
        WorktreeCmd::Pr { id } => match wts.change_request(&id)? {
            Some(cr) => println!(
                "#{} {:?}{} {} -> {}  checks {:?}  review {:?}\n{}\n{}",
                cr.number,
                cr.state,
                if cr.draft { " (draft)" } else { "" },
                cr.head_branch,
                cr.base_branch,
                cr.checks,
                cr.review,
                cr.title,
                cr.url
            ),
            None => println!("no change request for this branch"),
        },
        WorktreeCmd::PrOpen { id, title, body, base, draft } => {
            let cr = wts.open_change_request(&id, &title, &body, base.as_deref(), draft)?;
            println!("#{} {}", cr.number, cr.url);
        }
    }
    Ok(())
}

pub fn thread(cmd: ThreadCmd) -> Result<()> {
    let access = match &cmd {
        ThreadCmd::Send { access, .. } | ThreadCmd::Edit { access, .. } => *access,
        _ => AccessArg::Edits,
    };
    let s = sessions(worktrees()?, access)?;
    match cmd {
        ThreadCmd::List => {
            for t in s.threads()? {
                println!("{}  {:<32} worktree {}", t.id, t.title, t.worktree);
            }
        }
        ThreadCmd::New { worktree, title } => println!("{}", s.create_thread(&worktree, &title)?.id),
        ThreadCmd::Send { thread, prompt, provider, model, .. } => {
            let m = s.send(&thread, &prompt, &provider, model.as_deref())?.wait()?;
            print_reply(&s, &m)?;
        }
        ThreadCmd::Edit { message, prompt, provider, model, .. } => {
            let m = s.edit(&message, &prompt, &provider, model.as_deref())?.wait()?;
            print_reply(&s, &m)?;
        }
        ThreadCmd::Switch { message } => {
            let leaf = s.switch_branch(&message)?;
            println!("now at {}", leaf.id);
        }
        ThreadCmd::Show { thread } => {
            for m in s.path(&thread)? {
                let sibs = s.siblings(&m.id)?;
                let pos = sibs.iter().position(|x| x.id == m.id).unwrap_or(0) + 1;
                let alt = if sibs.len() > 1 { format!(" <{pos}/{}>", sibs.len()) } else { String::new() };
                match m.role {
                    Role::User => println!("\n[{}] you{alt}:\n{}", m.id, m.text),
                    Role::Assistant => {
                        println!("\n[{}] {} ({:?}){alt}:", m.id, m.provider.as_deref().unwrap_or("agent"), m.status);
                        for tc in s.tool_calls(&m.id)? {
                            println!("  - {} {}", tc.name, if tc.is_error == Some(true) { "(error)" } else { "" });
                        }
                        println!("{}", m.text);
                        if let Some(e) = &m.error {
                            println!("  error: {e}");
                        }
                    }
                }
            }
        }
        ThreadCmd::Events { message } => {
            for ev in s.events(&message)? {
                match ev.raw {
                    Some(raw) => println!("{}", String::from_utf8_lossy(&raw)),
                    None => println!("{{\"kind\":{:?}}}", ev.kind),
                }
            }
        }
    }
    s.close_idle();
    Ok(())
}

fn print_reply(s: &Sessions, m: &ondb_agents::Message) -> Result<()> {
    for tc in s.tool_calls(&m.id)? {
        eprintln!("  - {}", tc.name);
    }
    println!("{}", m.text);
    if let Some(e) = &m.error {
        bail!("{:?}: {e}", m.status);
    }
    Ok(())
}
