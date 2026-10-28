//! Large-file edit benchmark: `cargo run --release -p ondb-core --example bigfile [lines] [edits]`.

use std::time::Instant;

use ondb_core::{ActorId, Content, FileMode, History, HistoryId, InodeId, LineEnding, Op, Splice, Version};

fn main() {
    let mut args = std::env::args().skip(1);
    let lines: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(200_000);
    let edits: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(20_000);
    let text: Vec<u8> = (0..lines).flat_map(|i| format!("line {i:08} of a fairly large source file\n").into_bytes()).collect();
    let mut h = History::new(HistoryId::random());
    let a = ActorId::random();
    let t = Instant::now();
    let (b, _) = h
        .transact(a, None, |t| {
            t.push(Op::CreateFile {
                parent: InodeId::ROOT,
                name: "big.txt".into(),
                mode: FileMode::Regular,
                line_ending: LineEnding::Lf,
                content: Content::Text(text.clone()),
            })
        })
        .unwrap();
    let inode = InodeId::new(b.unwrap().header.op_id(0), 0);
    println!("create {} MiB: {:?}", text.len() >> 20, t.elapsed());

    let mut seed = 0x9E3779B97F4A7C15u64;
    let mut rnd = |n: u64| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed % n.max(1)
    };
    let mut len = text.len() as u64;
    let t = Instant::now();
    for _ in 0..edits {
        let at = rnd(len);
        let del = rnd(8).min(len - at);
        let ins = b"edit\n".to_vec();
        h.transact(a, None, |t| {
            t.push(Op::EditText { inode, splices: vec![Splice { at, del, ins: ins.len() as u64 }], text: ins })
        })
        .unwrap()
        .1
        .unwrap();
        len = len - del + 5;
    }
    let el = t.elapsed();
    println!("{edits} local edits: {el:?} ({:.1} µs/edit)", el.as_micros() as f64 / edits as f64);

    // Edits authored against a stale parent (concurrent remote work).
    let stale: Version = h.heads().clone();
    let b2 = ActorId::random();
    for _ in 0..200 {
        let ins = b"x\n".to_vec();
        h.transact(a, None, |t| {
            t.push(Op::EditText { inode, splices: vec![Splice { at: rnd(len), del: 0, ins: 2 }], text: ins })
        })
        .unwrap()
        .1
        .unwrap();
        len += 2;
    }
    let base_len = h.text_in(&h.excluding(&h.exclusions_for(&stale)), &inode).unwrap().len() as u64;
    let t = Instant::now();
    for i in 0..1000u64 {
        let ins = b"y\n".to_vec();
        let at = (i * 7919) % base_len;
        h.transact(b2, Some(stale.clone()), |t| {
            t.push(Op::EditText { inode, splices: vec![Splice { at, del: 0, ins: 2 }], text: ins })
        })
        .unwrap()
        .1
        .unwrap();
    }
    let el = t.elapsed();
    println!("1000 stale-parent edits: {el:?} ({:.1} µs/edit)", el.as_micros() as f64 / 1000.0);

    let t = Instant::now();
    let out = h.text(&inode).unwrap();
    println!("read {} MiB: {:?}", out.len() >> 20, t.elapsed());
    let frags = h.inode(&inode).unwrap().file().unwrap().text.fragments_len();
    println!("fragments: {frags}");
}
