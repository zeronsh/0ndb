//! Landing a fork back into the worktree it was forked from.
//!
//! A fork replicates its source's history (see `Worktrees::fork`), so the
//! two exchange batches directly:
//!
//! * [`Worktrees::sync_fork`] brings the source's newer batches into the
//!   fork. Files both sides changed since they last met are merged three
//!   ways (base: neither side's new work; ours: the fork's; theirs: the
//!   source's). Overlapping text gets git-style conflict markers, written in
//!   the fork only, so the source never sees a half-merged file. Binary
//!   files and edit/delete clashes keep the fork's side on disk and wait for
//!   a decision.
//! * [`Worktrees::resolve_conflict`] settles one conflict; text conflicts
//!   also count as settled once their markers are gone from the file.
//! * [`Worktrees::land_fork`] syncs, refuses while anything is unresolved,
//!   then gives the source the fork's batches. Both histories then hold the
//!   same batches, so both worktrees converge on the same files, and every
//!   line keeps its real author.

use std::collections::HashSet;

use ondb_core::{BatchId, FileMode, FileState, InodeId, NodeKind};
use serde::{Deserialize, Serialize};

use crate::mount::disk;
use crate::{ActorKind, Error, MountHandle, Workspace, Worktrees};

const CONFLICTS_KEY: &str = "land:conflicts";
const MARKER: &str = "<<<<<<< ";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConflictKind {
    /// Both edited the same lines; the file holds conflict markers.
    Text,
    /// Both changed a binary file; the fork's version is on disk.
    Binary,
    /// The fork deleted the file, the source edited it; the source's
    /// version is back on disk.
    DeletedHere,
    /// The source deleted the file, the fork edited it; the fork's version
    /// is on disk.
    DeletedThere,
}

/// One unresolved clash, with both sides' content for choosing between them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Conflict {
    pub path: String,
    pub kind: ConflictKind,
    /// The fork's version (`None`: it deleted the file).
    pub ours: Option<Vec<u8>>,
    /// The source's version (`None`: it deleted the file).
    pub theirs: Option<Vec<u8>>,
    pub exec: bool,
}

/// How to settle a conflict.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "take", content = "content")]
pub enum Resolution {
    Ours,
    Theirs,
    /// Exactly these bytes (`None` deletes the file).
    Content(Option<Vec<u8>>),
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct SyncReport {
    /// Batches brought in from the source.
    pub brought: usize,
    /// Files merged cleanly although both sides changed them.
    pub merged: Vec<String>,
    /// Unresolved conflicts, new and earlier.
    pub conflicts: Vec<Conflict>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct LandReport {
    pub sync: SyncReport,
    /// The fork's batches the source took in.
    pub landed: usize,
}

/// A mounted worktree.
type Live = (Workspace, MountHandle);

/// A file both sides changed: where it is, and base, ours, theirs.
struct Clash {
    path: String,
    base: Side,
    ours: Side,
    theirs: Side,
}

/// What a path holds in one view.
#[derive(Clone, PartialEq, Eq)]
enum Side {
    Absent,
    Text(Vec<u8>, ondb_core::LineEnding, bool),
    Bytes(Vec<u8>, bool),
}

impl Side {
    fn disk(&self) -> Option<Vec<u8>> {
        match self {
            Side::Absent => None,
            Side::Text(b, ending, _) => Some(disk::smudge(b, *ending)),
            Side::Bytes(b, _) => Some(b.clone()),
        }
    }

    fn exec(&self) -> bool {
        matches!(self, Side::Text(_, _, true) | Side::Bytes(_, true))
    }
}

impl Worktrees {
    fn fork_pair(&self, fork: &str) -> Result<(Live, Live), Error> {
        let info = self.get(fork).ok_or_else(|| Error::Invalid(format!("no managed worktree {fork}")))?;
        let origin = info.forked_from.ok_or_else(|| Error::Invalid(format!("{} isn't a fork", info.title)))?;
        if !origin.shared {
            return Err(Error::Invalid(format!(
                "{} has a history of its own (its source's was pruned), so it can't be landed; merge its branch with git",
                info.title
            )));
        }
        let mounted = |id: &str| self.workspace(id).ok_or_else(|| Error::Invalid(format!("worktree {id} isn't mounted")));
        let (ours, theirs) = (mounted(&info.id)?, mounted(&origin.worktree)?);
        ours.1.fence()?;
        theirs.1.fence()?;
        Ok((ours, theirs))
    }

    /// Unresolved conflicts in `fork`. Text conflicts whose markers are gone
    /// are dropped as resolved.
    pub fn conflicts(&self, fork: &str) -> Result<Vec<Conflict>, Error> {
        let (ws, mount) = self.workspace(fork).ok_or_else(|| Error::Invalid(format!("worktree {fork} isn't mounted")))?;
        mount.fence()?;
        let stored = load_conflicts(&ws)?;
        let open: Vec<Conflict> = stored
            .iter()
            .filter(|c| {
                c.kind != ConflictKind::Text
                    || ws.read(|h| h.lookup(&c.path).and_then(|i| h.text(&i))).is_some_and(|t| has_markers(&t))
            })
            .cloned()
            .collect();
        if open.len() != stored.len() {
            save_conflicts(&ws, &open)?;
        }
        Ok(open)
    }

    /// Brings the source's newer work into `fork`, merging files both
    /// changed (see the module docs).
    pub fn sync_fork(&self, fork: &str) -> Result<SyncReport, Error> {
        let ((ws, mount), (src, _)) = self.fork_pair(fork)?;
        let incoming = src.batches_missing_from(&ws.heads())?;
        let report = ws.integrate(incoming)?;
        if !report.rejected.is_empty() || !report.waiting.is_empty() {
            return Err(Error::Invalid(format!(
                "the source's changes didn't apply ({} rejected, {} waiting)",
                report.rejected.len(),
                report.waiting.len()
            )));
        }
        let theirs_new: HashSet<BatchId> = report.applied.iter().copied().collect();
        let mut out = SyncReport { brought: theirs_new.len(), ..SyncReport::default() };
        let mut conflicts = self.conflicts(fork)?;
        if !theirs_new.is_empty() {
            mount.fence()?;
            let ours_new: HashSet<BatchId> = ws.read(|h| h.exclusions_for(&src.heads()));
            let plans = ws.with(|ctx| -> Result<Vec<Clash>, Error> {
                let both: Vec<InodeId> = {
                    let a = ctx.touched_by(ours_new.iter().copied())?;
                    let b = ctx.touched_by(theirs_new.iter().copied())?;
                    a.intersection(&b).copied().collect()
                };
                let ctx: &crate::workspace::ReadCtx<'_> = ctx;
                let h = ctx.history();
                let base_ex: HashSet<BatchId> = ours_new.union(&theirs_new).copied().collect();
                let (base, ours, theirs) = (h.excluding(&base_ex), h.excluding(&theirs_new), h.excluding(&ours_new));
                let side = |ctx: &crate::workspace::ReadCtx<'_>,
                            view: &dyn ondb_core::View,
                            i: &InodeId|
                 -> Result<Side, Error> {
                    let h = ctx.history();
                    if !h.tree().is_present(view, i) || !matches!(h.inode(i).map(|n| &n.kind), Some(NodeKind::File(_))) {
                        return Ok(Side::Absent);
                    }
                    Ok(match h.file_state(view, i) {
                        Some(FileState::Text { bytes, ending, mode }) => Side::Text(bytes, ending, mode == FileMode::Executable),
                        Some(FileState::Binary { blob, mode }) => {
                            Side::Bytes(ctx.blob(&blob.oid)?.unwrap_or_default(), mode == FileMode::Executable)
                        }
                        None => Side::Absent,
                    })
                };
                let mut plans = Vec::new();
                for i in both {
                    let path = h.tree().path_of(&h.current(), &i).or_else(|| h.tree().path_of(&ours, &i));
                    let Some(path) = path else { continue };
                    plans.push(Clash {
                        path,
                        base: side(ctx, &base, &i)?,
                        ours: side(ctx, &ours, &i)?,
                        theirs: side(ctx, &theirs, &i)?,
                    });
                }
                Ok(plans)
            })?;
            let merger = ws.actor("land", ActorKind::System)?;
            for Clash { path, base, ours, theirs } in plans {
                if ours == theirs {
                    continue;
                }
                let exec = ours.exec() || theirs.exec();
                let conflict = |kind| Conflict { path: path.clone(), kind, ours: ours.disk(), theirs: theirs.disk(), exec };
                match (&base, &ours, &theirs) {
                    (_, Side::Text(o, ending, _), Side::Text(t, _, _)) => {
                        let empty = Vec::new();
                        let b = match &base {
                            Side::Text(b, _, _) => b,
                            _ => &empty,
                        };
                        match merge_text(b, o, t) {
                            Some(Ok(merged)) => {
                                mount.write_file_with_mode(merger, &path, disk::smudge(merged.as_bytes(), *ending), exec)?;
                                out.merged.push(path.clone());
                            }
                            Some(Err(marked)) => {
                                mount.write_file_with_mode(merger, &path, disk::smudge(marked.as_bytes(), *ending), exec)?;
                                conflicts.retain(|c| c.path != path);
                                conflicts.push(conflict(ConflictKind::Text));
                            }
                            None => {
                                write_side(&mount, merger, &path, &ours)?;
                                conflicts.retain(|c| c.path != path);
                                conflicts.push(conflict(ConflictKind::Binary));
                            }
                        }
                    }
                    (_, Side::Absent, _) if base != theirs => {
                        // We deleted it, they changed it: keep their edit until decided.
                        write_side(&mount, merger, &path, &theirs)?;
                        conflicts.retain(|c| c.path != path);
                        conflicts.push(conflict(ConflictKind::DeletedHere));
                    }
                    (_, _, Side::Absent) if base != ours => {
                        write_side(&mount, merger, &path, &ours)?;
                        conflicts.retain(|c| c.path != path);
                        conflicts.push(conflict(ConflictKind::DeletedThere));
                    }
                    (_, Side::Absent, _) | (_, _, Side::Absent) => {
                        // One side deleted a file the other didn't change: deleted.
                        mount.remove(merger, &path)?;
                    }
                    _ => {
                        // Binary changed on both sides: keep ours until decided.
                        write_side(&mount, merger, &path, &ours)?;
                        conflicts.retain(|c| c.path != path);
                        conflicts.push(conflict(ConflictKind::Binary));
                    }
                }
            }
            mount.fence()?;
        }
        save_conflicts(&ws, &conflicts)?;
        out.conflicts = conflicts;
        Ok(out)
    }

    /// Settles the conflict at `path` in `fork`.
    pub fn resolve_conflict(&self, fork: &str, path: &str, resolution: Resolution) -> Result<(), Error> {
        let (ws, mount) = self.workspace(fork).ok_or_else(|| Error::Invalid(format!("worktree {fork} isn't mounted")))?;
        let mut conflicts = load_conflicts(&ws)?;
        let i = conflicts.iter().position(|c| c.path == path).ok_or_else(|| Error::Invalid(format!("no conflict at {path}")))?;
        let c = conflicts.remove(i);
        let content = match resolution {
            Resolution::Ours => c.ours,
            Resolution::Theirs => c.theirs,
            Resolution::Content(bytes) => bytes,
        };
        let actor = ws.actor("land", ActorKind::System)?;
        match content {
            Some(bytes) => drop(mount.write_file_with_mode(actor, path, bytes, c.exec)?),
            None => drop(mount.remove(actor, path)?),
        }
        mount.fence()?;
        save_conflicts(&ws, &conflicts)
    }

    /// Syncs `fork`, then, if nothing is left unresolved, gives its source
    /// every batch the fork has that the source lacks.
    pub fn land_fork(&self, fork: &str) -> Result<LandReport, Error> {
        let sync = self.sync_fork(fork)?;
        if !sync.conflicts.is_empty() {
            let paths: Vec<&str> = sync.conflicts.iter().map(|c| c.path.as_str()).collect();
            return Err(Error::Invalid(format!("resolve the conflicts first: {}", paths.join(", "))));
        }
        let ((ws, _), (src, src_mount)) = self.fork_pair(fork)?;
        let outgoing = ws.batches_missing_from(&src.heads())?;
        let report = src.integrate(outgoing)?;
        if !report.rejected.is_empty() || !report.waiting.is_empty() {
            return Err(Error::Invalid(format!(
                "the fork's changes didn't apply ({} rejected, {} waiting)",
                report.rejected.len(),
                report.waiting.len()
            )));
        }
        src_mount.fence()?;
        Ok(LandReport { sync, landed: report.applied.len() })
    }
}

fn write_side(mount: &MountHandle, actor: ondb_core::ActorId, path: &str, side: &Side) -> Result<(), Error> {
    match side.disk() {
        Some(bytes) => drop(mount.write_file_with_mode(actor, path, bytes, side.exec())?),
        None => drop(mount.remove(actor, path)?),
    }
    Ok(())
}

/// A three-way line merge: `Ok` merged cleanly, `Err` with conflict markers,
/// `None` when a side isn't UTF-8 text.
fn merge_text(base: &[u8], ours: &[u8], theirs: &[u8]) -> Option<Result<String, String>> {
    let (b, o, t) = (std::str::from_utf8(base).ok()?, std::str::from_utf8(ours).ok()?, std::str::from_utf8(theirs).ok()?);
    let mut opts = diffy::MergeOptions::new();
    opts.set_conflict_style(diffy::ConflictStyle::Diff3);
    Some(opts.merge(b, o, t))
}

fn has_markers(text: &[u8]) -> bool {
    text.split(|b| *b == b'\n').any(|l| l.starts_with(MARKER.as_bytes()))
}

fn load_conflicts(ws: &Workspace) -> Result<Vec<Conflict>, Error> {
    Ok(match ws.local_get(CONFLICTS_KEY)? {
        Some(bytes) => postcard::from_bytes(&bytes).unwrap_or_default(),
        None => Vec::new(),
    })
}

fn save_conflicts(ws: &Workspace, conflicts: &[Conflict]) -> Result<(), Error> {
    let bytes = postcard::to_allocvec(conflicts).map_err(|e| Error::Invalid(e.to_string()))?;
    ws.local_set(CONFLICTS_KEY, &bytes)
}
