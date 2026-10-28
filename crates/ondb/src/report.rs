//! Change reports: what changed in a worktree that a given agent did not do
//! itself, since it last looked. Built from a selective view (everything
//! except the foreign batches) so the agent's own interleaved edits never
//! show up as someone else's.

use std::collections::{BTreeMap, HashSet};
use std::fmt::Write;

use ondb_core::diff::unified;
use ondb_core::{ActorId, BatchId, FileState, InodeId, NodeKind, Version};

use crate::Error;
use crate::attrib::scopes;
use crate::workspace::Workspace;

const MAX_HUNK_LINES: usize = 400;
const LOCKFILES: &[&str] = &[
    "Cargo.lock",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "bun.lock",
    "bun.lockb",
    "poetry.lock",
    "uv.lock",
    "Gemfile.lock",
    "composer.lock",
    "go.sum",
    "flake.lock",
];

pub fn is_lockfile(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    LOCKFILES.contains(&name)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FileChange {
    Edited {
        path: String,
        diff: Vec<String>,
    },
    /// Diff omitted (lockfile, oversized); `hunks` sizes the change.
    EditedWithheld {
        path: String,
        hunks: usize,
        reason: &'static str,
    },
    EditedBinary {
        path: String,
    },
    Created {
        path: String,
    },
    Removed {
        path: String,
    },
    Moved {
        from: String,
        to: String,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ChangeReport {
    pub since: Version,
    pub until: Version,
    pub batches: Vec<BatchId>,
    pub changes: Vec<FileChange>,
    pub git_head: Option<String>,
}

impl ChangeReport {
    pub fn is_empty(&self) -> bool {
        self.changes.is_empty() && self.git_head.is_none()
    }

    /// Prompt-ready rendering.
    pub fn render(&self, worktree: &str) -> String {
        let mut out = String::new();
        let _ = writeln!(out, "<workspace-changes worktree=\"{worktree}\">");
        if let Some(h) = &self.git_head {
            let _ = writeln!(out, "<head-moved to=\"{h}\"/>");
        }
        let mut lists: BTreeMap<&str, Vec<String>> = BTreeMap::new();
        for c in &self.changes {
            match c {
                FileChange::Edited { path, diff } => {
                    let _ = writeln!(out, "<modified path=\"{path}\">");
                    for l in diff {
                        let _ = writeln!(out, "{l}");
                    }
                    let _ = writeln!(out, "</modified>");
                }
                FileChange::EditedWithheld { path, hunks, reason } => {
                    let _ = writeln!(out, "<modified path=\"{path}\" hunks=\"{hunks}\" withheld=\"{reason}\"/>");
                }
                FileChange::EditedBinary { path } => lists.entry("modified-binary").or_default().push(path.clone()),
                FileChange::Created { path } => lists.entry("created").or_default().push(path.clone()),
                FileChange::Removed { path } => lists.entry("removed").or_default().push(path.clone()),
                FileChange::Moved { from, to } => lists.entry("moved").or_default().push(format!("{from} -> {to}")),
            }
        }
        for (tag, items) in lists {
            let _ = writeln!(out, "<{tag}>");
            for i in items {
                let _ = writeln!(out, "{i}");
            }
            let _ = writeln!(out, "</{tag}>");
        }
        out.push_str("</workspace-changes>\n");
        out
    }
}

/// Changes in `(since, heads]` made by anyone other than `agent`, excluding
/// batches attributed to the agent's own scopes (its disk effects).
pub fn foreign_changes(ws: &Workspace, since: &Version, agent: ActorId) -> Result<ChangeReport, Error> {
    let own: HashSet<BatchId> = scopes(ws).into_iter().filter(|s| s.agent == Some(agent)).flat_map(|s| s.batches).collect();
    ws.with(|ctx| -> Result<ChangeReport, Error> {
        let heads = ctx.history().heads().clone();
        let known: Version = since.heads().filter(|b| ctx.history().dag().contains_batch_id(b)).copied().collect();
        let diff = ctx.history().dag().difference(&heads, &known);
        let mut foreign = HashSet::new();
        let mut git_head = None;
        for id in &diff {
            let s = ctx.summary(id)?;
            if s.actor == agent || own.contains(id) {
                continue;
            }
            if s.meta_keys.iter().any(|k| k == "git/head") {
                git_head = Some(());
            }
            if !s.is_annotation_only() {
                foreign.insert(*id);
            }
        }
        let touched: Vec<InodeId> = {
            let mut t: Vec<InodeId> = ctx.touched_by(foreign.iter().copied())?.into_iter().collect();
            t.sort();
            t
        };
        let h = ctx.history();
        let (now, then) = (h.current(), h.excluding(&foreign));
        let tree = h.tree();
        let mut changes = Vec::new();
        for inode in touched {
            let Some(node) = h.inode(&inode) else { continue };
            let before = tree.is_present(&then, &inode).then(|| tree.path_of(&then, &inode)).flatten();
            let after = tree.is_present(&now, &inode).then(|| tree.path_of(&now, &inode)).flatten();
            let is_file = !matches!(node.kind, NodeKind::Dir);
            match (&before, &after) {
                (None, Some(p)) if is_file => changes.push(FileChange::Created { path: p.clone() }),
                (Some(p), None) if is_file => changes.push(FileChange::Removed { path: p.clone() }),
                (Some(a), Some(b)) if a != b => changes.push(FileChange::Moved { from: a.clone(), to: b.clone() }),
                _ => {}
            }
            let (Some(_), Some(path)) = (&before, &after) else { continue };
            match (h.file_state(&then, &inode), h.file_state(&now, &inode)) {
                (Some(FileState::Text { bytes: a, .. }), Some(FileState::Text { bytes: b, .. })) if a != b => {
                    let diff = unified(&a, &b, 3);
                    let hunks = diff.iter().filter(|l| l.starts_with("@@")).count();
                    if is_lockfile(path) {
                        changes.push(FileChange::EditedWithheld { path: path.clone(), hunks, reason: "lockfile" });
                    } else if diff.len() > MAX_HUNK_LINES {
                        changes.push(FileChange::EditedWithheld { path: path.clone(), hunks, reason: "too-large" });
                    } else {
                        changes.push(FileChange::Edited { path: path.clone(), diff });
                    }
                }
                (Some(a), Some(b)) if a != b => changes.push(FileChange::EditedBinary { path: path.clone() }),
                _ => {}
            }
        }
        let git_head = git_head.and_then(|_| h.meta("git/head").map(|v| String::from_utf8_lossy(v).into_owned()));
        let mut batches: Vec<BatchId> = foreign.into_iter().collect();
        batches.sort();
        Ok(ChangeReport { since: known, until: heads, batches, changes, git_head })
    })
}

/// Tracks, per agent, the version it last saw, and produces only what's new.
pub struct Reporter {
    ws: Workspace,
    agent: ActorId,
}

impl Reporter {
    pub fn new(ws: &Workspace, agent: ActorId) -> Reporter {
        Reporter { ws: ws.clone(), agent }
    }

    fn cursor_key(&self) -> String {
        format!("report-cursor:{}", self.agent.0)
    }

    /// What the agent has seen: the last reported version, or (first time)
    /// the start of its earliest scope, or now if it has never worked here.
    pub fn cursor(&self) -> Result<Version, Error> {
        match self.ws.local_get(&self.cursor_key())? {
            Some(b) => postcard::from_bytes(&b).map_err(|e| Error::Invalid(e.to_string())),
            None => Ok(scopes(&self.ws)
                .into_iter()
                .find(|s| s.agent == Some(self.agent))
                .map(|s| s.start_version)
                .unwrap_or_else(|| self.ws.heads())),
        }
    }

    /// Marks everything up to `v` as seen by the agent.
    pub fn advance(&self, v: &Version) -> Result<(), Error> {
        let bytes = postcard::to_stdvec(v).map_err(|e| Error::Invalid(e.to_string()))?;
        self.ws.local_set(&self.cursor_key(), &bytes)
    }

    /// Foreign changes since the cursor; advances the cursor.
    pub fn take(&self) -> Result<ChangeReport, Error> {
        let since = self.cursor()?;
        let report = foreign_changes(&self.ws, &since, self.agent)?;
        self.advance(&report.until)?;
        Ok(report)
    }
}
