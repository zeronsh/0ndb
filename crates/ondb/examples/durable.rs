//! Durable edit benchmark: every edit is a committed SQLite transaction.
//! `cargo run --release -p ondb --example durable [lines] [edits]`

use std::time::Instant;

use ondb::{ActorKind, Workspace};
use ondb_core::{Content, FileMode, InodeId, LineEnding, Op, Splice};

fn main() {
    let mut args = std::env::args().skip(1);
    let lines: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(200_000);
    let edits: u64 = args.next().and_then(|a| a.parse().ok()).unwrap_or(2_000);
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("0ndb.db");
    let ws = Workspace::open(&db, None).unwrap();
    let actor = ws.actor("bench", ActorKind::Agent).unwrap();
    let body: Vec<u8> = (0..lines).flat_map(|i| format!("line {i:08} of a fairly large source file\n").into_bytes()).collect();
    let t = Instant::now();
    let (batch, inode) = ws
        .commit(actor, None, |txn| {
            let (content, blob) = Content::text(body.clone());
            txn.attach_blob(blob.unwrap());
            let op = txn.push(Op::CreateFile {
                parent: InodeId::ROOT,
                name: "big.txt".into(),
                mode: FileMode::Regular,
                line_ending: LineEnding::Lf,
                content,
            })?;
            Ok(InodeId::new(op, 0))
        })
        .unwrap();
    assert!(batch.is_some());
    println!("create {} MiB (durable): {:?}", body.len() >> 20, t.elapsed());
    let mut len = body.len() as u64;
    let t = Instant::now();
    for i in 0..edits {
        let at = (i * 7_919_993) % len;
        ws.commit(actor, None, |txn| {
            Ok(txn.push(Op::EditText { inode, text: b"edit\n".to_vec(), splices: vec![Splice { at, del: 1, ins: 5 }] })?)
        })
        .unwrap();
        len += 4;
    }
    let el = t.elapsed();
    println!("{edits} durable edits: {el:?} ({:.0} µs/commit)", el.as_micros() as f64 / edits as f64);
    let expected = ws.read(|h| h.text(&inode)).unwrap();
    drop(ws);
    let size =
        ["", "-wal"].iter().filter_map(|s| std::fs::metadata(format!("{}{s}", db.display())).ok()).map(|m| m.len()).sum::<u64>();
    println!("database size: {} MiB", size >> 20);
    let t = Instant::now();
    let ws = Workspace::open(&db, None).unwrap();
    println!("reopen: {:?}", t.elapsed());
    let t = Instant::now();
    let text = ws.read(|h| h.text(&inode)).unwrap();
    println!("first read after reopen (lazy blob): {:?}", t.elapsed());
    assert_eq!(text, expected);
}
