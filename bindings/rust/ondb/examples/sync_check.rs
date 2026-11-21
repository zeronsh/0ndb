mod common;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use common::{arg_or_env, DirStore, TestPasskey};
use ondb::{Autostart, Client, Dir, HostBuilder, Options, PageArgs, SubItem};

fn main() -> ondb::Result<()> {
    let home = PathBuf::from(arg_or_env(1, "ONDB_HOME", "/tmp/ondb-sync-check"));
    let exe = arg_or_env(2, "ONDB_BIN", "0ndb");
    let store_dir = PathBuf::from(arg_or_env(3, "ONDB_ACCOUNT_STORE", "/tmp/ondb-account-store"));
    let passkey = PathBuf::from(arg_or_env(4, "ONDB_TEST_PASSKEY", &home.join("test-passkey").to_string_lossy()));
    let title = arg_or_env(5, "ONDB_TITLE", "Quickstart");
    std::fs::create_dir_all(&home)?;
    let sock = home.join("run").join("daemon.sock");
    let client = Client::connect_with(Options {
        socket: Some(sock.clone()),
        autostart: Some(Autostart::new(&exe).env("ONDB_HOME", home.to_string_lossy()).arg("--host-plugs").arg("sealed_store,unlock").arg("--no-runner")),
        ..Options::default()
    })?;
    let host = HostBuilder::new().socket(&sock).sealed_store(DirStore { dir: store_dir }).unlock(TestPasskey { path: passkey }).spawn()?;
    host.wait_registered(Duration::from_secs(10))?;
    let subject = std::env::var("ONDB_SUBJECT").unwrap_or_else(|_| "quickstart@example.com".into());
    if !client.account_state().wait()?.signed_in {
        let login = client.account_login(&subject, "sync-check", None, None).wait()?;
        println!("second device signed in: path {} spaces {}", login.path, login.spaces);
    }
    let space = client.space_list().wait()?.spaces.into_iter().find_map(|s| s.id).ok_or(ondb::Error::Protocol("no space after sign-in".into()))?;
    let t = Instant::now();
    let mut sub = client.subscribe_catalog(&space).wait()?;
    let deadline = Instant::now() + Duration::from_secs(60);
    let object = loop {
        let rows = client.catalog_list(&space, false, None, 200).wait()?.rows;
        if let Some(r) = rows.iter().find(|r| r.title == title) {
            break format!("{space}/{}", r.object.clone().unwrap_or_default());
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(ondb::Error::Status(ondb::Status::TIMEOUT));
        }
        match sub.blocking_recv_timeout(left) {
            Some(SubItem::Deltas(_)) | Some(SubItem::Gap(_)) => {}
            None => return Err(ondb::Error::Status(ondb::Status::TIMEOUT)),
        }
    };
    println!("conversation {object} visible after {:?}", t.elapsed());

    let mut msgs = 0;
    let mut older = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let page = client.convo_page(&object, &PageArgs { limit: 2, dir: Dir::Older, cursor: cursor.clone(), ..PageArgs::default() }).wait_timeout(Duration::from_secs(30))?;
        older.extend(page.messages.iter().map(|m| format!("{}: {}", m.role, m.text())));
        if !page.more {
            break;
        }
        cursor = Some(page.cursor);
    }
    msgs += older.len();
    println!("older: {older:?}");
    let all = client.convo_page(&object, &PageArgs { limit: 64, dir: Dir::Older, ..PageArgs::default() }).wait()?;
    let root = all.messages.last().and_then(|m| m.id.clone());
    let w = client.convo_window(&object, root.as_deref(), 0, 1).wait()?;
    let mut newer: Vec<String> = w.messages.iter().map(|m| format!("{}: {}", m.role, m.text())).collect();
    let (mut more, mut cur) = (w.more_newer, w.newer_cursor.clone());
    while more {
        let p = client.convo_page(&object, &PageArgs { limit: 2, dir: Dir::Newer, cursor: Some(cur.clone()), ..PageArgs::default() }).wait()?;
        newer.extend(p.messages.iter().map(|m| format!("{}: {}", m.role, m.text())));
        more = p.more;
        cur = p.cursor;
    }
    println!("newer: {newer:?}");
    println!("RESULT {} older, {} newer", msgs, newer.len());
    drop(sub);
    host.stop();
    Ok(())
}
