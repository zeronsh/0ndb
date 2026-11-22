use ondb::{Autostart, Change, Client, LiveBuffer, OpenArgs, Options, TextEdit, Units};
use serde_json::json;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn main() -> ondb::Result<()> {
    let exe = std::env::var("RC_BIN").expect("RC_BIN");
    let home = PathBuf::from(std::env::var("RC_HOME").expect("RC_HOME"));
    let edits: usize = std::env::var("RC_EDITS").ok().and_then(|s| s.parse().ok()).unwrap_or(12);
    std::fs::create_dir_all(&home)?;
    let client = Client::connect_with(Options {
        socket: Some(home.join("run").join("daemon.sock")),
        autostart: Some(Autostart::new(&exe).env("ONDB_HOME", home.to_string_lossy())),
        ..Options::default()
    })?;
    let space = client.space_create("rc", None, None).wait()?.space.expect("space");
    let tree = client.tree_create(&space, "work").wait()?.object.expect("tree");
    let root = home.join("work");
    std::fs::create_dir_all(&root)?;
    let mut body = String::new();
    for k in 1..=3000 {
        body.push_str(&format!("line {k} filler text that makes the file large enough for a slow agent rewrite window ok\n"));
    }
    std::fs::write(root.join("notes.txt"), &body)?;
    client.mount_add(&tree, &root.to_string_lossy()).wait()?;
    let t = Instant::now();
    loop {
        if client.tree_read(&tree, "notes.txt").wait().map(|x| x.text == body).unwrap_or(false) {
            break;
        }
        if t.elapsed() > Duration::from_secs(60) {
            panic!("never ingested");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    eprintln!("step ingested");
    let convo = client.convo_create(&space, "edit", Some("claude"), Some("haiku")).wait()?.object.expect("convo");
    client.convo_mount(&convo, "work", &tree, &root.to_string_lossy()).wait()?;
    eprintln!("step mounted");
    let mut b = LiveBuffer::open(&client, &OpenArgs { object: tree.clone(), path: "notes.txt".into(), units: Units::Bytes, page: 1 << 30, ..OpenArgs::default() }).wait()?;
    eprintln!("step buffer");
    let path = root.join("notes.txt");
    let prompt = format!(
        "Use the Edit tool on {} exactly {} times, one Edit call per turn step: for k = 1..{}, replace the text `line k filler` with `EDITED k` (k is the number). If an Edit fails because the file was modified, Read the file again and retry that same edit. Do not use any other tool to change the file, and do not stop until all {} edits succeeded.",
        path.display(), edits, edits, edits
    );
    client.send(&convo, &prompt).wait()?;
    eprintln!("step sent");
    let start = Instant::now();
    let mut typed: Vec<String> = Vec::new();
    let mut pending: Vec<(u64, String)> = Vec::new();
    let mut acked: Vec<String> = Vec::new();
    let mut i = 0u64;
    let mut seen_running = false;
    let mut reopens = 0;
    loop {
        let a = b.with_state(|st| st.acked_seq());
        pending.retain(|(q, t)| if *q <= a { acked.push(t.clone()); false } else { true });
        while let Some(c) = b.try_recv() {
            if matches!(c, Change::Reopen | Change::Closed(_)) {
                pending.clear();
                reopens += 1;
                eprintln!("buffer change {c:?}");
                b = LiveBuffer::open(&client, &OpenArgs { object: tree.clone(), path: "notes.txt".into(), units: Units::Bytes, page: 1 << 30, ..OpenArgs::default() }).wait()?;
            }
        }
        let phase = start.elapsed().as_millis() % 1000;
        if phase < 400 {
            let tok = format!("T{i}");
            i += 1;
            let at = b.len();
            if b.edit(&[TextEdit { pos: at, del: 0, ins: format!("{tok}\n") }], 0).is_ok() {
                typed.push(tok);
            }
        }
        if i % 20 == 0 {
            let st = match client.convo_status(&convo).wait() {
                Ok(s) => s,
                Err(e) => { eprintln!("convo_status: {e:?}"); std::thread::sleep(Duration::from_millis(5)); continue; }
            };
            if st.status == "running" {
                seen_running = true;
            }
            if seen_running && st.status == "idle" {
                break;
            }
            if start.elapsed() > Duration::from_secs(600) {
                println!("timeout waiting for the agent");
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    if let Err(e) = b.flush_blocking() { eprintln!("flush: {e:?}"); }
    let a = b.with_state(|st| st.acked_seq());
    pending.retain(|(q, t)| if *q <= a { acked.push(t.clone()); false } else { true });
    std::thread::sleep(Duration::from_secs(3));
    let fin = client.tree_read(&tree, "notes.txt").wait()?.text;
    let disk = std::fs::read_to_string(&path).unwrap_or_default();
    let lost: Vec<&String> = typed.iter().filter(|t| !fin.contains(&format!("{t}\n"))).collect();
    let reverted: Vec<&String> = acked.iter().filter(|t| !fin.contains(&format!("{t}
"))).collect();
    println!("acked tokens {}, acked but missing (reverted) {} {:?}", acked.len(), reverted.len(), reverted.iter().take(10).collect::<Vec<_>>());
    let done = (1..=edits).filter(|k| fin.contains(&format!("EDITED {k} "))).count();
    let st: serde_json::Value = client.call(&json!({"op": "stats"})).wait()?;
    println!(
        "agent took {:?}; typed {} tokens, lost {} {:?}; agent edits present {}/{}; tree == disk: {}; reopens {}",
        start.elapsed(), typed.len(), lost.len(), lost.iter().take(10).collect::<Vec<_>>(), done, edits, fin == disk, reopens
    );
    println!("base stats: merged={} current={} mismatch={} not_text={}", st["base_merged"], st["base_current"], st["base_mismatch"], st["base_not_text"]);
    let _ = client.daemon_stop().wait();
    Ok(())
}
