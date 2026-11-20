//! A worktree's history as a timeline: every change (batch), newest first,
//! with who made it (actor, and the turn or tool call it belongs to) and
//! which files it touched, plus unified diffs for any set of changes.
//!
//! Diffs compare the files just before the changes with just after them, so
//! they show what happened at the time, whatever came later.

use std::collections::{HashMap, HashSet};

use ondb_core::{BatchId, FileState, InodeId, NodeKind, OpId, Version, View};
use serde::Serialize;

use crate::attrib::{self, ScopeKind, ScopeRecord};
use crate::workspace::ReadCtx;
use crate::{ActorKind, Error, Workspace};

/// Files listed per entry; the rest are only counted.
const ENTRY_FILES: usize = 40;
/// Entries touching more files than this skip line counts (an import).
const STAT_FILES: usize = 200;
/// Diffs larger than this are summarized, not shown.
const PATCH_BYTES: usize = 256 << 10;

#[derive(Clone, Debug, Serialize)]
pub struct ScopeRef {
    pub id: String,
    pub kind: ScopeKind,
    pub label: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FileStatus {
    Added,
    Removed,
    Modified,
    Moved,
}

#[derive(Clone, Debug, Serialize)]
pub struct FileChange {
    pub path: String,
    /// Where it was before, when it moved.
    pub from: Option<String>,
    pub status: FileStatus,
    pub binary: bool,
    pub added: usize,
    pub removed: usize,
    /// Unified diff (`diff` only; `None` for binary or oversized files).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patch: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Entry {
    /// Stable id (`<ts>.<actor>`), for [`diff`].
    pub id: String,
    pub actor: String,
    pub actor_kind: Option<ActorKind>,
    pub wall_ms: u64,
    /// The innermost attribution scope (tool call, command, turn).
    pub scope: Option<ScopeRef>,
    /// The turn the scope belongs to.
    pub turn: Option<ScopeRef>,
    /// Files git wrote (a checkout, merge, ...).
    pub git: bool,
    pub files: Vec<FileChange>,
    /// Files touched beyond `files`.
    pub more_files: usize,
    /// Its operations were pruned; only the header is left.
    pub pruned: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Page {
    pub entries: Vec<Entry>,
    pub has_more: bool,
}

pub fn batch_id_str(id: &BatchId) -> String {
    format!("{}.{}", id.ts, id.actor.0)
}

pub fn parse_batch_id(s: &str) -> Option<BatchId> {
    let (ts, actor) = s.split_once('.')?;
    Some(OpId::new(ts.parse().ok()?, ondb_core::ActorId(actor.parse().ok()?)))
}

/// Up to `limit` changes older than `before` (default: the newest), newest
/// first. Annotation-only batches (scope records, registry) are skipped.
pub fn entries(ws: &Workspace, before: Option<&str>, limit: usize) -> Result<Page, Error> {
    let scopes = attrib::scopes(ws);
    let by_id: HashMap<String, &ScopeRecord> = scopes.iter().map(|s| (s.id.to_string(), s)).collect();
    let innermost = attrib::scope_index(ws);
    let ids: Vec<BatchId> = ws.read(|h| {
        let all = h.exclusions_for(&Version::root());
        let mut ids = h.dag().topo_sorted(all);
        ids.reverse();
        ids
    });
    let start = match before.and_then(parse_batch_id) {
        Some(b) => ids.iter().position(|id| *id == b).map_or(ids.len(), |i| i + 1),
        None => 0,
    };
    let mut out = Vec::new();
    let mut has_more = false;
    for id in &ids[start..] {
        let summary = ws.summary(id)?;
        if summary.is_annotation_only() && !summary.pruned {
            continue;
        }
        if out.len() == limit {
            has_more = true;
            break;
        }
        let scope = innermost.get(id);
        let turn = scope.and_then(|s| {
            let mut cur: &ScopeRecord = s;
            while cur.kind != ScopeKind::Turn {
                cur = by_id.get(&cur.parent.as_ref()?.to_string())?;
            }
            Some(cur)
        });
        let actor = scope.and_then(|s| s.agent).unwrap_or(summary.actor);
        let info = ws.actor_info(&actor);
        let (files, more_files) = if summary.pruned {
            (Vec::new(), 0)
        } else {
            let one = HashSet::from([*id]);
            let mut files = ws.with(|ctx| compare(ctx, &one, false, summary.touched.len() <= STAT_FILES))?;
            let more = files.len().saturating_sub(ENTRY_FILES);
            files.truncate(ENTRY_FILES);
            (files, more)
        };
        out.push(Entry {
            id: batch_id_str(id),
            actor: info.as_ref().map(|i| i.name.clone()).unwrap_or_else(|| actor.short()),
            actor_kind: info.map(|i| i.kind),
            wall_ms: summary.wall_ms,
            scope: scope.map(scope_ref),
            turn: turn.map(scope_ref),
            git: summary.git_checkout,
            files,
            more_files,
            pruned: summary.pruned,
        });
    }
    Ok(Page { entries: out, has_more })
}

/// Unified diffs of what `ids` changed, file by file.
pub fn diff(ws: &Workspace, ids: &[BatchId]) -> Result<Vec<FileChange>, Error> {
    let set: HashSet<BatchId> = ids.iter().copied().collect();
    ws.with(|ctx| compare(ctx, &set, true, true))
}

fn scope_ref(s: &ScopeRecord) -> ScopeRef {
    ScopeRef { id: s.id.to_string(), kind: s.kind.clone(), label: s.label.clone() }
}

/// What a path held in one view.
enum Content {
    Absent,
    Text(String),
    Binary(ondb_core::Oid),
}

fn content(ctx: &ReadCtx<'_>, view: &dyn View, i: &InodeId) -> Content {
    let h = ctx.history();
    if !h.tree().is_present(view, i) {
        return Content::Absent;
    }
    match h.inode(i).map(|n| &n.kind) {
        Some(NodeKind::File(_)) => match h.file_state(view, i) {
            Some(FileState::Text { bytes, .. }) => match String::from_utf8(bytes) {
                Ok(t) => Content::Text(t),
                Err(e) => Content::Binary(ondb_core::Oid::of_blob(e.as_bytes())),
            },
            Some(FileState::Binary { blob, .. }) => Content::Binary(blob.oid),
            None => Content::Absent,
        },
        Some(NodeKind::Symlink { .. }) => {
            h.symlink_target(view, i).map_or(Content::Absent, |t| Content::Text(format!("symlink -> {t}\n")))
        }
        _ => Content::Absent,
    }
}

/// Files `ids` changed: just before them against just after them.
fn compare(ctx: &mut ReadCtx<'_>, ids: &HashSet<BatchId>, patches: bool, counts: bool) -> Result<Vec<FileChange>, Error> {
    let touched = ctx.touched_by(ids.iter().copied())?;
    let ctx: &ReadCtx<'_> = ctx;
    let h = ctx.history();
    let dag = h.dag();
    let parents: Vec<BatchId> =
        ids.iter().filter_map(|id| dag.header(id)).flat_map(|hd| hd.parents.heads().copied().collect::<Vec<_>>()).collect();
    let mut before_ex = h.exclusions_for(&dag.frontier_of(&parents));
    before_ex.extend(ids.iter().copied());
    let after_ex = h.exclusions_for(&dag.frontier_of(&ids.iter().copied().collect::<Vec<_>>()));
    let (before, after) = (h.excluding(&before_ex), h.excluding(&after_ex));
    let mut out = Vec::new();
    for i in touched {
        if matches!(h.inode(&i).map(|n| &n.kind), Some(NodeKind::Dir) | None) {
            continue;
        }
        let (old, new) = (content(ctx, &before, &i), content(ctx, &after, &i));
        let (from, to) = (h.tree().path_of(&before, &i), h.tree().path_of(&after, &i));
        let status = match (&old, &new) {
            (Content::Absent, Content::Absent) => continue,
            (Content::Absent, _) => FileStatus::Added,
            (_, Content::Absent) => FileStatus::Removed,
            _ if from != to => FileStatus::Moved,
            _ => FileStatus::Modified,
        };
        let same = match (&old, &new) {
            (Content::Text(a), Content::Text(b)) => a == b,
            (Content::Binary(a), Content::Binary(b)) => a == b,
            _ => false,
        };
        if same && status == FileStatus::Modified {
            continue;
        }
        let Some(path) = to.clone().or_else(|| from.clone()) else { continue };
        let binary = matches!(old, Content::Binary(_)) || matches!(new, Content::Binary(_));
        let mut change = FileChange {
            from: if status == FileStatus::Moved { from } else { None },
            path,
            status,
            binary,
            added: 0,
            removed: 0,
            patch: None,
        };
        if !binary && (counts || patches) {
            fn text(c: &Content) -> &str {
                match c {
                    Content::Text(t) => t,
                    _ => "",
                }
            }
            let (a, b) = (text(&old), text(&new));
            if a.len() + b.len() <= 4 * PATCH_BYTES {
                let patch = diffy::create_patch(a, b);
                for hunk in patch.hunks() {
                    for line in hunk.lines() {
                        match line {
                            diffy::Line::Insert(_) => change.added += 1,
                            diffy::Line::Delete(_) => change.removed += 1,
                            diffy::Line::Context(_) => {}
                        }
                    }
                }
                if patches {
                    let rendered = patch.to_string();
                    if rendered.len() <= PATCH_BYTES {
                        change.patch = Some(rendered);
                    }
                }
            }
        }
        out.push(change);
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}
