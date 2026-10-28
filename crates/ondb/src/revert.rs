//! Selective undo: compute what the worktree would be if a set of batches
//! had never happened (every other change, including later ones, kept) and
//! commit the difference as new operations.

use std::collections::HashSet;

use ondb_core::diff::line_splices;
use ondb_core::{ActorId, BatchId, Content, FileState, InodeId, NodeKind, Op};

use crate::Error;
use crate::workspace::Workspace;

pub fn revert_batches(ws: &Workspace, actor: ActorId, batches: &HashSet<BatchId>) -> Result<Option<BatchId>, Error> {
    if batches.is_empty() {
        return Ok(None);
    }
    let ops = ws.with(|ctx| -> Result<(Vec<Op>, Vec<ondb_core::Blob>), Error> {
        let mut touched: Vec<InodeId> = ctx.touched_by(batches.iter().copied())?.into_iter().collect();
        touched.sort();
        let h = ctx.history();
        let now = h.current();
        let then = h.excluding(batches);
        let tree = h.tree();
        let mut ops = Vec::new();
        let mut blobs = Vec::new();
        let mut restores = Vec::new();
        let mut removals = Vec::new();
        for inode in touched {
            let Some(node) = h.inode(&inode) else { continue };
            let (present_now, present_then) = (tree.is_present(&now, &inode), tree.is_present(&then, &inode));
            if present_then && !present_now {
                restores.push(Op::Restore { inode });
            }
            if present_now && !present_then {
                removals.push(Op::Remove { inode });
                continue;
            }
            if !present_then {
                continue;
            }
            if let (Some(a), Some(b)) = (tree.placement_in(&now, &inode), tree.placement_in(&then, &inode))
                && a != b
            {
                ops.push(Op::Rename { inode, parent: b.parent, name: b.name.clone() });
            }
            match &node.kind {
                NodeKind::File(_) => match (h.file_state(&now, &inode), h.file_state(&then, &inode)) {
                    (
                        Some(FileState::Text { bytes: a, ending: ea, mode: ma }),
                        Some(FileState::Text { bytes: b, ending: eb, mode: mb }),
                    ) => {
                        let (text, splices) = line_splices(&a, &b);
                        if !splices.is_empty() {
                            ops.push(Op::EditText { inode, text, splices });
                        }
                        if ea != eb {
                            ops.push(Op::SetLineEnding { inode, ending: eb });
                        }
                        if ma != mb {
                            ops.push(Op::SetMode { inode, mode: mb });
                        }
                    }
                    (now_state, Some(FileState::Text { bytes, ending, mode })) => {
                        let (content, blob) = Content::text(bytes);
                        if let Some(b) = blob {
                            blobs.push(b);
                        }
                        ops.push(Op::SetContent { inode, content });
                        ops.push(Op::SetLineEnding { inode, ending });
                        if !matches!(now_state, Some(FileState::Binary { mode: m, .. }) if m == mode) {
                            ops.push(Op::SetMode { inode, mode });
                        }
                    }
                    (now_state, Some(FileState::Binary { blob, mode })) => {
                        if !matches!(&now_state, Some(FileState::Binary { blob: b, .. }) if b.oid == blob.oid) {
                            ops.push(Op::SetContent { inode, content: Content::Binary(blob) });
                        }
                        let now_mode = match now_state {
                            Some(FileState::Text { mode, .. } | FileState::Binary { mode, .. }) => Some(mode),
                            None => None,
                        };
                        if now_mode != Some(mode) {
                            ops.push(Op::SetMode { inode, mode });
                        }
                    }
                    _ => {}
                },
                NodeKind::Symlink { .. } => {
                    if let Some(t) = h.symlink_target(&then, &inode)
                        && h.symlink_target(&now, &inode).as_ref() != Some(&t)
                    {
                        ops.push(Op::SetSymlinkTarget { inode, target: t });
                    }
                }
                NodeKind::Dir => {}
            }
        }
        // Restore before anything that might live inside a restored
        // directory; remove last so moves out of removed dirs happen first.
        restores.extend(ops);
        restores.extend(removals);
        Ok((restores, blobs))
    })?;
    let (ops, blobs) = ops;
    let (batch, _) = ws.commit(actor, None, |txn| {
        for b in blobs {
            txn.attach_blob(b);
        }
        for op in ops {
            txn.push(op)?;
        }
        Ok(())
    })?;
    Ok(batch)
}
