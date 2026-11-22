mod common;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use common::{arg_or_env, DirStore, TestPasskey};
use ondb::{Autostart, Client, Dir, HostBuilder, Options, PageArgs, RecordArgs, SubItem};

fn main() -> ondb::Result<()> {
    let home = PathBuf::from(arg_or_env(1, "ONDB_HOME", &std::env::temp_dir().join("ondb-quickstart").to_string_lossy()));
    let exe = arg_or_env(2, "ONDB_BIN", "0ndb");
    let store_dir = PathBuf::from(arg_or_env(3, "ONDB_ACCOUNT_STORE", &home.with_extension("account-store").to_string_lossy()));
    std::fs::create_dir_all(&home)?;
    std::fs::create_dir_all(&store_dir)?;
    let sock = home.join("run").join("daemon.sock");
    let started = Instant::now();
    let client = Client::connect_with(Options {
        socket: Some(sock.clone()),
        autostart: Some(
            Autostart::new(&exe)
                .env("ONDB_HOME", home.to_string_lossy())
                .arg("--host-plugs")
                .arg("sealed_store,unlock")
                .arg("--no-runner"),
        ),
        ..Options::default()
    })?;
    let st = client.daemon_status().wait()?;
    println!("daemon {} pid {} ready in {:?}, host plugs {:?}", st.version, st.pid, started.elapsed(), st.host_plugs);

    let host = HostBuilder::new()
        .socket(&sock)
        .sealed_store(DirStore { dir: store_dir.clone() })
        .unlock(TestPasskey { path: home.join("test-passkey") })
        .spawn()?;
    println!("host registered for {:?}", host.wait_registered(Duration::from_secs(10))?);

    let subject = std::env::var("ONDB_SUBJECT").unwrap_or_else(|_| "quickstart@example.com".into());
    let relay = std::env::var("ONDB_RELAY").ok();
    let relay_key = std::env::var("ONDB_RELAY_KEY").ok();
    let account = client.account_state().wait()?;
    if !account.signed_in {
        let t = Instant::now();
        let login = client.account_login(&subject, "quickstart", relay.as_deref(), relay_key.as_deref()).wait()?;
        println!("signed in: path {} status {} spaces {} ({:?})", login.path, login.status, login.spaces, t.elapsed());
    } else {
        println!("already signed in as {}", account.subject);
    }

    let spaces = client.space_list().wait()?.spaces;
    let space = match spaces.iter().find_map(|s| s.id.clone()) {
        Some(id) => id,
        None => client.space_create("quickstart", relay.as_deref(), relay_key.as_deref()).wait()?.space.ok_or(ondb::Error::Protocol("no space id".into()))?,
    };
    client.set_default_space(&space).wait()?;

    let title = std::env::var("ONDB_TITLE").unwrap_or_else(|_| "Quickstart".into());
    let convo = client.convo_create(&space, &title, None, None).wait()?.object.ok_or(ondb::Error::Protocol("no object".into()))?;
    println!("conversation {convo} in space {space}");

    let mut sub = client.subscribe_conversation(&convo).wait()?;
    let mut parent = None;
    for i in 0..6 {
        let (role, text) = if i % 2 == 0 { ("user", format!("question {}", i / 2 + 1)) } else { ("assistant", format!("answer {}", i / 2 + 1)) };
        let r = client
            .record(
                &convo,
                &RecordArgs {
                    source: "quickstart".into(),
                    external_id: format!("turn-{i}"),
                    role: role.into(),
                    parent: parent.clone(),
                    text,
                    ..RecordArgs::default()
                },
            )
            .wait()?;
        parent = r.msg.clone();
    }
    let mut seen = 0;
    while seen < 6 {
        match sub.blocking_recv_timeout(Duration::from_secs(5)) {
            Some(SubItem::Deltas(ds)) => seen += ds.iter().filter(|d| d.kind == "message").count(),
            Some(SubItem::Gap(g)) => println!("gap {g:?}"),
            Some(_) => {}
            None => break,
        }
    }
    println!("live deltas: {seen} message records");

    let mut older = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let page = client.convo_page(&convo, &PageArgs { limit: 2, dir: Dir::Older, cursor: cursor.clone(), ..PageArgs::default() }).wait()?;
        older.extend(page.messages.iter().map(|m| format!("{}: {}", m.role, m.text())));
        if !page.more {
            break;
        }
        cursor = Some(page.cursor);
    }
    println!("older pages (newest first): {older:?}");

    let first = client.convo_page(&convo, &PageArgs { limit: 64, dir: Dir::Older, ..PageArgs::default() }).wait()?;
    let root = first.messages.last().and_then(|m| m.id.clone());
    let w = client.convo_window(&convo, root.as_deref(), 0, 1).wait()?;
    let mut newer: Vec<String> = w.messages.iter().map(|m| format!("{}: {}", m.role, m.text())).collect();
    let mut cursor = w.newer_cursor.clone();
    let mut more = w.more_newer;
    while more {
        let page = client.convo_page(&convo, &PageArgs { limit: 2, dir: Dir::Newer, cursor: Some(cursor.clone()), ..PageArgs::default() }).wait()?;
        newer.extend(page.messages.iter().map(|m| format!("{}: {}", m.role, m.text())));
        more = page.more;
        cursor = page.cursor;
    }
    println!("newer pages (oldest first): {newer:?}");
    drop(sub);
    host.stop();
    Ok(())
}
