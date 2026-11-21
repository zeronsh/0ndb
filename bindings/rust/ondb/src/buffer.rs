use std::collections::{HashMap, VecDeque};

use serde::Deserialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Units {
    #[default]
    Bytes,
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
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct TextEdit {
    pub pos: u64,
    pub del: u64,
    pub ins: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpPart {
    Retain(u64),
    Delete(u64),
    Insert(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Operation {
    pub parts: Vec<OpPart>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BufferDelta {
    pub rev: u64,
    pub base: u64,
    pub actor: String,
    pub ops: Operation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Bias {
    #[default]
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Anchor(u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    pub base: u64,
    pub edits: Vec<TextEdit>,
}

#[derive(Debug, Clone)]
enum Doc {
    Bytes(Vec<u8>),
    Utf16(Vec<u16>),
}

impl Doc {
    fn new(units: Units, text: &str) -> Doc {
        match units {
            Units::Bytes => Doc::Bytes(text.as_bytes().to_vec()),
            Units::Utf16 => Doc::Utf16(text.encode_utf16().collect()),
        }
    }

    fn len(&self) -> u64 {
        match self {
            Doc::Bytes(v) => v.len() as u64,
            Doc::Utf16(v) => v.len() as u64,
        }
    }

    fn splice(&mut self, pos: u64, del: u64, ins: &str) {
        let (p, d) = (pos as usize, del as usize);
        match self {
            Doc::Bytes(v) => {
                let end = (p + d).min(v.len());
                v.splice(p.min(v.len())..end, ins.bytes());
            }
            Doc::Utf16(v) => {
                let end = (p + d).min(v.len());
                v.splice(p.min(v.len())..end, ins.encode_utf16());
            }
        }
    }

    fn text(&self) -> String {
        match self {
            Doc::Bytes(v) => String::from_utf8_lossy(v).into_owned(),
            Doc::Utf16(v) => String::from_utf16_lossy(v),
        }
    }
}

impl Operation {
    pub fn from_edits(doc_len: u64, edits: &[TextEdit]) -> Option<Operation> {
        let mut parts = Vec::new();
        let mut at = 0u64;
        for e in edits {
            if e.pos < at || e.pos + e.del > doc_len {
                return None;
            }
            if e.pos > at {
                parts.push(OpPart::Retain(e.pos - at));
            }
            if !e.ins.is_empty() {
                parts.push(OpPart::Insert(e.ins.clone()));
            }
            if e.del > 0 {
                parts.push(OpPart::Delete(e.del));
            }
            at = e.pos + e.del;
        }
        if doc_len > at {
            parts.push(OpPart::Retain(doc_len - at));
        }
        Some(Operation { parts }.normalized())
    }

    pub fn from_json(v: &serde_json::Value) -> Option<Operation> {
        let mut parts = Vec::new();
        for p in v.as_array()? {
            if let Some(n) = p.get("retain").and_then(|x| x.as_u64()) {
                parts.push(OpPart::Retain(n));
            } else if let Some(n) = p.get("delete").and_then(|x| x.as_u64()) {
                parts.push(OpPart::Delete(n));
            } else {
                parts.push(OpPart::Insert(p.get("insert").and_then(|x| x.as_str())?.to_string()));
            }
        }
        Some(Operation { parts }.normalized())
    }

    pub fn to_edits(&self) -> Vec<TextEdit> {
        let mut out: Vec<TextEdit> = Vec::new();
        let mut at = 0u64;
        for p in &self.parts {
            match p {
                OpPart::Retain(n) => at += n,
                OpPart::Delete(n) => {
                    match out.last_mut() {
                        Some(e) if e.pos + e.del == at => e.del += n,
                        _ => out.push(TextEdit { pos: at, del: *n, ins: String::new() }),
                    }
                    at += n;
                }
                OpPart::Insert(s) => match out.last_mut() {
                    Some(e) if e.pos + e.del == at => e.ins.push_str(s),
                    _ => out.push(TextEdit { pos: at, del: 0, ins: s.clone() }),
                },
            }
        }
        out
    }

    fn normalized(self) -> Operation {
        let mut parts: Vec<OpPart> = Vec::with_capacity(self.parts.len());
        for p in self.parts {
            match (parts.last_mut(), p) {
                (_, OpPart::Retain(0)) | (_, OpPart::Delete(0)) => {}
                (_, OpPart::Insert(s)) if s.is_empty() => {}
                (Some(OpPart::Retain(a)), OpPart::Retain(b)) => *a += b,
                (Some(OpPart::Delete(a)), OpPart::Delete(b)) => *a += b,
                (Some(OpPart::Insert(a)), OpPart::Insert(b)) => a.push_str(&b),
                (_, p) => parts.push(p),
            }
        }
        Operation { parts }
    }

    fn base_len(&self) -> u64 {
        self.parts
            .iter()
            .map(|p| match p {
                OpPart::Retain(n) | OpPart::Delete(n) => *n,
                OpPart::Insert(_) => 0,
            })
            .sum()
    }

    fn map_pos(&self, units: Units, pos: u64, bias: Bias) -> u64 {
        let (mut old, mut new) = (0u64, 0u64);
        for p in &self.parts {
            match p {
                OpPart::Retain(n) => {
                    if pos < old + n {
                        return new + (pos - old);
                    }
                    old += n;
                    new += n;
                }
                OpPart::Delete(n) => {
                    if pos < old + n {
                        return new;
                    }
                    old += n;
                }
                OpPart::Insert(s) => {
                    if pos == old && bias == Bias::Left {
                        return new;
                    }
                    new += units.len_of(s);
                }
            }
        }
        new + pos.saturating_sub(old)
    }
}

pub fn transform(units: Units, a: &Operation, b: &Operation, a_first: bool) -> (Operation, Operation) {
    let mut ap = Vec::new();
    let mut bp = Vec::new();
    let mut ia = a.parts.iter().cloned();
    let mut ib = b.parts.iter().cloned();
    let mut x = ia.next();
    let mut y = ib.next();
    loop {
        match (x.take(), y.take()) {
            (None, None) => break,
            (Some(OpPart::Insert(s)), Some(OpPart::Insert(t))) => {
                if a_first {
                    bp.push(OpPart::Retain(units.len_of(&s)));
                    ap.push(OpPart::Insert(s));
                    x = ia.next();
                    y = Some(OpPart::Insert(t));
                } else {
                    ap.push(OpPart::Retain(units.len_of(&t)));
                    bp.push(OpPart::Insert(t));
                    x = Some(OpPart::Insert(s));
                    y = ib.next();
                }
            }
            (Some(OpPart::Insert(s)), yy) => {
                bp.push(OpPart::Retain(units.len_of(&s)));
                ap.push(OpPart::Insert(s));
                x = ia.next();
                y = yy;
            }
            (xx, Some(OpPart::Insert(s))) => {
                ap.push(OpPart::Retain(units.len_of(&s)));
                bp.push(OpPart::Insert(s));
                x = xx;
                y = ib.next();
            }
            (None, _) | (_, None) => break,
            (Some(OpPart::Retain(n)), Some(OpPart::Retain(m))) => {
                let k = n.min(m);
                ap.push(OpPart::Retain(k));
                bp.push(OpPart::Retain(k));
                x = if n > k { Some(OpPart::Retain(n - k)) } else { ia.next() };
                y = if m > k { Some(OpPart::Retain(m - k)) } else { ib.next() };
            }
            (Some(OpPart::Delete(n)), Some(OpPart::Delete(m))) => {
                let k = n.min(m);
                x = if n > k { Some(OpPart::Delete(n - k)) } else { ia.next() };
                y = if m > k { Some(OpPart::Delete(m - k)) } else { ib.next() };
            }
            (Some(OpPart::Delete(n)), Some(OpPart::Retain(m))) => {
                let k = n.min(m);
                ap.push(OpPart::Delete(k));
                x = if n > k { Some(OpPart::Delete(n - k)) } else { ia.next() };
                y = if m > k { Some(OpPart::Retain(m - k)) } else { ib.next() };
            }
            (Some(OpPart::Retain(n)), Some(OpPart::Delete(m))) => {
                let k = n.min(m);
                bp.push(OpPart::Delete(k));
                x = if n > k { Some(OpPart::Retain(n - k)) } else { ia.next() };
                y = if m > k { Some(OpPart::Delete(m - k)) } else { ib.next() };
            }
        }
    }
    (Operation { parts: ap }.normalized(), Operation { parts: bp }.normalized())
}

pub struct Buffer {
    pub id: String,
    pub units: Units,
    pub actor: String,
    rev: u64,
    doc: Doc,
    pending: VecDeque<Operation>,
    anchors: HashMap<Anchor, (u64, Bias)>,
    next_anchor: u64,
}

impl Buffer {
    pub fn new(id: impl Into<String>, actor: impl Into<String>, units: Units, rev: u64, text: &str) -> Buffer {
        Buffer {
            id: id.into(),
            units,
            actor: actor.into(),
            rev,
            doc: Doc::new(units, text),
            pending: VecDeque::new(),
            anchors: HashMap::new(),
            next_anchor: 0,
        }
    }

    pub fn rev(&self) -> u64 {
        self.rev
    }

    pub fn len(&self) -> u64 {
        self.doc.len()
    }

    pub fn is_empty(&self) -> bool {
        self.doc.len() == 0
    }

    pub fn text(&self) -> String {
        self.doc.text()
    }

    pub fn in_flight(&self) -> usize {
        self.pending.len()
    }

    pub fn anchor(&mut self, pos: u64, bias: Bias) -> Anchor {
        self.next_anchor += 1;
        let a = Anchor(self.next_anchor);
        self.anchors.insert(a, (pos.min(self.doc.len()), bias));
        a
    }

    pub fn resolve(&self, a: Anchor) -> Option<u64> {
        self.anchors.get(&a).map(|(p, _)| *p)
    }

    pub fn drop_anchor(&mut self, a: Anchor) {
        self.anchors.remove(&a);
    }

    fn apply(&mut self, op: &Operation) {
        let mut at = 0u64;
        for p in &op.parts {
            match p {
                OpPart::Retain(n) => at += n,
                OpPart::Delete(n) => self.doc.splice(at, *n, ""),
                OpPart::Insert(s) => {
                    self.doc.splice(at, 0, s);
                    at += self.units.len_of(s);
                }
            }
        }
        let units = self.units;
        for (pos, bias) in self.anchors.values_mut() {
            *pos = op.map_pos(units, *pos, *bias);
        }
    }

    pub fn edit(&mut self, edits: &[TextEdit]) -> Option<Outgoing> {
        let op = Operation::from_edits(self.doc.len(), edits)?;
        self.apply(&op);
        let out = Outgoing {
            base: self.rev,
            edits: op.to_edits(),
        };
        self.pending.push_back(op);
        Some(out)
    }

    pub fn ack(&mut self, rev: u64) {
        if rev <= self.rev {
            return;
        }
        self.pending.pop_front();
        self.rev = rev;
    }

    pub fn receive(&mut self, delta: &BufferDelta) -> Option<Vec<TextEdit>> {
        if delta.rev <= self.rev {
            return Some(Vec::new());
        }
        if delta.actor == self.actor && !self.pending.is_empty() {
            self.ack(delta.rev);
            return Some(Vec::new());
        }
        let mut remote = delta.ops.clone();
        if remote.base_len() != self.server_len() {
            return None;
        }
        let mut transformed = VecDeque::with_capacity(self.pending.len());
        for p in self.pending.drain(..) {
            let (r2, p2) = transform(self.units, &remote, &p, true);
            remote = r2;
            transformed.push_back(p2);
        }
        self.pending = transformed;
        self.apply(&remote);
        self.rev = delta.rev;
        Some(remote.to_edits())
    }

    fn server_len(&self) -> u64 {
        let mut len = self.doc.len() as i64;
        for p in &self.pending {
            for part in &p.parts {
                match part {
                    OpPart::Insert(t) => len -= self.units.len_of(t) as i64,
                    OpPart::Delete(n) => len += *n as i64,
                    OpPart::Retain(_) => {}
                }
            }
        }
        len.max(0) as u64
    }
}
