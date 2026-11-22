use std::time::{Duration, Instant};

use ondb::{Change, Client, LiveBuffer, OpenArgs, Options, TextEdit, Units};

struct Rng(u64);

impl Rng {
    fn n(&mut self, m: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        if m == 0 {
            0
        } else {
            self.0 % m
        }
    }
}

fn random_edits(r: &mut Rng, len: u64) -> Vec<TextEdit> {
    let words = ["a", "bc", "é", "😀", " ", "xyz", "\n"];
    let mut out = Vec::new();
    let mut at = 0;
    for _ in 0..r.n(3) + 1 {
        if at > len {
            break;
        }
        let pos = at + r.n(len - at + 1);
        let del = r.n((len - pos).min(3) + 1);
        let ins: String = (0..r.n(3)).map(|_| words[r.n(words.len() as u64) as usize]).collect();
        out.push(TextEdit { pos, del, ins });
        at = pos + del + 1;
    }
    out
}

fn surrogate_safe(text: &str, edits: &mut Vec<TextEdit>) {
    let units: Vec<u16> = text.encode_utf16().collect();
    let low = |p: u64| (p as usize) < units.len() && (0xDC00..0xE000).contains(&units[p as usize]);
    edits.retain(|e| !low(e.pos) && !low(e.pos + e.del));
}

fn drain(b: &mut LiveBuffer) -> usize {
    let mut n = 0;
    while let Some(c) = b.try_recv() {
        if let Change::Reopen = c {
            panic!("buffer needs reopening");
        }
        n += 1;
    }
    n
}

fn main() -> ondb::Result<()> {
    let home = std::env::var("ONDB_HOME").expect("ONDB_HOME");
    let rounds: u64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(200);
    let client = Client::connect_with(Options {
        socket: Some(std::path::Path::new(&home).join("run").join("daemon.sock")),
        ..Options::default()
    })?;
    let space = match client.space_list().wait()?.spaces.into_iter().find_map(|s| s.id) {
        Some(s) => s,
        None => client.space_create("buffers", None, None).wait()?.space.expect("space"),
    };
    let created: ondb::Created = client.call(&serde_json::json!({"op": "text.create", "space": space, "title": "notes", "initial": "hello wörld 😀\n"})).wait()?;
    let object = created.object.expect("object");
    let mut a = LiveBuffer::open(&client, &OpenArgs { object: object.clone(), units: Units::Utf16, actor: Some("aa".repeat(16)), ..OpenArgs::default() }).wait()?;
    let mut b = LiveBuffer::open(&client, &OpenArgs { object: object.clone(), units: Units::Utf16, actor: Some("bb".repeat(16)), ..OpenArgs::default() }).wait()?;
    println!("opened {} twice: A rev {} B rev {} text {:?}", object, a.rev(), b.rev(), a.text());
    let mut r = Rng(0x9e3779b97f4a7c15);
    let t0 = Instant::now();
    let mut sent = 0;
    for round in 0..rounds {
        for buf in [&a, &b] {
            if r.n(3) == 0 {
                continue;
            }
            let text = buf.text();
            let len = buf.len();
            let mut edits = random_edits(&mut r, len);
            surrogate_safe(&text, &mut edits);
            if buf.edit(&edits, round)?.is_some() {
                sent += 1;
            }
        }
        if r.n(4) == 0 {
            drain(&mut a);
            drain(&mut b);
        }
        if a.in_flight() > 16 && r.n(2) == 0 {
            a.flush_blocking()?;
        }
    }
    a.flush_blocking()?;
    b.flush_blocking()?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let server = loop {
        drain(&mut a);
        drain(&mut b);
        let s = a.server_text().wait()?;
        let settled = a.unacked() == 0 && b.unacked() == 0 && a.rev() == s.rev && b.rev() == s.rev;
        if settled || Instant::now() > deadline {
            break s;
        }
        if let Some(c) = a.blocking_recv_timeout(Duration::from_millis(100)) {
            let _ = c;
        }
    };
    let (ta, tb) = (a.text(), b.text());
    println!("{sent} pipelined edits from two actors in {:?}; server rev {}", t0.elapsed(), server.rev);
    println!("A == server: {}, B == server: {}, length {} units", ta == server.text, tb == server.text, a.len());
    if ta != server.text || tb != server.text {
        println!("A: {ta:?}\nB: {tb:?}\nS: {:?}", server.text);
        std::process::exit(1);
    }
    let half = a.len() / 2;
    let anchors = a.anchors(&[0, half], false).wait()?;
    let before = a.resolve(&anchors).wait()?;
    b.edit(&[TextEdit { pos: 0, del: 0, ins: "PREFIX ".into() }], 9999)?;
    b.flush_blocking()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while a.text() != b.text() && Instant::now() < deadline {
        a.blocking_recv_timeout(Duration::from_millis(200));
    }
    let after = a.resolve(&anchors).wait()?;
    println!("anchors {:?}: resolved {:?} before and {:?} after B inserted 7 units at 0", anchors.iter().map(|x| x.text()).collect::<Vec<_>>(), before, after);
    let undone = b.undo().wait()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while !a.text().starts_with("hello") && !a.text().is_empty() && a.text().starts_with("PREFIX") && Instant::now() < deadline {
        a.blocking_recv_timeout(Duration::from_millis(200));
    }
    println!("B undo -> {undone}; A now starts with PREFIX: {}", a.text().starts_with("PREFIX "));
    Ok(())
}
