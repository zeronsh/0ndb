use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use ondb::{Anchor, Autostart, Change, Client, LiveBuffer, OpenArgs, Options, Range, TextEdit, Units};
use serde_json::json;

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

fn rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("VmRSS:")).and_then(|l| l.split_whitespace().nth(1)?.parse().ok()))
        .unwrap_or(0)
}

fn ctx_switches(pid: u64) -> u64 {
    let mut total = 0;
    if let Ok(rd) = std::fs::read_dir(format!("/proc/{pid}/task")) {
        for t in rd.flatten() {
            if let Ok(s) = std::fs::read_to_string(t.path().join("status")) {
                for l in s.lines() {
                    if l.starts_with("voluntary_ctxt_switches:") || l.starts_with("nonvoluntary_ctxt_switches:") {
                        total += l.split_whitespace().nth(1).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
                    }
                }
            }
        }
    }
    total
}

fn pct(v: &mut [Duration], p: f64) -> Duration {
    if v.is_empty() {
        return Duration::ZERO;
    }
    v.sort();
    v[((v.len() as f64 - 1.0) * p).round() as usize]
}

fn gen_file(kind: &str, r: &mut Rng) -> String {
    let words = ["alpha", "βeta", "gamma", "😀", "naïve", "中文", "𝄞", "👩‍👩‍👧", "x", "fn", "{", "}", "→"];
    let nl = if kind == "crlf" { "\r\n" } else { "\n" };
    let target = if kind == "big" { 5 << 20 } else { 24 << 10 };
    let mut s = String::with_capacity(target + 64);
    let mut line = 0;
    while s.len() < target {
        s.push_str(&format!("{line:06} "));
        for _ in 0..r.n(10) + 2 {
            s.push_str(words[r.n(words.len() as u64) as usize]);
            s.push(' ');
        }
        s.push_str(nl);
        line += 1;
    }
    s
}

fn is_low(u: Option<u32>) -> bool {
    matches!(u, Some(x) if (0xDC00..0xE000).contains(&x))
}

fn in_marker(b: &LiveBuffer, pos: u64, del: u64) -> bool {
    b.with_state(|st| {
        let before = st.slice(pos.saturating_sub(24), pos);
        let open = |o: char, c: char| before.chars().rev().find(|x| *x == o || *x == c) == Some(o);
        let cut = st.slice(pos, pos + del);
        open('⟪', '⟫') || open('⟦', '⟧') || cut.chars().any(|c| matches!(c, '⟪' | '⟫' | '⟦' | '⟧'))
    })
}

fn pick_edit(b: &LiveBuffer, r: &mut Rng, crlf: bool, i: u64) -> Option<TextEdit> {
    let len = b.len();
    let mut pos = r.n(len + 1);
    let unit = |p: u64| b.with_state(|s| s.unit(p));
    while pos > 0 && (is_low(unit(pos)) || (crlf && unit(pos) == Some(10) && unit(pos - 1) == Some(13))) {
        pos -= 1;
    }
    let mut del = if r.n(3) == 0 { r.n(4).min(len - pos) } else { 0 };
    while del > 0 && (is_low(unit(pos + del)) || (crlf && unit(pos + del) == Some(10) && unit(pos + del - 1) == Some(13))) {
        del += 1;
        if pos + del > len {
            del = 0;
        }
    }
    if del > 0 && in_marker(b, pos, del) {
        del = 0;
    }
    if in_marker(b, pos, 0) {
        return None;
    }
    let ins = match r.n(10) {
        0 => "😀".to_string(),
        1 => "👩‍👩‍👧".to_string(),
        2 => if crlf { "\r\n".to_string() } else { "\n".to_string() },
        3 => "é".to_string(),
        4 => "𝄞x".to_string(),
        5 => "中".to_string(),
        6 if i % 3 == 0 => String::new(),
        _ => ["a", "b", " ", "ok"][r.n(4) as usize].to_string(),
    };
    if del == 0 && ins.is_empty() {
        return None;
    }
    Some(TextEdit { pos, del, ins })
}

struct Agent {
    stop: Arc<AtomicBool>,
    tree_writes: Arc<AtomicU64>,
    disk_writes: Arc<AtomicU64>,
    buffer_edits: Arc<AtomicU64>,
    handle: std::thread::JoinHandle<ondb::Result<()>>,
}

fn char_boundary(s: &str, mut at: usize) -> usize {
    while at > 0 && (!s.is_char_boundary(at) || (at < s.len() && s.as_bytes()[at] == b'\n' && s.as_bytes()[at - 1] == b'\r')) {
        at -= 1;
    }
    at
}

fn spawn_agent(sock: PathBuf, tree: String, path: String, disk: PathBuf, period: Duration, seed: u64) -> Agent {
    let stop = Arc::new(AtomicBool::new(false));
    let tree_writes = Arc::new(AtomicU64::new(0));
    let disk_writes = Arc::new(AtomicU64::new(0));
    let buffer_edits = Arc::new(AtomicU64::new(0));
    let (s2, tw, dw, be) = (stop.clone(), tree_writes.clone(), disk_writes.clone(), buffer_edits.clone());
    let handle = std::thread::spawn(move || -> ondb::Result<()> {
        let c = Client::connect_with(Options { socket: Some(sock), ..Options::default() })?;
        let mut ab = LiveBuffer::open(&c, &OpenArgs { object: tree.clone(), path: path.clone(), units: Units::Bytes, actor: Some("a9".repeat(16)), page: 1 << 30, ..OpenArgs::default() }).wait()?;
        let mut r = Rng(seed);
        let mut n = 0u64;
        let modes: Vec<u8> = std::env::var("AGENT_MODES").unwrap_or_else(|_| "tdbb".into()).into_bytes();
        while !s2.load(Ordering::Relaxed) {
            std::thread::sleep(period);
            while let Some(ch) = ab.try_recv() {
                if matches!(ch, Change::Reopen | Change::Closed(_)) {
                    return Err(ondb::Error::Protocol(format!("agent buffer {ch:?}")));
                }
            }
            n += 1;
            let tag = format!("⟦agent {n}⟧");
            match modes[r.n(modes.len() as u64) as usize] {
                b'n' => continue,
                b't' => {
                    let cur: serde_json::Value = c.call(&json!({"op": "tree.read", "object": tree, "path": path})).wait()?;
                    let text = cur["text"].as_str().unwrap_or("").to_string();
                    let at = char_boundary(&text, r.n(text.len() as u64 + 1) as usize);
                    let new = format!("{}{}{}", &text[..at], tag, &text[at..]);
                    let _: serde_json::Value = c.call(&json!({"op": "tree.write", "object": tree, "path": path, "text": new})).wait()?;
                    tw.fetch_add(1, Ordering::Relaxed);
                }
                b'd' => {
                    let text = std::fs::read_to_string(&disk).unwrap_or_default();
                    let at = char_boundary(&text, r.n(text.len() as u64 + 1) as usize);
                    let new = format!("{}{}{}", &text[..at], tag, &text[at..]);
                    let tmp = disk.with_extension("agent-tmp");
                    std::fs::write(&tmp, new)?;
                    std::fs::rename(&tmp, &disk)?;
                    dw.fetch_add(1, Ordering::Relaxed);
                }
                _ => {
                    let len = ab.len();
                    let text_at = |p: u64| ab.with_state(|s| s.unit(p));
                    let mut at = r.n(len + 1);
                    while at > 0 && matches!(text_at(at), Some(x) if (0x80..0xC0).contains(&x)) {
                        at -= 1;
                    }
                    if ab.edit(&[TextEdit { pos: at, del: 0, ins: tag }], n)?.is_some() {
                        be.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
        }
        ab.flush_blocking()?;
        Ok(())
    });
    Agent { stop, tree_writes, disk_writes, buffer_edits, handle }
}

fn drain(b: &mut LiveBuffer, deltas: &mut u64) {
    while let Some(c) = b.try_recv() {
        match c {
            Change::Delta { .. } => *deltas += 1,
            Change::Reopen | Change::Closed(_) => panic!("buffer {c:?}"),
            Change::Cursors(_) => {}
        }
    }
}

fn stamp(b: &LiveBuffer, sent: &[Instant], next: &mut u64, lat: &mut Vec<Duration>) {
    let acked = b.with_state(|s| s.acked_seq());
    let now = Instant::now();
    while *next <= acked {
        if let Some(t) = sent.get(*next as usize - 1) {
            lat.push(now - *t);
        }
        *next += 1;
    }
}

fn settle(client: &Client, b: &mut LiveBuffer, deltas: &mut u64, tree: &str, file: &str, disk: &Path) -> ondb::Result<(String, bool, bool, Duration)> {
    b.flush_blocking()?;
    let t = Instant::now();
    loop {
        drain(b, deltas);
        let s = b.server_text().wait()?;
        let tr: serde_json::Value = client.call(&json!({"op": "tree.read", "object": tree, "path": file})).wait()?;
        let tree_ok = tr["text"].as_str() == Some(s.text.as_str());
        let disk_ok = std::fs::read_to_string(disk).ok().as_deref() == Some(s.text.as_str());
        let settled = b.unacked() == 0 && b.rev() == s.rev && b.text() == s.text;
        if (settled && tree_ok && disk_ok) || t.elapsed() > Duration::from_secs(30) {
            return Ok((s.text, tree_ok, disk_ok, t.elapsed()));
        }
        if let Some(c) = b.blocking_recv_timeout(Duration::from_millis(20)) {
            if matches!(c, Change::Delta { .. }) {
                *deltas += 1;
            }
        }
    }
}

fn first_diff(a: &str, b: &str) -> String {
    let (x, y): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let i = x.iter().zip(y.iter()).position(|(p, q)| p != q).unwrap_or(x.len().min(y.len()));
    let w = |v: &Vec<char>| v[i.saturating_sub(20)..(i + 20).min(v.len())].iter().collect::<String>();
    format!("at char {i} (lens {} / {}): {:?} vs {:?}", x.len(), y.len(), w(&x), w(&y))
}

struct Report {
    file: String,
    edits: u64,
    lat_burst: Vec<Duration>,
    lat_typing: Vec<Duration>,
    ok: bool,
}

#[allow(clippy::too_many_arguments)]
fn session(client: &Client, sock: &Path, tree: &str, root: &Path, file: &str, edits: u64, period: Duration, seed: u64) -> ondb::Result<Report> {
    let crlf = file.starts_with("crlf");
    let disk = root.join(file);
    let t_open = Instant::now();
    let rss0 = rss_kb();
    let mut b = LiveBuffer::open(client, &OpenArgs { object: tree.into(), path: file.into(), units: Units::Utf16, page: 64 << 10, ..OpenArgs::default() }).wait()?;
    let first = t_open.elapsed();
    b.load_all_blocking(1 << 20)?;
    let loaded = t_open.elapsed();
    let disk_text = std::fs::read_to_string(&disk)?;
    println!(
        "[{file}] open {:?} (first page), fully loaded {:?}, {} utf16 units, client rss +{} KiB, matches disk {}",
        first,
        loaded,
        b.len(),
        rss_kb().saturating_sub(rss0),
        b.text() == disk_text
    );
    let agent = spawn_agent(sock.to_path_buf(), tree.into(), file.into(), disk.clone(), period, seed ^ 0xabcdef);
    let mut r = Rng(seed);
    let mut deltas = 0u64;
    let mut sent: Vec<Instant> = Vec::new();
    let mut next_ack = 1u64;
    let mut lat_burst = Vec::new();
    let mut lat_typing = Vec::new();
    let mut anchors: Vec<(Anchor, String)> = Vec::new();
    let mut undos = (0, 0);
    let mut cursor_calls = 0;
    let t0 = Instant::now();
    let mut i = 0u64;
    let mut max_inflight = 0;
    let mut apply_time = Duration::ZERO;
    while i < edits {
        drain(&mut b, &mut deltas);
        stamp(&b, &sent, &mut next_ack, &mut lat_burst);
        let typing = i >= edits * 3 / 4;
        if i % 97 == 0 {
            let k = format!("⟪M{i}⟫");
            let pos = loop {
                let p = r.n(b.len() + 1);
                if !is_low(b.with_state(|s| s.unit(p))) && !in_marker(&b, p, 0) && !(crlf && b.with_state(|s| s.unit(p)) == Some(10)) {
                    break p;
                }
            };
            if b.edit(&[TextEdit { pos, del: 0, ins: k.clone() }], i)?.is_some() {
                sent.push(Instant::now());
            }
            let a = b.anchors(&[pos], false).wait()?;
            let back = b.resolve(&a).wait()?;
            if back[0] != pos as i64 {
                let now = b.with_state(|s| s.slice(back[0].max(0) as u64, back[0].max(0) as u64 + 8));
                if !now.starts_with("⟪M") {
                    let (rev, un, ack, sent) = b.with_state(|s| (s.rev(), s.unacked(), s.acked_seq(), s.sent()));
                    let srv = b.server_text().wait()?;
                    let su: Vec<u16> = srv.text.encode_utf16().collect();
                    let near = |v: &[u16], at: usize| String::from_utf16_lossy(&v[at.saturating_sub(8).min(v.len())..(at + 14).min(v.len())]);
                    let back2 = b.resolve(&a).wait()?;
                    println!(
                        "[{file}] anchor {} for {k} at {pos} resolved to {} then {:?} ({now:?}); client rev {rev} unacked {un} ack {ack} sent {sent}; engine rev {} near {:?}; client near {:?}",
                        a[0].text(),
                        back[0],
                        back2,
                        srv.rev,
                        near(&su, pos as usize),
                        b.with_state(|s| s.slice(pos.saturating_sub(8), pos + 14))
                    );
                }
            }
            anchors.push((a[0].clone(), k));
            i += 1;
            continue;
        }
        if i % 151 == 0 && i > 0 && std::env::var("NO_UNDO").is_err() {
            stamp(&b, &sent, &mut next_ack, &mut lat_burst);
            let before = b.len();
            let u = b.undo().wait()?;
            undos.0 += u as u64;
            let rd = b.redo().wait()?;
            undos.1 += rd as u64;
            let _ = before;
        }
        if i % 40 == 0 {
            let len = b.len() as i64;
            let a = (r.n(len as u64 + 1)) as i64;
            b.set_cursors(&[Range { anchor: a, head: a }, Range { anchor: 0, head: len.min(5) }]).wait()?;
            cursor_calls += 1;
        }
        let mut list = Vec::new();
        if let Some(e) = pick_edit(&b, &mut r, crlf, i) {
            list.push(e);
        }
        if r.n(5) == 0 {
            if let Some(e2) = pick_edit(&b, &mut r, crlf, i + 1) {
                if let Some(e1) = list.first() {
                    if e2.pos > e1.pos + e1.del + 1 {
                        list.push(e2);
                    } else if e2.pos + e2.del + 1 < e1.pos {
                        list.insert(0, e2);
                    }
                }
            }
        }
        if list.is_empty() {
            continue;
        }
        let ta = Instant::now();
        let seq = b.edit(&list, i)?;
        apply_time += ta.elapsed();
        if seq.is_some() {
            sent.push(Instant::now());
            i += 1;
        }
        max_inflight = max_inflight.max(b.unacked());
        if typing {
            let target = sent.len() as u64;
            let t = Instant::now();
            while b.with_state(|s| s.acked_seq()) < target && t.elapsed() < Duration::from_millis(500) {
                drain(&mut b, &mut deltas);
                std::hint::spin_loop();
            }
            let acked = b.with_state(|s| s.acked_seq());
            let now = Instant::now();
            while next_ack <= acked {
                let d = now - sent[next_ack as usize - 1];
                if next_ack == target {
                    lat_typing.push(d);
                } else {
                    lat_burst.push(d);
                }
                next_ack += 1;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    let typed = t0.elapsed();
    agent.stop.store(true, Ordering::Relaxed);
    let agent_res = agent.handle.join().expect("agent thread");
    agent_res?;
    let (server, tree_ok, disk_ok, disk_wait) = settle(client, &mut b, &mut deltas, tree, file, &disk)?;
    stamp(&b, &sent, &mut next_ack, &mut lat_burst);
    let client_text = b.text();
    let engine_ok = client_text == server;
    let mut anchor_ok = 0;
    let mut anchor_gone = 0;
    let resolved = b.resolve(&anchors.iter().map(|a| a.0.clone()).collect::<Vec<_>>()).wait()?;
    for ((_, k), p) in anchors.iter().zip(resolved.iter()) {
        let at = b.with_state(|s| s.slice(*p as u64, *p as u64 + k.encode_utf16().count() as u64));
        if &at == k {
            anchor_ok += 1;
        } else if !client_text.contains(k.as_str()) {
            anchor_gone += 1;
        } else {
            println!("[{file}] anchor {k} resolved to {p}, text there {at:?}");
        }
    }
    let agent_tags = client_text.matches("⟦agent").count();
    let agent_total = agent.tree_writes.load(Ordering::Relaxed) + agent.disk_writes.load(Ordering::Relaxed) + agent.buffer_edits.load(Ordering::Relaxed);
    println!(
        "[{file}] {edits} edits in {:?} (max {} unacked, client apply total {:?}), {} deltas in; agent: {} tree.write, {} disk writes, {} buffer edits, {} of {} tags present",
        typed,
        max_inflight,
        apply_time,
        deltas,
        agent.tree_writes.load(Ordering::Relaxed),
        agent.disk_writes.load(Ordering::Relaxed),
        agent.buffer_edits.load(Ordering::Relaxed),
        agent_tags,
        agent_total
    );
    println!(
        "[{file}] undo {} / redo {} done, {} cursor sets, anchors {} exact / {} gone (of {}); client == engine {}, == tree.read {}, == disk {} (settled in {:?}); final {} units",
        undos.0,
        undos.1,
        cursor_calls,
        anchor_ok,
        anchor_gone,
        anchors.len(),
        engine_ok,
        tree_ok,
        disk_ok,
        disk_wait,
        b.len()
    );
    if !engine_ok {
        println!("[{file}] client vs engine {}", first_diff(&client_text, &server));
    }
    if !disk_ok {
        let d = std::fs::read_to_string(&disk).unwrap_or_default();
        println!("[{file}] disk vs engine {}", first_diff(&d, &server));
    }
    Ok(Report { file: file.into(), edits, lat_burst, lat_typing, ok: engine_ok && tree_ok && disk_ok })
}

fn apply_units(doc: &mut Vec<u16>, ops: &[ondb::Op]) {
    let mut at = 0usize;
    for o in ops {
        match o {
            ondb::Op::Retain(n) => at += *n as usize,
            ondb::Op::Delete(n) => {
                doc.drain(at..at + *n as usize);
            }
            ondb::Op::Insert(t) => {
                let u: Vec<u16> = t.encode_utf16().collect();
                let k = u.len();
                doc.splice(at..at, u);
                at += k;
            }
        }
    }
}

fn own_text_check(client: &Client, sock: &Path, tree: &str, root: &Path, file: &str, edits: u64) -> ondb::Result<bool> {
    let mut b = LiveBuffer::open(client, &OpenArgs { object: tree.into(), path: file.into(), units: Units::Utf16, page: 1 << 30, own_text: true, ..OpenArgs::default() }).wait()?;
    let mut app: Vec<u16> = b.take_page().unwrap_or_default().encode_utf16().collect();
    assert_eq!(app.len() as u64, b.len());
    let rss0 = rss_kb();
    let agent = spawn_agent(sock.to_path_buf(), tree.into(), file.into(), root.join(file), Duration::from_millis(20), 77);
    let mut r = Rng(0x51ed270b);
    let t0 = Instant::now();
    let mut n = 0;
    while n < edits {
        while let Some(c) = b.try_recv() {
            match c {
                Change::Delta { ops, .. } => apply_units(&mut app, &ops),
                Change::Reopen | Change::Closed(_) => panic!("own_text buffer {c:?}"),
                Change::Cursors(_) => {}
            }
        }
        let mut pos = r.n(app.len() as u64 + 1) as usize;
        while pos > 0 && pos < app.len() && (0xDC00..0xE000).contains(&app[pos]) {
            pos -= 1;
        }
        let ins = ["a", "😀", "é", "\n"][r.n(4) as usize].to_string();
        let e = TextEdit { pos: pos as u64, del: 0, ins: ins.clone() };
        if b.edit(&[e], n)?.is_some() {
            let u: Vec<u16> = ins.encode_utf16().collect();
            app.splice(pos..pos, u);
            n += 1;
        }
    }
    agent.stop.store(true, Ordering::Relaxed);
    agent.handle.join().expect("agent")?;
    b.flush_blocking()?;
    let deadline = Instant::now() + Duration::from_secs(30);
    let ok = loop {
        while let Some(c) = b.try_recv() {
            if let Change::Delta { ops, .. } = c {
                apply_units(&mut app, &ops);
            }
        }
        let s = b.server_text().wait()?;
        let same = b.unacked() == 0 && b.rev() == s.rev && String::from_utf16_lossy(&app) == s.text && b.len() == app.len() as u64;
        if same || Instant::now() > deadline {
            break same;
        }
        if let Some(Change::Delta { ops, .. }) = b.blocking_recv_timeout(Duration::from_millis(20)) {
            apply_units(&mut app, &ops);
        }
    };
    println!(
        "[{file}] own_text: {edits} edits in {:?} with the app keeping its own UTF-16 text; process rss +{} KiB; app text == engine {ok}",
        t0.elapsed(),
        rss_kb().saturating_sub(rss0)
    );
    Ok(ok)
}

fn main() -> ondb::Result<()> {
    let home = PathBuf::from(std::env::args().nth(1).expect("ONDB_HOME arg"));
    let exe = std::env::args().nth(2).unwrap_or_else(|| "0ndb".into());
    let edits: u64 = std::env::var("EDITS").ok().and_then(|s| s.parse().ok()).unwrap_or(1200);
    let only = std::env::var("ONLY").ok();
    std::fs::create_dir_all(&home)?;
    let sock = home.join("run").join("daemon.sock");
    let client = Client::connect_with(Options {
        socket: Some(sock.clone()),
        autostart: Some(Autostart::new(&exe).env("ONDB_HOME", home.to_string_lossy()).arg("--no-runner")),
        ..Options::default()
    })?;
    let st = client.daemon_status().wait()?;
    println!("daemon {} pid {} rss {} KiB", st.version, st.pid, st.rss / 1024);
    let space = client.space_create("e2e", None, None).wait()?.space.expect("space");
    let created: ondb::Created = client.call(&json!({"op": "tree.create", "space": space, "title": "work"})).wait()?;
    let tree = created.object.expect("tree");
    let root = home.join("work");
    std::fs::create_dir_all(&root)?;
    let mut r = Rng(0x2545F4914F6CDD1D);
    let files = [("emoji.txt", "lf"), ("crlf.txt", "crlf"), ("big.txt", "big")];
    for (name, kind) in files {
        std::fs::write(root.join(name), gen_file(kind, &mut r))?;
    }
    for i in 0..100 {
        std::fs::write(root.join(format!("small{i}.txt")), format!("small file {i} 😀\r\nline two\n"))?;
    }
    let t = Instant::now();
    client.mount_add(&tree, &root.to_string_lossy()).wait()?;
    for (name, _) in files {
        let want = std::fs::read_to_string(root.join(name))?;
        loop {
            let v: Result<serde_json::Value, _> = client.call(&json!({"op": "tree.read", "object": tree, "path": name})).wait();
            if v.ok().and_then(|v| v["text"].as_str().map(|s| s == want)).unwrap_or(false) {
                break;
            }
            if t.elapsed() > Duration::from_secs(120) {
                return Err(ondb::Error::Protocol(format!("{name} never ingested")));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    println!("mounted {} and ingested {} files (5 MiB big.txt) in {:?}", root.display(), files.len() + 100, t.elapsed());

    let st0 = client.daemon_status().wait()?;
    let mut opened = Vec::new();
    for i in 0..100 {
        opened.push(LiveBuffer::open(&client, &OpenArgs { object: tree.clone(), path: format!("small{i}.txt"), units: Units::Utf16, ..OpenArgs::default() }).wait()?);
    }
    let st1 = client.daemon_status().wait()?;
    let rss_c0 = rss_kb();
    let big = LiveBuffer::open(&client, &OpenArgs { object: tree.clone(), path: "big.txt".into(), units: Units::Utf16, page: 64 << 10, ..OpenArgs::default() }).wait()?;
    big.load_all_blocking(1 << 20)?;
    let rss_c1 = rss_kb();
    let st2 = client.daemon_status().wait()?;
    big.edit(&[TextEdit { pos: 0, del: 0, ins: "x".into() }], 0)?;
    big.flush_blocking()?;
    std::thread::sleep(Duration::from_millis(300));
    let st3 = client.daemon_status().wait()?;
    println!(
        "fresh daemon rss {} KiB; +{} B per open small buffer (100 opened); one 5 MiB buffer: +{} KiB opened, +{} KiB after its first edit; client mirror of it +{} KiB",
        st0.rss / 1024,
        (st1.rss - st0.rss) / 100,
        (st2.rss - st1.rss) / 1024,
        (st3.rss - st2.rss) / 1024,
        rss_c1.saturating_sub(rss_c0)
    );
    drop(big);

    let mut reports = Vec::new();
    for (k, (name, _)) in files.iter().enumerate() {
        if only.as_deref().is_some_and(|o| o != *name) {
            continue;
        }
        let ms: u64 = std::env::var("AGENT_MS").ok().and_then(|s| s.parse().ok()).unwrap_or(if *name == "big.txt" { 15 } else { 4 });
        let period = Duration::from_millis(ms);
        reports.push(session(&client, &sock, &tree, &root, name, edits, period, 0x9e3779b97f4a7c15 ^ k as u64)?);
    }
    let own_ok = if only.is_none() || only.as_deref() == Some("big.txt") { own_text_check(&client, &sock, &tree, &root, "big.txt", edits)? } else { true };
    let big = LiveBuffer::open(&client, &OpenArgs { object: tree.clone(), path: "big.txt".into(), units: Units::Utf16, page: 64 << 10, ..OpenArgs::default() }).wait()?;
    std::thread::sleep(Duration::from_secs(3));

    let w0 = client.daemon_status().wait()?;
    let w1 = client.daemon_status().wait()?;
    let per_call = w1.wakeups - w0.wakeups;
    let c0 = ctx_switches(w1.pid);
    let idle = Duration::from_secs(std::env::var("IDLE_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(10));
    std::thread::sleep(idle);
    let c1 = ctx_switches(w1.pid);
    let w2 = client.daemon_status().wait()?;
    println!(
        "idle {:?} with {} buffers open: {} daemon wakeups (minus {} per status call), {} context switches over all daemon threads, timeout_ms {}",
        idle,
        opened.len() + 1 + reports.len(),
        w2.wakeups - w1.wakeups - per_call,
        per_call,
        c1 - c0,
        w2.timeout_ms
    );

    let mut all_ok = own_ok;
    for rep in reports.iter_mut() {
        let (b50, b99) = (pct(&mut rep.lat_burst, 0.5), pct(&mut rep.lat_burst, 0.99));
        let (t50, t99) = (pct(&mut rep.lat_typing, 0.5), pct(&mut rep.lat_typing, 0.99));
        println!(
            "RESULT {} edits {} ok {} | pipelined edit->ack p50 {:?} p99 {:?} (n={}) | typing edit->ack p50 {:?} p99 {:?} (n={})",
            rep.file,
            rep.edits,
            rep.ok,
            b50,
            b99,
            rep.lat_burst.len(),
            t50,
            t99,
            rep.lat_typing.len()
        );
        all_ok &= rep.ok;
    }
    drop(opened);
    drop(big);
    if std::env::var("KEEP").is_err() {
        let _ = client.daemon_stop().wait();
    }
    if !all_ok {
        std::process::exit(1);
    }
    Ok(())
}
