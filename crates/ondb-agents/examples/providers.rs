//! Checks providers against their real CLIs.
//!
//! `cargo run --release -p ondb-agents --example providers` lists every
//! provider and its models; `... -- <provider> [model]` also runs one short
//! prompt in a scratch directory and prints the normalized events.

use ondb_agents::acp::Acp;
use ondb_agents::claude::{Access, ClaudeCode};
use ondb_agents::codex::Codex;
use ondb_agents::pi::Pi;
use ondb_agents::{EventKind, Provider, StartRequest};

fn main() {
    let a = Access::AcceptEdits;
    let all: Vec<Box<dyn Provider>> = vec![
        Box::new(ClaudeCode::new(a)),
        Box::new(Codex::new(a)),
        Box::new(Acp::devin(a)),
        Box::new(Acp::cursor(a)),
        Box::new(Acp::opencode(a)),
        Box::new(Acp::grok(a)),
        Box::new(Acp::hermes(a)),
        Box::new(Acp::antigravity(a)),
        Box::new(Pi::new()),
    ];
    let args: Vec<String> = std::env::args().skip(1).collect();
    for p in &all {
        if let Some(only) = args.first()
            && only != p.id()
        {
            continue;
        }
        if !p.available() {
            println!("{:<12} not installed", p.id());
            continue;
        }
        let t = std::time::Instant::now();
        match p.models() {
            Ok(m) => {
                let default = m.iter().find(|m| m.default).map(|m| m.id.as_str()).unwrap_or("-");
                let sample: Vec<&str> = m.iter().take(4).map(|m| m.id.as_str()).collect();
                println!("{:<12} {:>3} models in {:.1?}, default {default}: {sample:?}", p.id(), m.len(), t.elapsed());
            }
            Err(e) => println!("{:<12} models failed: {e}", p.id()),
        }
        if args.is_empty() {
            continue;
        }
        let dir = std::env::temp_dir().join(format!("ondb-try-{}", p.id()));
        std::fs::create_dir_all(&dir).unwrap();
        let req = StartRequest { cwd: dir, model: args.get(1).cloned(), ..Default::default() };
        let mut run = p.start(req).expect("start");
        run.send("Create a file named hello.txt containing the word hi, then reply with the single word done.").unwrap();
        while let Some(ev) = run.next() {
            match &ev.kind {
                EventKind::TextDelta { .. } | EventKind::ReasoningDelta { .. } => {}
                EventKind::Other { kind } if kind == "stderr" || kind.starts_with("_") || kind == "session/update" => {}
                k => println!("  {k:?}"),
            }
            if matches!(ev.kind, EventKind::TurnEnded { .. }) {
                break;
            }
        }
        run.close();
    }
}
