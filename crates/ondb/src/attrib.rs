//! Attribution scopes. A scope brackets work by one agent — a whole turn,
//! one tool call, one shell command — and records exactly which batches it
//! produced, including disk effects of programs the agent ran (scripts,
//! formatters, `sed`, code generators) that the mount ingested.
//!
//! The bracketing is precise because both ends are fenced: before the scope
//! opens, every earlier disk change is ingested (so it isn't blamed on the
//! scope); before it closes, every change the scope's processes made is
//! ingested (so none leak into the next scope). Records are stored in the
//! history itself, so attribution syncs to every replica.

use std::collections::{HashMap, HashSet};

use crossbeam_channel::Receiver;
use ondb_core::{ActorId, BatchId, Op, Version};
use ondb_store::Origin;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::Error;
use crate::mount::MountHandle;
use crate::workspace::{ActorKind, Event, Workspace};

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct ScopeId(pub Uuid);

impl std::fmt::Display for ScopeId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", &self.0.simple().to_string()[..12])
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ScopeKind {
    /// A full agent turn (external agents are attributed at this level).
    Turn,
    /// One tool invocation (edit tool, patch application).
    ToolCall,
    /// A shell command and every disk effect of the processes it ran.
    Command,
    /// Changes produced by reverting another scope.
    Revert,
    Other(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScopeRecord {
    pub id: ScopeId,
    pub kind: ScopeKind,
    pub label: String,
    /// The agent the scope's changes are credited to.
    pub agent: Option<ActorId>,
    pub parent: Option<ScopeId>,
    pub started_ms: u64,
    pub ended_ms: Option<u64>,
    pub start_version: Version,
    pub end_version: Option<Version>,
    /// Batches produced inside the scope, in commit order.
    pub batches: Vec<BatchId>,
    /// Every mount confirmed it had ingested the scope's disk effects. When
    /// false, some changes may still arrive later, so revert is refused.
    pub settled: bool,
}

pub fn scope_key(id: &ScopeId) -> String {
    format!("scope/{}", id.0)
}

/// An open scope. Dropping it without [`Recorder::end`] leaves it recorded
/// as unfinished.
pub struct Scope {
    record: ScopeRecord,
    events: Receiver<Event>,
    credit: HashSet<ActorId>,
}

impl Scope {
    pub fn id(&self) -> ScopeId {
        self.record.id
    }
}

#[derive(Clone)]
pub struct Recorder {
    ws: Workspace,
    mounts: Vec<MountHandle>,
    actor: ActorId,
}

impl Recorder {
    pub fn new(ws: &Workspace, mounts: Vec<MountHandle>) -> Result<Recorder, Error> {
        let actor = ws.actor("recorder", ActorKind::System)?;
        Ok(Recorder { ws: ws.clone(), mounts, actor })
    }

    fn fence_all(&self) -> Result<bool, Error> {
        let mut settled = true;
        for m in &self.mounts {
            settled &= m.fence()?.settled();
        }
        Ok(settled)
    }

    fn write(&self, record: &ScopeRecord) -> Result<(), Error> {
        let value = postcard::to_stdvec(record).map_err(|e| Error::Invalid(e.to_string()))?;
        self.ws.commit(self.actor, None, |txn| Ok(txn.push(Op::Meta { key: scope_key(&record.id), value: Some(value) })?))?;
        Ok(())
    }

    /// Opens a scope. Batches committed by `agent` or by any mount's
    /// ingestion actor until [`Recorder::end`] are credited to it.
    pub fn begin(&self, kind: ScopeKind, label: &str, agent: Option<ActorId>, parent: Option<ScopeId>) -> Result<Scope, Error> {
        self.fence_all()?;
        let events = self.ws.subscribe();
        let mut credit: HashSet<ActorId> = self.mounts.iter().map(|m| m.ingestion_actor()).collect();
        credit.extend(agent);
        let record = ScopeRecord {
            id: ScopeId(Uuid::new_v4()),
            kind,
            label: label.to_string(),
            agent,
            parent,
            started_ms: ondb_core::now_ms(),
            ended_ms: None,
            start_version: self.ws.heads(),
            end_version: None,
            batches: Vec::new(),
            settled: false,
        };
        self.write(&record)?;
        Ok(Scope { record, events, credit })
    }

    /// Closes a scope after fencing every mount, and records its batches.
    pub fn end(&self, scope: Scope) -> Result<ScopeRecord, Error> {
        let settled = self.fence_all()?;
        let Scope { mut record, events, credit } = scope;
        for ev in events.try_iter() {
            if let Event::Committed(c) = ev
                && c.origin == Origin::Local
                && credit.contains(&c.actor)
            {
                record.batches.push(c.batch);
            }
        }
        record.ended_ms = Some(ondb_core::now_ms());
        record.end_version = Some(self.ws.heads());
        record.settled = settled;
        self.write(&record)?;
        Ok(record)
    }

    /// Runs `f` inside a scope.
    pub fn scoped<R>(
        &self,
        kind: ScopeKind,
        label: &str,
        agent: Option<ActorId>,
        parent: Option<ScopeId>,
        f: impl FnOnce(&Scope) -> R,
    ) -> Result<(R, ScopeRecord), Error> {
        let scope = self.begin(kind, label, agent, parent)?;
        let out = f(&scope);
        Ok((out, self.end(scope)?))
    }

    /// Reverts everything a scope did, keeping later changes by others
    /// (selective undo), and records the revert as its own scope.
    pub fn revert(&self, id: &ScopeId, actor: ActorId, force: bool) -> Result<(Option<BatchId>, ScopeRecord), Error> {
        let target = scope(&self.ws, id)?.ok_or_else(|| Error::Invalid(format!("unknown scope {id}")))?;
        if target.ended_ms.is_none() {
            return Err(Error::Invalid(format!("scope {id} is still open")));
        }
        if !target.settled && !force {
            return Err(Error::Invalid(format!("scope {id} is not settled: some of its changes may still arrive")));
        }
        let batches: HashSet<BatchId> = target.batches.iter().copied().collect();
        let scope = self.begin(ScopeKind::Revert, &format!("revert {id}"), Some(actor), Some(*id))?;
        let batch = crate::revert::revert_batches(&self.ws, actor, &batches)?;
        Ok((batch, self.end(scope)?))
    }
}

pub fn scope(ws: &Workspace, id: &ScopeId) -> Result<Option<ScopeRecord>, Error> {
    ws.read(|h| h.meta(&scope_key(id)).map(postcard::from_bytes).transpose()).map_err(|e| Error::Invalid(e.to_string()))
}

pub fn scopes(ws: &Workspace) -> Vec<ScopeRecord> {
    let mut out: Vec<ScopeRecord> =
        ws.read(|h| h.meta_with_prefix("scope/").filter_map(|(_, v)| postcard::from_bytes(v).ok()).collect());
    out.sort_by_key(|s: &ScopeRecord| s.started_ms);
    out
}

/// batch -> innermost scope that produced it.
pub fn scope_index(ws: &Workspace) -> HashMap<BatchId, ScopeRecord> {
    let mut out: HashMap<BatchId, ScopeRecord> = HashMap::new();
    for s in scopes(ws) {
        for b in &s.batches {
            // Later-starting scopes are nested inside earlier ones.
            let replace = out.get(b).is_none_or(|cur| cur.started_ms <= s.started_ms);
            if replace {
                out.insert(*b, s.clone());
            }
        }
    }
    out
}
