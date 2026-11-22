use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::conn::{Client, Pending, SubItem, Subscription};
use crate::error::{Error, Result, Status};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Units {
    Bytes,
    #[default]
    Utf16,
}

impl Units {
    pub fn name(self) -> &'static str {
        match self {
            Units::Bytes => "bytes",
            Units::Utf16 => "utf16",
        }
    }

    pub fn len_of(self, s: &str) -> u64 {
        match self {
            Units::Bytes => s.len() as u64,
            Units::Utf16 => s.encode_utf16().count() as u64,
        }
    }

    fn units(self, s: &str) -> Vec<u32> {
        match self {
            Units::Bytes => s.bytes().map(u32::from).collect(),
            Units::Utf16 => s.encode_utf16().map(u32::from).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct TextEdit {
    pub pos: u64,
    pub del: u64,
    pub ins: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Retain(u64),
    Delete(u64),
    Insert(String),
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct WireOp {
    pub kind: String,
    pub n: u64,
    pub text: String,
    pub author: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Range {
    pub anchor: i64,
    pub head: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CursorSet {
    pub device: Option<String>,
    pub actor: Option<String>,
    pub ranges: Vec<Range>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct BufferEvent {
    pub kind: String,
    pub buffer: u64,
    pub rev: u64,
    pub ack: u64,
    pub length: u64,
    pub text: String,
    pub more: bool,
    pub actor: Option<String>,
    pub line: String,
    pub ops: Vec<WireOp>,
    pub cursors: Vec<CursorSet>,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Anchor {
    Start,
    End,
    At { actor: String, seq: u64, offset: u64, after: bool },
}

impl Anchor {
    pub fn parse(s: &str) -> Option<Anchor> {
        match s {
            "s" => return Some(Anchor::Start),
            "e" => return Some(Anchor::End),
            _ => {}
        }
        let parts: Vec<&str> = s.split('.').collect();
        if parts.len() != 3 && parts.len() != 4 {
            return None;
        }
        let after = match parts[parts.len() - 1] {
            "b" => false,
            "a" => true,
            _ => return None,
        };
        let offset = if parts.len() == 4 { parts[2].parse().ok()? } else { 0 };
        Some(Anchor::At {
            actor: parts[0].to_string(),
            seq: parts[1].parse().ok()?,
            offset,
            after,
        })
    }

    pub fn sticks_forward(&self) -> bool {
        match self {
            Anchor::Start => false,
            Anchor::End => true,
            Anchor::At { after, .. } => !after,
        }
    }

    pub fn text(&self) -> String {
        match self {
            Anchor::Start => "s".into(),
            Anchor::End => "e".into(),
            Anchor::At { actor, seq, offset, after } => {
                let b = if *after { "a" } else { "b" };
                if *offset > 0 {
                    format!("{actor}.{seq}.{offset}.{b}")
                } else {
                    format!("{actor}.{seq}.{b}")
                }
            }
        }
    }
}

#[derive(Debug, Clone)]
pub enum Change {
    Delta { ops: Vec<Op>, rev: u64 },
    Cursors(Vec<CursorSet>),
    Closed(String),
    Reopen,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditRequest {
    pub seq: u64,
    pub rev: u64,
    pub pos: Vec<u64>,
    pub del: Vec<u64>,
    pub ins: Vec<String>,
}

const HOLE: u32 = u32::MAX;

fn op_len(units: Units, o: &Op) -> u64 {
    match o {
        Op::Retain(n) | Op::Delete(n) => *n,
        Op::Insert(s) => units.len_of(s),
    }
}

fn push_op(out: &mut Vec<Op>, o: Op) {
    match &o {
        Op::Retain(0) | Op::Delete(0) => return,
        Op::Insert(s) if s.is_empty() => return,
        _ => {}
    }
    match (out.last_mut(), &o) {
        (Some(Op::Retain(a)), Op::Retain(b)) => *a += b,
        (Some(Op::Delete(a)), Op::Delete(b)) => *a += b,
        _ => out.push(o),
    }
}

fn trim_ops(mut out: Vec<Op>) -> Vec<Op> {
    while matches!(out.last(), Some(Op::Retain(_))) {
        out.pop();
    }
    out
}

pub fn ops_from_wire(ops: &[WireOp]) -> Vec<Op> {
    let mut out = Vec::with_capacity(ops.len());
    for o in ops {
        match o.kind.as_str() {
            "retain" => push_op(&mut out, Op::Retain(o.n)),
            "delete" => push_op(&mut out, Op::Delete(o.n)),
            _ => push_op(&mut out, Op::Insert(o.text.clone())),
        }
    }
    out
}

pub fn edits_to_ops(edits: &[TextEdit]) -> Option<Vec<Op>> {
    let mut ops = Vec::new();
    let mut at = 0u64;
    for e in edits {
        if e.pos < at {
            return None;
        }
        push_op(&mut ops, Op::Retain(e.pos - at));
        push_op(&mut ops, Op::Delete(e.del));
        push_op(&mut ops, Op::Insert(e.ins.clone()));
        at = e.pos + e.del;
    }
    Some(trim_ops(ops))
}

pub fn ops_to_edits(ops: &[Op]) -> Vec<TextEdit> {
    let mut out: Vec<TextEdit> = Vec::new();
    let mut at = 0u64;
    for o in ops {
        match o {
            Op::Retain(n) => at += n,
            Op::Delete(n) => {
                match out.last_mut() {
                    Some(e) if e.pos + e.del == at && e.ins.is_empty() => e.del += n,
                    _ => out.push(TextEdit { pos: at, del: *n, ins: String::new() }),
                }
                at += n;
            }
            Op::Insert(s) => match out.last_mut() {
                Some(e) if e.pos + e.del == at => e.ins.push_str(s),
                _ => out.push(TextEdit { pos: at, del: 0, ins: s.clone() }),
            },
        }
    }
    out
}

pub fn transform(units: Units, a: &[Op], b: &[Op]) -> (Vec<Op>, Vec<Op>) {
    let mut ao = Vec::new();
    let mut bo = Vec::new();
    let (mut i, mut j, mut ui, mut uj) = (0usize, 0usize, 0u64, 0u64);
    let rem = |ops: &[Op], k: usize, used: u64| -> (Option<Op>, u64) {
        if k < ops.len() {
            (Some(ops[k].clone()), op_len(units, &ops[k]) - used)
        } else {
            (None, u64::MAX)
        }
    };
    loop {
        if i >= a.len() && j >= b.len() {
            break;
        }
        let (oa, ra) = rem(a, i, ui);
        let (ob, rb) = rem(b, j, uj);
        if let Some(Op::Insert(s)) = &oa {
            push_op(&mut ao, Op::Insert(s.clone()));
            push_op(&mut bo, Op::Retain(ra));
            i += 1;
            ui = 0;
            continue;
        }
        if let Some(Op::Insert(s)) = &ob {
            push_op(&mut ao, Op::Retain(rb));
            push_op(&mut bo, Op::Insert(s.clone()));
            j += 1;
            uj = 0;
            continue;
        }
        let k = ra.min(rb);
        let ka = matches!(oa, None | Some(Op::Retain(_)));
        let kb = matches!(ob, None | Some(Op::Retain(_)));
        match (ka, kb) {
            (true, true) => {
                push_op(&mut ao, Op::Retain(k));
                push_op(&mut bo, Op::Retain(k));
            }
            (false, true) => push_op(&mut ao, Op::Delete(k)),
            (true, false) => push_op(&mut bo, Op::Delete(k)),
            (false, false) => {}
        }
        if i < a.len() {
            ui += k;
            if ui >= op_len(units, &a[i]) {
                i += 1;
                ui = 0;
            }
        }
        if j < b.len() {
            uj += k;
            if uj >= op_len(units, &b[j]) {
                j += 1;
                uj = 0;
            }
        }
    }
    (trim_ops(ao), trim_ops(bo))
}

pub fn transform_position(units: Units, ops: &[Op], pos: u64, after: bool) -> u64 {
    let (mut old, mut shift) = (0u64, 0i64);
    for o in ops {
        let n = op_len(units, o);
        match o {
            Op::Retain(_) => {
                if pos < old + n {
                    return (pos as i64 + shift) as u64;
                }
                old += n;
            }
            Op::Insert(_) => {
                if pos == old && !after {
                    return (pos as i64 + shift) as u64;
                }
                shift += n as i64;
            }
            Op::Delete(_) => {
                if pos <= old {
                    return (pos as i64 + shift) as u64;
                }
                if pos < old + n {
                    return (old as i64 + shift) as u64;
                }
                shift -= n as i64;
                old += n;
            }
        }
    }
    (pos as i64 + shift) as u64
}

struct Unacked {
    seq: u64,
    ops: Vec<Op>,
}

pub struct BufferState {
    pub id: u64,
    pub units: Units,
    pub actor: Option<String>,
    pub line: String,
    rev: u64,
    seq: u64,
    ack: u64,
    pending: VecDeque<Unacked>,
    acks: VecDeque<(u64, u64)>,
    doc: Vec<u32>,
    own_text: bool,
    page: Option<String>,
    length: u64,
    ver: u64,
    log: VecDeque<(u64, Vec<Op>)>,
    watch: BTreeMap<u64, usize>,
    cursors: Vec<CursorSet>,
    closed: bool,
}

impl BufferState {
    pub fn from_open(open: &BufferEvent, units: Units) -> BufferState {
        BufferState::from_open_with(open, units, false)
    }

    pub fn from_open_with(open: &BufferEvent, units: Units, own_text: bool) -> BufferState {
        let mut doc = if own_text { Vec::new() } else { units.units(&open.text) };
        if !own_text && (doc.len() as u64) < open.length {
            doc.resize(open.length as usize, HOLE);
        }
        BufferState {
            id: open.buffer,
            units,
            actor: open.actor.clone(),
            line: open.line.clone(),
            rev: open.rev,
            seq: 0,
            ack: 0,
            pending: VecDeque::new(),
            acks: VecDeque::new(),
            doc,
            own_text,
            page: if own_text { Some(open.text.clone()) } else { None },
            length: open.length,
            ver: 0,
            log: VecDeque::new(),
            watch: BTreeMap::new(),
            cursors: Vec::new(),
            closed: false,
        }
    }

    pub fn rev(&self) -> u64 {
        self.rev
    }

    pub fn len(&self) -> u64 {
        self.length
    }

    pub fn is_empty(&self) -> bool {
        self.length == 0
    }

    pub fn mirrors_text(&self) -> bool {
        !self.own_text
    }

    pub fn take_page(&mut self) -> Option<String> {
        self.page.take()
    }

    pub fn unacked(&self) -> usize {
        self.pending.len()
    }

    pub fn sent(&self) -> u64 {
        self.seq
    }

    pub fn acked_seq(&self) -> u64 {
        self.ack
    }

    pub fn is_closed(&self) -> bool {
        self.closed
    }

    pub fn cursors(&self) -> &[CursorSet] {
        &self.cursors
    }

    pub fn holes(&self) -> Vec<(u64, u64)> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < self.doc.len() {
            if self.doc[i] == HOLE {
                let s = i;
                while i < self.doc.len() && self.doc[i] == HOLE {
                    i += 1;
                }
                out.push((s as u64, (i - s) as u64));
            } else {
                i += 1;
            }
        }
        out
    }

    pub fn loaded(&self) -> bool {
        !self.doc.contains(&HOLE)
    }

    pub fn text(&self) -> String {
        match self.units {
            Units::Bytes => {
                let b: Vec<u8> = self.doc.iter().filter(|u| **u != HOLE).map(|u| *u as u8).collect();
                String::from_utf8_lossy(&b).into_owned()
            }
            Units::Utf16 => {
                let v: Vec<u16> = self.doc.iter().filter(|u| **u != HOLE).map(|u| *u as u16).collect();
                String::from_utf16_lossy(&v)
            }
        }
    }

    pub fn slice(&self, from: u64, to: u64) -> String {
        let to = (to as usize).min(self.doc.len());
        let from = (from as usize).min(to);
        let part = &self.doc[from..to];
        match self.units {
            Units::Bytes => {
                let b: Vec<u8> = part.iter().filter(|u| **u != HOLE).map(|u| *u as u8).collect();
                String::from_utf8_lossy(&b).into_owned()
            }
            Units::Utf16 => {
                let v: Vec<u16> = part.iter().filter(|u| **u != HOLE).map(|u| *u as u16).collect();
                String::from_utf16_lossy(&v)
            }
        }
    }

    pub fn unit(&self, at: u64) -> Option<u32> {
        self.doc.get(at as usize).copied().filter(|u| *u != HOLE)
    }

    fn watch_begin(&mut self) -> u64 {
        *self.watch.entry(self.ver).or_insert(0) += 1;
        self.ver
    }

    fn watch_end(&mut self, ver: u64, positions: &[i64], after: &[bool]) -> Vec<i64> {
        let units = self.units;
        let out = positions
            .iter()
            .enumerate()
            .map(|(i, p)| {
                if *p < 0 {
                    return *p;
                }
                let a = after.get(i).copied().unwrap_or(false);
                let mut q = *p as u64;
                for (v, ops) in self.log.iter() {
                    if *v > ver {
                        q = transform_position(units, ops, q, a);
                    }
                }
                q as i64
            })
            .collect();
        if let Some(n) = self.watch.get_mut(&ver) {
            *n -= 1;
            if *n == 0 {
                self.watch.remove(&ver);
            }
        }
        match self.watch.keys().next().copied() {
            Some(low) => {
                while self.log.front().is_some_and(|(v, _)| *v <= low) {
                    self.log.pop_front();
                }
            }
            None => self.log.clear(),
        }
        out
    }

    fn apply(&mut self, ops: &[Op]) {
        self.ver += 1;
        if !self.watch.is_empty() {
            self.log.push_back((self.ver, ops.to_vec()));
        }
        for o in ops {
            match o {
                Op::Retain(_) => {}
                Op::Delete(n) => self.length = self.length.saturating_sub(*n),
                Op::Insert(t) => self.length += self.units.len_of(t),
            }
        }
        if self.own_text {
            return;
        }
        let mut at = 0usize;
        for o in ops {
            match o {
                Op::Retain(n) => at += *n as usize,
                Op::Delete(n) => {
                    let end = (at + *n as usize).min(self.doc.len());
                    self.doc.drain(at.min(end)..end);
                }
                Op::Insert(s) => {
                    let u = self.units.units(s);
                    let k = u.len();
                    let p = at.min(self.doc.len());
                    self.doc.splice(p..p, u);
                    at = p + k;
                }
            }
        }
    }

    fn acked(&mut self, ack: u64) {
        self.ack = self.ack.max(ack);
        while self.pending.front().is_some_and(|p| p.seq <= ack) {
            self.pending.pop_front();
        }
    }

    pub fn local(&self, pos: i64, ack: u64, after: bool) -> i64 {
        if pos < 0 {
            return pos;
        }
        let mut p = pos as u64;
        for e in &self.pending {
            if e.seq > ack {
                p = transform_position(self.units, &e.ops, p, after);
            }
        }
        p as i64
    }

    pub fn edit_result(&mut self, rev: u64, ack: u64) {
        if rev <= self.rev {
            self.acked(ack);
        } else {
            self.acks.push_back((rev, ack));
        }
    }

    pub fn edit(&mut self, edits: &[TextEdit]) -> Result<Option<EditRequest>> {
        if self.closed {
            return Err(Error::Status(Status::CLOSED));
        }
        let ops = edits_to_ops(edits).ok_or(Error::Status(Status::INVALID))?;
        if ops.is_empty() {
            return Ok(None);
        }
        let end = edits.last().map(|e| e.pos + e.del).unwrap_or(0);
        if end > self.len() {
            return Err(Error::Status(Status::INVALID));
        }
        self.apply(&ops);
        self.seq += 1;
        self.pending.push_back(Unacked { seq: self.seq, ops });
        Ok(Some(EditRequest {
            seq: self.seq,
            rev: self.rev,
            pos: edits.iter().map(|e| e.pos).collect(),
            del: edits.iter().map(|e| e.del).collect(),
            ins: edits.iter().map(|e| e.ins.clone()).collect(),
        }))
    }

    pub fn fill(&mut self, from: i64, ack: u64, text: &str) {
        let at = self.local(from, ack, false);
        if at < 0 || self.own_text {
            return;
        }
        for (k, x) in self.units.units(text).into_iter().enumerate() {
            let i = at as usize + k;
            if i < self.doc.len() && self.doc[i] == HOLE {
                self.doc[i] = x;
            }
        }
    }

    pub fn receive(&mut self, ev: &BufferEvent) -> Option<Change> {
        match ev.kind.as_str() {
            "delta" => {
                self.acked(ev.ack);
                let mut d = ops_from_wire(&ev.ops);
                for p in self.pending.iter_mut() {
                    let (p2, d2) = transform(self.units, &p.ops, &d);
                    p.ops = p2;
                    d = d2;
                }
                self.apply(&d);
                self.rev = ev.rev;
                while let Some(&(rev, ack)) = self.acks.front() {
                    if rev > self.rev {
                        break;
                    }
                    self.acks.pop_front();
                    self.acked(ack);
                }
                let units = self.units;
                for c in self.cursors.iter_mut() {
                    for r in c.ranges.iter_mut() {
                        if r.anchor >= 0 {
                            r.anchor = transform_position(units, &d, r.anchor as u64, true) as i64;
                        }
                        if r.head >= 0 {
                            r.head = transform_position(units, &d, r.head as u64, true) as i64;
                        }
                    }
                }
                Some(Change::Delta { ops: d, rev: ev.rev })
            }
            "cursors" => {
                let mut list = ev.cursors.clone();
                for c in list.iter_mut() {
                    for r in c.ranges.iter_mut() {
                        r.anchor = self.local(r.anchor, ev.ack, true);
                        r.head = self.local(r.head, ev.ack, true);
                    }
                }
                self.cursors = list.clone();
                Some(Change::Cursors(list))
            }
            "closed" => {
                self.closed = true;
                Some(Change::Closed(ev.status.clone()))
            }
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct OpenArgs {
    pub object: String,
    pub path: String,
    pub line: String,
    pub units: Units,
    pub actor: Option<String>,
    pub page: u64,
    pub own_text: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ReadReply {
    pub rev: u64,
    pub ack: u64,
    pub from: i64,
    pub length: u64,
    pub text: String,
    #[serde(skip)]
    pub local: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct TextReply {
    pub rev: u64,
    pub text: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct AckReply {
    ack: u64,
    rev: u64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct DoneReply {
    done: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct AnchorsReply {
    anchors: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct ResolveReply {
    positions: Vec<i64>,
}

pub struct LiveBuffer {
    client: Client,
    sub: Subscription,
    state: Arc<Mutex<BufferState>>,
    inflight: Mutex<Vec<Pending<u64>>>,
    failed: Mutex<Option<Error>>,
}

impl LiveBuffer {
    pub fn open(client: &Client, args: &OpenArgs) -> Pending<LiveBuffer> {
        let mut req = json!({"op": "buffer.open", "object": args.object, "units": args.units.name()});
        if !args.path.is_empty() {
            req["path"] = json!(args.path);
        }
        if !args.line.is_empty() {
            req["line"] = json!(args.line);
        }
        if let Some(a) = &args.actor {
            req["actor"] = json!(a);
        }
        if args.page > 0 {
            req["page"] = json!(args.page);
        }
        let units = args.units;
        let own_text = args.own_text;
        let c2 = client.clone();
        client.subscribe_raw_with(&req, move |sub, open| {
            let ev: BufferEvent = serde_json::from_slice(open)?;
            Ok(LiveBuffer {
                client: c2,
                sub,
                state: Arc::new(Mutex::new(BufferState::from_open_with(&ev, units, own_text))),
                inflight: Mutex::new(Vec::new()),
                failed: Mutex::new(None),
            })
        })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, BufferState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn with_state<T>(&self, f: impl FnOnce(&BufferState) -> T) -> T {
        f(&self.state())
    }

    pub fn take_page(&self) -> Option<String> {
        self.state().take_page()
    }

    pub fn id(&self) -> u64 {
        self.state().id
    }

    pub fn rev(&self) -> u64 {
        self.state().rev()
    }

    pub fn len(&self) -> u64 {
        self.state().len()
    }

    pub fn is_empty(&self) -> bool {
        self.state().is_empty()
    }

    pub fn unacked(&self) -> usize {
        self.state().unacked()
    }

    pub fn loaded(&self) -> bool {
        self.state().loaded()
    }

    pub fn cursors(&self) -> Vec<CursorSet> {
        self.state().cursors().to_vec()
    }

    pub fn text(&self) -> String {
        self.state().text()
    }

    fn reap(&self) {
        let mut list = self.inflight.lock().unwrap_or_else(|e| e.into_inner());
        let mut keep = Vec::with_capacity(list.len());
        for mut p in list.drain(..) {
            match p.try_take() {
                None => keep.push(p),
                Some(Ok(_)) => {}
                Some(Err(e)) => {
                    let mut f = self.failed.lock().unwrap_or_else(|e| e.into_inner());
                    if f.is_none() {
                        *f = Some(e);
                    }
                }
            }
        }
        *list = keep;
    }

    fn failure(&self) -> Option<Change> {
        self.reap();
        let f = self.failed.lock().unwrap_or_else(|e| e.into_inner()).take()?;
        Some(match f {
            Error::Status(st) => Change::Closed(st.name().to_string()),
            _ => Change::Reopen,
        })
    }

    pub fn in_flight(&self) -> usize {
        self.reap();
        self.inflight.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    pub fn flush_blocking(&self) -> Result<()> {
        let list: Vec<Pending<u64>> = std::mem::take(&mut *self.inflight.lock().unwrap_or_else(|e| e.into_inner()));
        let mut first = None;
        for p in list {
            if let Err(e) = p.wait() {
                first.get_or_insert(e);
            }
        }
        match first {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    fn take(&self, item: SubItem) -> Option<Change> {
        match item {
            SubItem::Raw(b) => {
                let ev: BufferEvent = serde_json::from_slice(&b).ok()?;
                self.state().receive(&ev)
            }
            SubItem::Gap(_) => Some(Change::Reopen),
            SubItem::Deltas(_) | SubItem::Runners(_) => None,
        }
    }

    pub async fn recv(&mut self) -> Option<Change> {
        if let Some(c) = self.failure() {
            return Some(c);
        }
        loop {
            let item = self.sub.recv().await?;
            if let Some(c) = self.take(item) {
                return Some(c);
            }
        }
    }

    pub fn blocking_recv_timeout(&mut self, timeout: std::time::Duration) -> Option<Change> {
        if let Some(c) = self.failure() {
            return Some(c);
        }
        loop {
            let item = self.sub.blocking_recv_timeout(timeout)?;
            if let Some(c) = self.take(item) {
                return Some(c);
            }
        }
    }

    pub fn try_recv(&mut self) -> Option<Change> {
        if let Some(c) = self.failure() {
            return Some(c);
        }
        loop {
            let item = self.sub.try_recv()?;
            if let Some(c) = self.take(item) {
                return Some(c);
            }
        }
    }

    pub fn edit(&self, edits: &[TextEdit], group: u64) -> Result<Option<u64>> {
        self.reap();
        let (req, id) = {
            let mut st = self.state();
            match st.edit(edits)? {
                Some(r) => (r, st.id),
                None => return Ok(None),
            }
        };
        let body = json!({"op": "buffer.edit", "buffer": id, "rev": req.rev, "group": group, "pos": req.pos, "del": req.del, "ins": req.ins});
        let state = self.state.clone();
        let p = self.client.call_then::<AckReply, u64>(&body, move |r| {
            state.lock().unwrap_or_else(|e| e.into_inner()).edit_result(r.rev, r.ack);
            r.ack
        });
        self.inflight.lock().unwrap_or_else(|e| e.into_inner()).push(p);
        Ok(Some(req.seq))
    }

    pub fn read(&self, from: u64, len: u64) -> Pending<ReadReply> {
        let (id, rev) = {
            let st = self.state();
            (st.id, st.rev)
        };
        let state = self.state.clone();
        self.client.call_then::<ReadReply, ReadReply>(&json!({"op": "buffer.read", "buffer": id, "rev": rev, "from": from, "len": len}), move |mut r| {
            let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
            r.local = st.local(r.from, r.ack, false);
            st.fill(r.from, r.ack, &r.text);
            r
        })
    }

    pub fn load_all_blocking(&self, chunk: u64) -> Result<()> {
        loop {
            let first = self.state().holes().first().copied();
            let Some((at, n)) = first else { return Ok(()) };
            self.read(at, n.min(chunk.max(1))).wait()?;
        }
    }

    pub fn anchors(&self, positions: &[u64], after: bool) -> Pending<Vec<Anchor>> {
        let (id, rev) = {
            let st = self.state();
            (st.id, st.rev)
        };
        let bias = if after { "after" } else { "before" };
        self.client
            .call_then::<AnchorsReply, Vec<Anchor>>(&json!({"op": "buffer.anchors", "buffer": id, "rev": rev, "positions": positions, "bias": bias}), |r| {
                r.anchors.iter().filter_map(|a| Anchor::parse(a)).collect()
            })
    }

    pub fn resolve(&self, anchors: &[Anchor]) -> Pending<Vec<i64>> {
        let (id, rev, ver) = {
            let mut st = self.state();
            let ver = st.watch_begin();
            (st.id, st.rev, ver)
        };
        let state = self.state.clone();
        let list: Vec<String> = anchors.iter().map(Anchor::text).collect();
        let after: Vec<bool> = anchors.iter().map(Anchor::sticks_forward).collect();
        let token = Arc::new(Mutex::new(Some(ver)));
        let (state2, token2) = (self.state.clone(), token.clone());
        let mut p = self.client.call_then::<ResolveReply, Vec<i64>>(&json!({"op": "buffer.resolve", "buffer": id, "rev": rev, "anchors": list}), move |r| {
            match token.lock().unwrap_or_else(|e| e.into_inner()).take() {
                Some(v) => state.lock().unwrap_or_else(|e| e.into_inner()).watch_end(v, &r.positions, &after),
                None => r.positions,
            }
        });
        p.on_drop(move || {
            if let Some(v) = token2.lock().unwrap_or_else(|e| e.into_inner()).take() {
                state2.lock().unwrap_or_else(|e| e.into_inner()).watch_end(v, &[], &[]);
            }
        });
        p
    }

    pub fn set_cursors(&self, ranges: &[Range]) -> Pending<crate::types::Ack> {
        let (id, rev) = {
            let st = self.state();
            (st.id, st.rev)
        };
        let flat: Vec<i64> = ranges.iter().flat_map(|r| [r.anchor, r.head]).collect();
        self.client.call(&json!({"op": "buffer.cursors", "buffer": id, "rev": rev, "ranges": flat}))
    }

    pub fn undo(&self) -> Pending<bool> {
        let id = self.state().id;
        self.client.call_then::<DoneReply, bool>(&json!({"op": "buffer.undo", "buffer": id}), |r| r.done)
    }

    pub fn redo(&self) -> Pending<bool> {
        let id = self.state().id;
        self.client.call_then::<DoneReply, bool>(&json!({"op": "buffer.redo", "buffer": id}), |r| r.done)
    }

    pub fn ack(&self) -> Pending<crate::types::Ack> {
        let (id, rev) = {
            let st = self.state();
            (st.id, st.rev)
        };
        self.client.call(&json!({"op": "buffer.ack", "buffer": id, "rev": rev}))
    }

    pub fn server_text(&self) -> Pending<TextReply> {
        let id = self.state().id;
        self.client.call(&json!({"op": "buffer.text", "buffer": id}))
    }
}
