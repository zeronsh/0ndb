//! Per-line provenance. Every byte of a file names the operation that
//! inserted it, so each line resolves to the batch, actor and scope that
//! last wrote it — whether that was an edit tool, a disk ingestion of a
//! script's output, or a remote replica.

use strand_core::{ActorId, BatchId, OpId};

use crate::Error;
use crate::attrib::{ScopeRecord, scope_index};
use crate::workspace::{ActorInfo, Workspace};

#[derive(Clone, Debug)]
pub struct LineOrigin {
    pub line: usize,
    pub text: String,
    pub op: OpId,
    pub batch: Option<BatchId>,
    pub actor: ActorId,
    pub actor_info: Option<ActorInfo>,
    pub scope: Option<ScopeRecord>,
    pub wall_ms: u64,
}

/// (text, newest inserting op, its batch, batch wall time)
type RawLine = (String, OpId, Option<BatchId>, u64);

pub fn blame(ws: &Workspace, path: &str) -> Result<Vec<LineOrigin>, Error> {
    let scopes = scope_index(ws);
    let lines = ws.read(|h| -> Result<Vec<RawLine>, Error> {
        let inode = h.lookup(path).ok_or_else(|| Error::Invalid(format!("{path} is not tracked")))?;
        let file = h.inode(&inode).and_then(|i| i.file()).ok_or_else(|| Error::Invalid(format!("{path} is not a file")))?;
        let mut out = Vec::new();
        let mut line = Vec::new();
        let mut newest = OpId::ZERO;
        let mut flush = |line: &mut Vec<u8>, newest: &mut OpId| {
            let batch = h.dag().batch_of(*newest);
            let wall = batch.and_then(|b| h.dag().header(&b)).map(|hd| hd.wall_ms).unwrap_or(0);
            out.push((String::from_utf8_lossy(line).trim_end_matches('\n').to_string(), *newest, batch, wall));
            line.clear();
            *newest = OpId::ZERO;
        };
        for (ins, off, len) in file.text.visible_spans() {
            let bytes = h.insertions().get(&ins).map(|b| &b[off as usize..(off + len) as usize]).unwrap_or(&[]);
            for &b in bytes {
                line.push(b);
                newest = newest.max(ins);
                if b == b'\n' {
                    flush(&mut line, &mut newest);
                }
            }
        }
        if !line.is_empty() {
            flush(&mut line, &mut newest);
        }
        Ok(out)
    })?;
    Ok(lines
        .into_iter()
        .enumerate()
        .map(|(i, (text, op, batch, wall_ms))| LineOrigin {
            line: i + 1,
            text,
            op,
            batch,
            actor: op.actor,
            actor_info: ws.actor_info(&op.actor),
            scope: batch.and_then(|b| scopes.get(&b).cloned()),
            wall_ms,
        })
        .collect())
}
