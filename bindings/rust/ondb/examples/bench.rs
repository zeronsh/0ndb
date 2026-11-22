use std::time::{Duration, Instant};

use ondb::{Client, Options, SubItem};

fn ctx_switches(pid: &str, only: Option<&str>) -> Option<u64> {
    let mut total = 0;
    for t in std::fs::read_dir(format!("/proc/{pid}/task")).ok()? {
        let t = t.ok()?.path();
        if let Some(name) = only {
            if std::fs::read_to_string(t.join("comm")).ok()?.trim() != name {
                continue;
            }
        }
        for line in std::fs::read_to_string(t.join("status")).ok()?.lines() {
            if line.starts_with("voluntary_ctxt_switches") || line.starts_with("nonvoluntary_ctxt_switches") {
                total += line.split_whitespace().last()?.parse::<u64>().ok()?;
            }
        }
    }
    Some(total)
}

fn pct(v: &mut [Duration], p: f64) -> Duration {
    v.sort();
    v[((v.len() as f64 - 1.0) * p) as usize]
}

fn connect() -> ondb::Result<Client> {
    let home = std::env::var("ONDB_HOME").expect("set ONDB_HOME");
    Client::connect_with(Options {
        socket: Some(std::path::Path::new(&home).join("run").join("daemon.sock")),
        ..Options::default()
    })
}

fn latency(c: &Client) -> ondb::Result<()> {
    for _ in 0..200 {
        c.identity().wait()?;
    }
    let mut v = Vec::new();
    for _ in 0..5000 {
        let t = Instant::now();
        c.identity().wait()?;
        v.push(t.elapsed());
    }
    let mean = v.iter().sum::<Duration>() / v.len() as u32;
    println!("json identity round trip: mean {:?} p50 {:?} p99 {:?} max {:?}", mean, pct(&mut v, 0.5), pct(&mut v, 0.99), pct(&mut v, 1.0));
    let mut v = Vec::new();
    for _ in 0..5000 {
        let t = Instant::now();
        let r = c.call_raw(&[1, 1], false, 0).wait()?;
        assert_eq!(r.status, ondb::Status::OK);
        v.push(t.elapsed());
    }
    println!("binary identity round trip: p50 {:?} p99 {:?}", pct(&mut v, 0.5), pct(&mut v, 0.99));
    let space = c.space_list().wait()?.spaces.into_iter().find_map(|s| s.id).expect("a space");
    let rows = c.catalog_list(&space, false, None, 50).wait()?.rows;
    if let Some(r) = rows.first() {
        let ob = r.object.clone().unwrap_or_default();
        let mut v = Vec::new();
        for _ in 0..2000 {
            let t = Instant::now();
            c.convo_page(&ob, &ondb::PageArgs { limit: 20, ..Default::default() }).wait()?;
            v.push(t.elapsed());
        }
        println!("convo.page (20 messages) round trip: p50 {:?} p99 {:?}", pct(&mut v, 0.5), pct(&mut v, 0.99));
        let mut v = Vec::new();
        for _ in 0..2000 {
            let t = Instant::now();
            c.convo_status(&ob).wait()?;
            v.push(t.elapsed());
        }
        println!("convo.status round trip: p50 {:?} p99 {:?}", pct(&mut v, 0.5), pct(&mut v, 0.99));
    }
    let t = Instant::now();
    let pending: Vec<_> = (0..10000).map(|_| c.identity()).collect();
    for p in pending {
        p.wait()?;
    }
    let e = t.elapsed();
    println!("pipelined: 10000 calls in {:?} ({:.0} calls/s)", e, 10000.0 / e.as_secs_f64());
    Ok(())
}

fn idle(c: &Client, secs: u64) -> ondb::Result<()> {
    let st = c.daemon_status().wait()?;
    let space = c.space_list().wait()?.spaces.into_iter().find_map(|s| s.id).expect("a space");
    let rows = c.catalog_list(&space, false, None, 50).wait()?.rows;
    let ob = rows.first().and_then(|r| r.object.clone()).expect("a conversation");
    let _cat = c.subscribe_catalog(&space).wait()?;
    let _conv = c.subscribe_conversation(&ob).wait()?;
    let _ev = c.events()?;
    let _states = c.connection_states();
    c.convo_status(&ob).wait()?;
    std::thread::sleep(Duration::from_secs(3));
    let pid = st.pid.to_string();
    let d0 = ctx_switches(&pid, None);
    let r0 = ctx_switches("self", Some("ondb-reader"));
    let s0 = c.stats();
    std::thread::sleep(Duration::from_secs(secs));
    let d1 = ctx_switches(&pid, None);
    let r1 = ctx_switches("self", Some("ondb-reader"));
    let s1 = c.stats();
    let after = c.daemon_status().wait()?;
    println!(
        "idle {secs}s with catalog + conversation subscriptions, events and presence: daemon context switches {:?}, client reader context switches {:?}, client socket reads {}, bytes {}, daemon wakeups {} -> {}, daemon armed-timer timeout {} ms (-1 = none)",
        d1.zip(d0).map(|(a, b)| a - b),
        r1.zip(r0).map(|(a, b)| a - b),
        s1.socket_reads - s0.socket_reads,
        s1.bytes_received - s0.bytes_received,
        st.wakeups,
        after.wakeups,
        after.timeout_ms
    );
    Ok(())
}

fn stream(c: &Client, provider: &str, model: &str, prompt: &str) -> ondb::Result<()> {
    let space = c.space_list().wait()?.spaces.into_iter().find_map(|s| s.id).expect("a space");
    let ob = c.convo_create(&space, "stream bench", Some(provider), Some(model)).wait()?.object.expect("object");
    let mut sub = c.subscribe_conversation(&ob).wait()?;
    let _cat = c.subscribe_catalog(&space).wait()?;
    let _ev = c.events()?;
    let pid = c.daemon_status().wait()?.pid.to_string();
    let s0 = c.stats();
    let r0 = ctx_switches("self", Some("ondb-reader"));
    let d0 = ctx_switches(&pid, None);
    let sent = c.send(&ob, prompt).wait()?;
    let t0 = Instant::now();
    let (mut first, mut frames, mut chunks, mut text_bytes, mut out_tokens) = (None, 0u64, 0u64, 0u64, 0u64);
    let deadline = Instant::now() + Duration::from_secs(300);
    'outer: while Instant::now() < deadline {
        match sub.blocking_recv_timeout(Duration::from_secs(120)) {
            Some(SubItem::Deltas(ds)) => {
                frames += 1;
                for d in ds {
                    if d.kind == "chunk" || d.kind == "block" {
                        if d.kind == "chunk" {
                            first.get_or_insert_with(|| t0.elapsed());
                        }
                        chunks += 1;
                        text_bytes += d.text.len() as u64;
                    }
                    if d.kind == "seal" && d.msg != sent.item && d.role != "user" && d.usage.output > 0 {
                        out_tokens = d.usage.output;
                        break 'outer;
                    }
                }
            }
            Some(SubItem::Gap(g)) => println!("gap {g:?}"),
            Some(_) => {}
            None => break,
        }
    }
    let e = t0.elapsed();
    let s1 = c.stats();
    let r1 = ctx_switches("self", Some("ondb-reader"));
    let d1 = ctx_switches(&pid, None);
    let reads = s1.socket_reads - s0.socket_reads;
    let bytes = s1.bytes_received - s0.bytes_received;
    println!(
        "stream {provider}/{model}: {:?} total, first text after {:?}, {out_tokens} output tokens, {frames} conversation frames, {chunks} chunk/block deltas, {text_bytes} text bytes; client socket reads {reads} ({:.1}/s), reader context switches {:?}, daemon context switches {:?}; {bytes} bytes received = {:.1} bytes per output token ({:.2}x the text)",
        e,
        first,
        reads as f64 / e.as_secs_f64(),
        r1.zip(r0).map(|(a, b)| a - b),
        d1.zip(d0).map(|(a, b)| a - b),
        bytes as f64 / out_tokens.max(1) as f64,
        bytes as f64 / text_bytes.max(1) as f64
    );
    Ok(())
}

fn main() -> ondb::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let c = connect()?;
    match args.get(1).map(String::as_str) {
        Some("idle") => idle(&c, args.get(2).and_then(|s| s.parse().ok()).unwrap_or(60)),
        Some("stream") => stream(&c, &args[2], &args[3], &args[4]),
        _ => latency(&c),
    }
}
