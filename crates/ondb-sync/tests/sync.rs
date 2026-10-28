use std::fs;
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ondb::{ActorKind, Mount, MountOptions, Workspace};
use ondb_core::{BatchHeader, Content, FileMode, InodeId, LineEnding, Op, Splice, Version};
use ondb_sync::transport::{TcpTransport, run_client, serve_tcp};
use ondb_sync::{Client, Message, RejectReason, Relay, RelayConfig, Replica, pump};

fn create(ws: &Workspace, name: &str, body: &str) {
    let actor = ws.actor("tester", ActorKind::Human).unwrap();
    ws.commit(actor, None, |t| {
        t.push(Op::CreateFile {
            parent: InodeId::ROOT,
            name: name.into(),
            mode: FileMode::Regular,
            line_ending: LineEnding::Lf,
            content: Content::Text(body.as_bytes().to_vec()),
        })?;
        Ok(())
    })
    .unwrap();
}

fn walk(ws: &Workspace) -> Vec<(String, Option<Vec<u8>>)> {
    ws.read(|h| h.walk().into_iter().map(|(p, i)| (p, h.text(&i))).collect())
}

#[test]
fn replicas_converge_through_relay() {
    let ws: Vec<Workspace> = {
        let first = Workspace::in_memory(None).unwrap();
        let id = first.id();
        vec![first, Workspace::in_memory(Some(id)).unwrap(), Workspace::in_memory(Some(id)).unwrap()]
    };
    let mut relay = Relay::in_memory(RelayConfig { validate: true, cutoff_after: Some(Duration::ZERO) });
    let mut clients: Vec<Client<Workspace>> = ws.iter().cloned().map(Client::new).collect();
    let mut initial = Vec::new();
    for (i, c) in clients.iter_mut().enumerate() {
        initial.extend(c.connect().unwrap().into_iter().map(|m| (i as u64, m)));
    }
    let mut refs: Vec<(u64, &mut Client<Workspace>)> = clients.iter_mut().enumerate().map(|(i, c)| (i as u64, c)).collect();
    pump(&mut relay, &mut refs, initial).unwrap();
    // Concurrent offline work from every replica, then one push each.
    for (i, w) in ws.iter().enumerate() {
        create(w, &format!("from-{i}.txt"), &format!("hello {i}\n"));
    }
    let mut initial = Vec::new();
    for (i, c) in refs.iter_mut() {
        initial.extend(c.poll().unwrap().into_iter().map(|m| (*i, m)));
    }
    pump(&mut relay, &mut refs, initial).unwrap();
    // Second round: concurrent edits of the same file from two replicas.
    let target = ws[0].read(|h| h.lookup("from-0.txt")).unwrap();
    for (i, w) in ws.iter().take(2).enumerate() {
        let actor = w.actor("tester", ActorKind::Human).unwrap();
        w.commit(actor, None, |t| {
            let text = format!("edit {i}\n");
            t.push(Op::EditText {
                inode: target,
                splices: vec![Splice { at: 0, del: 0, ins: text.len() as u64 }],
                text: text.into_bytes(),
            })?;
            Ok(())
        })
        .unwrap();
    }
    let mut initial = Vec::new();
    for (i, c) in refs.iter_mut() {
        initial.extend(c.poll().unwrap().into_iter().map(|m| (*i, m)));
    }
    pump(&mut relay, &mut refs, initial).unwrap();
    let reference = walk(&ws[0]);
    assert_eq!(reference.len(), 3);
    for w in &ws {
        assert_eq!(walk(w), reference);
        assert_eq!(w.heads(), ws[0].heads());
        assert!(w.unpushed().unwrap().is_empty());
    }
    let merged = String::from_utf8(reference[0].1.clone().unwrap()).unwrap();
    assert!(merged.contains("edit 0") && merged.contains("edit 1") && merged.ends_with("hello 0\n"), "{merged}");
    // Every peer has confirmed everything, so the cutoff caught up.
    assert_eq!(relay.cutoff(ws[0].id()), ws[0].heads());
}

#[test]
fn relay_refuses_batches_behind_cutoff_and_invalid_ops() {
    let a = Workspace::in_memory(None).unwrap();
    let mut relay = Relay::in_memory(RelayConfig { validate: true, cutoff_after: None });
    let mut client = Client::new(a.clone());
    create(&a, "x.txt", "x\n");
    let hello = client.connect().unwrap();
    pump(&mut relay, &mut [(1, &mut client)], hello.into_iter().map(|m| (1, m)).collect()).unwrap();
    let base = a.heads();

    // A batch whose op can't apply (deletes past the end of the file).
    let inode = a.read(|h| h.lookup("x.txt")).unwrap();
    let actor = ondb_core::ActorId::random();
    let start = a.read(|h| h.dag().max_ts()) + 1;
    let bad = ondb_core::Batch {
        header: BatchHeader { actor, start, end: start, parents: base.clone(), wall_ms: 0 },
        ops: vec![Op::EditText { inode, text: vec![], splices: vec![Splice { at: 0, del: 99, ins: 0 }] }],
        blobs: vec![],
    };
    let out = relay.handle(2, Message::Batches { history: a.id(), batches: vec![bad.clone()] });
    match &out[0].message {
        Message::Ack { rejected, .. } => assert!(matches!(rejected[0].reason, RejectReason::Invalid(_))),
        m => panic!("unexpected {m:?}"),
    }
    assert_eq!(relay.heads(a.id()), base, "invalid batch must not be admitted");

    // Advance the cutoff past `base`, then push work built on `base`.
    create(&a, "y.txt", "y\n");
    let push = client.poll().unwrap();
    pump(&mut relay, &mut [(1, &mut client)], push.into_iter().map(|m| (1, m)).collect()).unwrap();
    relay.set_cutoff(a.id(), a.heads());
    let stale_actor = ondb_core::ActorId::random();
    let start = a.read(|h| h.dag().max_ts()) + 1;
    let stale = ondb_core::Batch {
        header: BatchHeader { actor: stale_actor, start, end: start, parents: base, wall_ms: 0 },
        ops: vec![Op::Meta { key: "k".into(), value: None }],
        blobs: vec![],
    };
    let out = relay.handle(3, Message::Batches { history: a.id(), batches: vec![stale] });
    match &out[0].message {
        Message::Ack { rejected, .. } => assert_eq!(rejected[0].reason, RejectReason::BehindCutoff),
        m => panic!("unexpected {m:?}"),
    }
}

#[test]
fn late_joiner_and_out_of_order_delivery() {
    let a = Workspace::in_memory(None).unwrap();
    for i in 0..5 {
        create(&a, &format!("f{i}"), "x\n");
    }
    let b = Workspace::in_memory(Some(a.id())).unwrap();
    let mut batches = a.batches_missing_from(&Version::root()).unwrap();
    batches.reverse();
    let report = b.integrate(batches.split_off(2)).unwrap();
    assert!(report.applied.is_empty() || report.waiting.len() + report.applied.len() == 4);
    b.integrate(batches).unwrap();
    assert_eq!(walk(&a), walk(&b));
    assert_eq!(Replica::heads(&a), Replica::heads(&b));
}

/// Two directories on "two devices", each mounted and syncing over TCP
/// through a relay: edits from any process on one side appear on the other.
#[test]
fn tcp_relay_syncs_mounted_directories() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let relay = Arc::new(Mutex::new(Relay::in_memory(RelayConfig { validate: true, cutoff_after: None })));
    let stop = Arc::new(AtomicBool::new(false));
    let server = {
        let (relay, stop) = (relay.clone(), stop.clone());
        std::thread::spawn(move || serve_tcp(listener, relay, stop).unwrap())
    };

    let dir = tempfile::tempdir().unwrap();
    let (root_a, root_b) = (dir.path().join("a"), dir.path().join("b"));
    fs::create_dir_all(&root_a).unwrap();
    fs::create_dir_all(&root_b).unwrap();
    fs::write(root_a.join("hello.txt"), "from a\n").unwrap();
    let a = Workspace::open(dir.path().join("a.db"), None).unwrap();
    let b = Workspace::open(dir.path().join("b.db"), Some(a.id())).unwrap();
    let mount_a = Mount::start(&a, &root_a, MountOptions::default()).unwrap();
    let mount_b = Mount::start(&b, &root_b, MountOptions::default()).unwrap();

    let mut threads = Vec::new();
    for ws in [a.clone(), b.clone()] {
        let stop = stop.clone();
        threads.push(std::thread::spawn(move || {
            let mut transport = TcpTransport::connect(addr).unwrap();
            let changes = ws.subscribe();
            let mut client = Client::new(ws);
            run_client(&mut client, &mut transport, &changes, &stop).unwrap();
        }));
    }

    let wait_for = |path: &std::path::Path, want: &str| {
        let deadline = Instant::now() + Duration::from_secs(10);
        while fs::read_to_string(path).ok().as_deref() != Some(want) {
            assert!(Instant::now() < deadline, "{} never became {want:?}", path.display());
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    wait_for(&root_b.join("hello.txt"), "from a\n");
    std::process::Command::new("sh").arg("-c").arg("printf 'b wrote this\\n' > note.md").current_dir(&root_b).status().unwrap();
    wait_for(&root_a.join("note.md"), "b wrote this\n");
    fs::write(root_a.join("hello.txt"), "from a\nedited on a\n").unwrap();
    wait_for(&root_b.join("hello.txt"), "from a\nedited on a\n");
    mount_a.fence().unwrap();
    mount_b.fence().unwrap();

    stop.store(true, Ordering::Relaxed);
    for t in threads {
        t.join().unwrap();
    }
    server.join().unwrap();
    assert_eq!(walk(&a), walk(&b));
}
