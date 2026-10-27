//! Line-granular diffing. Ingested disk changes are recorded as whole-line
//! hunks (histogram diff), which keeps anchors in untouched lines intact and
//! produces edits that read like the change a human would describe.

use std::ops::Range;

use imara_diff::{Algorithm, Diff, InternedInput};

use crate::op::Splice;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LineHunk {
    pub old: Range<u32>,
    pub new: Range<u32>,
}

/// Byte offset of the start of every line, plus a final entry for the end.
pub fn line_starts(data: &[u8]) -> Vec<usize> {
    let mut starts = vec![0];
    for (i, b) in data.iter().enumerate() {
        if *b == b'\n' && i + 1 < data.len() {
            starts.push(i + 1);
        }
    }
    if data.is_empty() {
        return vec![0];
    }
    starts.push(data.len());
    starts
}

pub fn line_hunks(old: &[u8], new: &[u8]) -> Vec<LineHunk> {
    if old == new {
        return Vec::new();
    }
    let input = InternedInput::new(old, new);
    let mut diff = Diff::compute(Algorithm::Histogram, &input);
    diff.postprocess_lines(&input);
    diff.hunks().map(|h| LineHunk { old: h.before, new: h.after }).collect()
}

/// Splices turning `old` into `new`, with the concatenated inserted bytes.
pub fn line_splices(old: &[u8], new: &[u8]) -> (Vec<u8>, Vec<Splice>) {
    let hunks = line_hunks(old, new);
    if hunks.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let os = line_starts(old);
    let ns = line_starts(new);
    let at = |starts: &[usize], line: u32| starts[(line as usize).min(starts.len() - 1)] as u64;
    let mut text = Vec::new();
    let mut splices = Vec::with_capacity(hunks.len());
    for h in hunks {
        let o0 = at(&os, h.old.start);
        let o1 = at(&os, h.old.end);
        let n0 = at(&ns, h.new.start);
        let n1 = at(&ns, h.new.end);
        text.extend_from_slice(&new[n0 as usize..n1 as usize]);
        splices.push(Splice { at: o0, del: o1 - o0, ins: n1 - n0 });
    }
    (text, splices)
}

/// Applies splices (offsets in `base`) to bytes; the reference semantics
/// used by tests and by callers that need the result without a CRDT.
pub fn apply_splices(base: &[u8], text: &[u8], splices: &[Splice]) -> Vec<u8> {
    let mut out = Vec::with_capacity(base.len() + text.len());
    let (mut cursor, mut used) = (0usize, 0usize);
    for s in splices {
        out.extend_from_slice(&base[cursor..s.at as usize]);
        out.extend_from_slice(&text[used..used + s.ins as usize]);
        used += s.ins as usize;
        cursor = (s.at + s.del) as usize;
    }
    out.extend_from_slice(&base[cursor..]);
    out
}

/// Unified diff body (`@@ -a,b +c,d @@` hunks with `context` lines).
pub fn unified(old: &[u8], new: &[u8], context: u32) -> Vec<String> {
    let hunks = line_hunks(old, new);
    let os = line_starts(old);
    let ns = line_starts(new);
    let lines = |data: &[u8], starts: &[usize], r: Range<u32>| -> Vec<String> {
        r.map(|i| {
            let (a, b) = (starts[i as usize], starts[(i as usize + 1).min(starts.len() - 1)]);
            String::from_utf8_lossy(&data[a..b]).trim_end_matches(['\n', '\r']).to_string()
        })
        .collect()
    };
    let n_old = (os.len() - 1) as u32;
    let n_new = (ns.len() - 1) as u32;
    // Group hunks whose context windows touch.
    let mut groups: Vec<Vec<LineHunk>> = Vec::new();
    for h in hunks {
        match groups.last_mut() {
            Some(g) if h.old.start <= g.last().unwrap().old.end + 2 * context => g.push(h),
            _ => groups.push(vec![h]),
        }
    }
    let mut out = Vec::new();
    for g in groups {
        let first = &g[0];
        let last = g.last().unwrap();
        let o_start = first.old.start.saturating_sub(context);
        let n_start = first.new.start.saturating_sub(first.old.start - o_start);
        let o_end = (last.old.end + context).min(n_old);
        let n_end = (last.new.end + (o_end - last.old.end)).min(n_new);
        let mut body = Vec::new();
        let mut o = o_start;
        for h in &g {
            for l in lines(old, &os, o..h.old.start) {
                body.push(format!(" {l}"));
            }
            for l in lines(old, &os, h.old.clone()) {
                body.push(format!("-{l}"));
            }
            for l in lines(new, &ns, h.new.clone()) {
                body.push(format!("+{l}"));
            }
            o = h.old.end;
        }
        for l in lines(old, &os, o..o_end) {
            body.push(format!(" {l}"));
        }
        let range = |start: u32, end: u32| {
            let count = end - start;
            let first = if count == 0 { start } else { start + 1 };
            format!("{first},{count}")
        };
        out.push(format!("@@ -{} +{} @@", range(o_start, o_end), range(n_start, n_end)));
        out.extend(body);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splices_roundtrip_and_are_line_granular() {
        let old = b"a\nb\nc\nd\n";
        let new = b"a\nB\nc\nd\ne\n";
        let (text, splices) = line_splices(old, new);
        assert_eq!(apply_splices(old, &text, &splices), new);
        assert_eq!(splices[0], Splice { at: 2, del: 2, ins: 2 });
        for s in &splices {
            assert!(s.at == 0 || old[s.at as usize - 1] == b'\n');
        }
    }

    #[test]
    fn handles_missing_trailing_newline() {
        let old = b"x\ny";
        let new = b"x\ny\nz";
        let (text, splices) = line_splices(old, new);
        assert_eq!(apply_splices(old, &text, &splices), new);
        let (text, splices) = line_splices(b"", b"hi\n");
        assert_eq!(apply_splices(b"", &text, &splices), b"hi\n");
    }

    #[test]
    fn unified_output() {
        let out = unified(b"a\nb\nc\n", b"a\nx\nc\n", 1);
        assert_eq!(out, vec!["@@ -1,3 +1,3 @@", " a", "-b", "+x", " c"]);
    }
}
