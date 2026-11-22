use serde_json::{json, Map, Value};

use crate::codec::hex;
use crate::conn::{Client, Pending, SubKind, Subscription};
use crate::types::*;

fn put(m: &mut Map<String, Value>, k: &str, v: Option<impl Into<Value>>) {
    if let Some(v) = v {
        m.insert(k.to_string(), v.into());
    }
}

fn nonempty(s: &str) -> Option<&str> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

impl Client {
    pub fn daemon_status(&self) -> Pending<DaemonStatus> {
        self.call(&json!({"op": "daemon.status"}))
    }

    pub fn daemon_stop(&self) -> Pending<Ack> {
        self.call(&json!({"op": "daemon.stop"}))
    }

    pub fn describe(&self) -> Pending<Value> {
        self.call(&json!({"op": "describe"}))
    }

    pub fn identity(&self) -> Pending<Identity> {
        self.call(&json!({"op": "identity"}))
    }

    pub fn state(&self) -> Pending<State> {
        self.call(&json!({"op": "state.get"}))
    }

    pub fn set_default_space(&self, space: &str) -> Pending<Ack> {
        self.call(&json!({"op": "state.set", "default_space": space}))
    }

    pub fn space_create(&self, name: &str, relay: Option<&str>, relay_key: Option<&str>) -> Pending<SpaceCreated> {
        let mut m = Map::new();
        m.insert("op".into(), "space.create".into());
        m.insert("name".into(), name.into());
        put(&mut m, "relay", relay);
        put(&mut m, "relay_key", relay_key);
        self.call(&Value::Object(m))
    }

    pub fn space_list(&self) -> Pending<Spaces> {
        self.call(&json!({"op": "space.list"}))
    }

    pub fn space_info(&self, space: &str) -> Pending<Value> {
        self.call(&json!({"op": "space.info", "space": space}))
    }

    pub fn convo_create(&self, space: &str, title: &str, provider: Option<&str>, model: Option<&str>) -> Pending<Created> {
        let mut m = Map::new();
        m.insert("op".into(), "convo.create".into());
        m.insert("space".into(), space.into());
        m.insert("title".into(), title.into());
        put(&mut m, "provider", provider);
        put(&mut m, "model", model);
        self.call(&Value::Object(m))
    }

    pub fn convo_status(&self, object: &str) -> Pending<ConvoStatus> {
        self.call(&json!({"op": "convo.status", "object": object}))
    }

    pub fn convo_page(&self, object: &str, a: &PageArgs) -> Pending<Page> {
        let mut m = Map::new();
        m.insert("op".into(), "convo.page".into());
        m.insert("object".into(), object.into());
        m.insert("dir".into(), a.dir.name().into());
        if a.limit > 0 {
            m.insert("limit".into(), a.limit.into());
        }
        put(&mut m, "from", a.from.clone());
        put(&mut m, "leaf", a.leaf.clone());
        put(&mut m, "cursor", a.cursor.clone().filter(|c| !c.is_empty()));
        self.call(&Value::Object(m))
    }

    pub fn convo_window(&self, object: &str, anchor: Option<&str>, before: u64, after: u64) -> Pending<Window> {
        let mut m = Map::new();
        m.insert("op".into(), "convo.window".into());
        m.insert("object".into(), object.into());
        m.insert("before".into(), before.into());
        m.insert("after".into(), after.into());
        put(&mut m, "anchor", anchor);
        self.call(&Value::Object(m))
    }

    pub fn convo_message(&self, object: &str, msg: &str) -> Pending<MessageReply> {
        self.call(&json!({"op": "convo.message", "object": object, "msg": msg}))
    }

    pub fn send(&self, object: &str, text: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "send", "object": object, "text": text}))
    }

    pub fn send_with(&self, object: &str, text: &str, parent: Option<&str>, provider: Option<&str>, model: Option<&str>) -> Pending<WriteResult> {
        let mut m = Map::new();
        m.insert("op".into(), "send".into());
        m.insert("object".into(), object.into());
        m.insert("text".into(), text.into());
        put(&mut m, "parent", parent);
        put(&mut m, "provider", provider);
        put(&mut m, "model", model);
        self.call(&Value::Object(m))
    }

    pub fn queue(&self, object: &str, text: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "queue", "object": object, "text": text}))
    }

    pub fn steer(&self, object: &str, msg: &str, text: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "steer", "object": object, "msg": msg, "text": text}))
    }

    pub fn edit(&self, object: &str, item: &str, text: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "edit", "object": object, "item": item, "text": text}))
    }

    pub fn cancel_item(&self, object: &str, item: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "cancel", "object": object, "item": item}))
    }

    pub fn interrupt(&self, object: &str, msg: Option<&str>) -> Pending<WriteResult> {
        let mut m = Map::new();
        m.insert("op".into(), "interrupt".into());
        m.insert("object".into(), object.into());
        put(&mut m, "msg", msg);
        self.call(&Value::Object(m))
    }

    pub fn answer(&self, object: &str, request: &str, allow: bool, text: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "answer", "object": object, "request": request, "allow": allow, "text": text}))
    }

    pub fn switch(&self, object: &str, sibling: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "switch", "object": object, "sibling": sibling}))
    }

    pub fn back(&self, object: &str, msg: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "back", "object": object, "msg": msg}))
    }

    pub fn follow(&self, object: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "follow", "object": object}))
    }

    pub fn redact(&self, object: &str, msg: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "redact", "object": object, "msg": msg}))
    }

    pub fn record(&self, object: &str, a: &RecordArgs) -> Pending<Receipt> {
        let mut m = Map::new();
        m.insert("op".into(), "record".into());
        m.insert("object".into(), object.into());
        m.insert("source".into(), a.source.clone().into());
        m.insert("external_id".into(), a.external_id.clone().into());
        m.insert("sequence".into(), a.sequence.into());
        m.insert("role".into(), (if a.role.is_empty() { "assistant" } else { a.role.as_str() }).into());
        m.insert("blocks".into(), json!([{"kind": "text", "text": a.text}]));
        put(&mut m, "parent", a.parent.clone());
        m.insert("status".into(), a.status.clone().unwrap_or_else(|| "done".into()).into());
        put(&mut m, "provider", nonempty(&a.provider));
        put(&mut m, "model", nonempty(&a.model));
        self.call(&Value::Object(m))
    }

    pub fn catalog_list(&self, space: &str, archived: bool, after: Option<&str>, limit: u64) -> Pending<CatalogList> {
        let mut m = Map::new();
        m.insert("op".into(), "catalog.list".into());
        m.insert("space".into(), space.into());
        m.insert("archived".into(), archived.into());
        if limit > 0 {
            m.insert("limit".into(), limit.into());
        }
        put(&mut m, "after", after.filter(|a| !a.is_empty()));
        self.call(&Value::Object(m))
    }

    pub fn catalog_get(&self, object: &str) -> Pending<CatalogGet> {
        self.call(&json!({"op": "catalog.get", "object": object}))
    }

    pub fn catalog_set_title(&self, object: &str, title: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "catalog.set", "object": object, "title": title}))
    }

    pub fn catalog_set_archived(&self, object: &str, archived: bool) -> Pending<WriteResult> {
        self.call(&json!({"op": "catalog.set", "object": object, "archived": archived}))
    }

    pub fn catalog_set_pinned(&self, object: &str, pinned: bool) -> Pending<WriteResult> {
        self.call(&json!({"op": "catalog.set", "object": object, "pinned": pinned}))
    }

    pub fn subscribe_conversation(&self, object: &str) -> Pending<Subscription> {
        self.subscribe(&json!({"op": "subscribe", "object": object, "kind": "conversation"}), false)
    }

    pub fn subscribe_catalog(&self, space: &str) -> Pending<Subscription> {
        self.subscribe(&json!({"op": "subscribe.catalog", "space": space}), true)
    }

    pub fn runner_renewal_request(&self) -> Pending<Value> {
        self.call(&json!({"op": "runner.renewal_request"}))
    }

    pub fn pool_renew(&self, request: &str) -> Pending<Value> {
        self.call(&json!({"op": "pool.renew", "request": request}))
    }

    pub fn runner_renew(&self, renewal: &str) -> Pending<Value> {
        self.call(&json!({"op": "runner.renew", "renewal": renewal}))
    }

    pub fn placement(&self, object: &str) -> Pending<Placement> {
        self.call(&json!({"op": "placement", "object": object}))
    }

    pub fn assign(&self, object: &str, msg: &str, runner: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "assign", "object": object, "msg": msg, "runner": runner}))
    }

    pub fn resume(&self, object: &str, runner: &str) -> Pending<Ack> {
        self.call(&json!({"op": "assign", "object": object, "runner": runner}))
    }

    pub fn runners(&self, space: &str, object: Option<&str>) -> Pending<Runners> {
        let mut m = Map::new();
        m.insert("op".into(), "runners".into());
        m.insert("space".into(), space.into());
        put(&mut m, "object", object);
        self.call(&Value::Object(m))
    }

    pub fn subscribe_runners(&self, space: &str, object: Option<&str>) -> Pending<Subscription> {
        let mut m = Map::new();
        m.insert("op".into(), "subscribe.runners".into());
        m.insert("space".into(), space.into());
        put(&mut m, "object", object);
        self.subscribe_with(&Value::Object(m), SubKind::Runners, |sub, _| Ok(sub))
    }

    pub fn takeover_get(&self, object: &str, level: &str) -> Pending<TakeoverPolicy> {
        self.call(&json!({"op": "takeover.get", "object": object, "level": level}))
    }

    pub fn takeover_set(&self, object: &str, level: &str, policy: &str) -> Pending<Ack> {
        self.call(&json!({"op": "takeover.set", "object": object, "level": level, "policy": policy}))
    }

    pub fn quiesce(&self, off: bool, lift_ms: Option<u64>) -> Pending<Quiesced> {
        let mut m = Map::new();
        m.insert("op".into(), "quiesce".into());
        m.insert("off".into(), off.into());
        put(&mut m, "lift_ms", lift_ms);
        self.call_timeout(&Value::Object(m), 120_000)
    }

    pub fn runtime_stats(&self) -> Pending<RuntimeStats> {
        self.call(&json!({"op": "runtime.stats"}))
    }

    pub fn mount_add(&self, object: &str, root: &str) -> Pending<Ack> {
        self.call(&json!({"op": "mount.add", "object": object, "root": root}))
    }

    pub fn mount_remove(&self, root: &str) -> Pending<Ack> {
        self.call(&json!({"op": "mount.remove", "root": root}))
    }

    pub fn mounts(&self) -> Pending<MountedList> {
        self.call(&json!({"op": "tree.mounts"}))
    }

    pub fn tree_find(&self, path: &str) -> Pending<TreeFind> {
        self.call(&json!({"op": "tree.find", "path": path}))
    }

    pub fn convo_mount(&self, object: &str, name: &str, tree: &str, path: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "mount", "object": object, "name": name, "tree": tree, "path": path}))
    }

    pub fn search_with(&self, a: &SearchArgs) -> Pending<SearchResults> {
        let mut m = Map::new();
        m.insert("op".into(), "search".into());
        m.insert("query".into(), a.query.as_str().into());
        if a.limit > 0 {
            m.insert("limit".into(), a.limit.into());
        }
        put(&mut m, "space", a.space.as_deref());
        put(&mut m, "cursor", a.cursor.as_deref());
        put(&mut m, "sort", a.sort.as_deref());
        put(&mut m, "scope", a.scope.as_deref());
        if a.semantic {
            m.insert("semantic".into(), true.into());
        }
        if a.collapse {
            m.insert("collapse".into(), true.into());
        }
        self.call(&Value::Object(m))
    }

    pub fn text_create(&self, space: &str, title: &str, initial: &str) -> Pending<Created> {
        self.call(&json!({"op": "text.create", "space": space, "title": title, "initial": initial}))
    }

    pub fn tree_create(&self, space: &str, title: &str) -> Pending<Created> {
        self.call(&json!({"op": "tree.create", "space": space, "title": title}))
    }

    pub fn subscribe_object(&self, object: &str, kind: &str) -> Pending<Subscription> {
        self.subscribe(&json!({"op": "subscribe", "object": object, "kind": kind}), false)
    }

    pub fn map_create(&self, space: &str, title: &str) -> Pending<Created> {
        self.call(&json!({"op": "map.create", "space": space, "title": title}))
    }

    pub fn map_get(&self, object: &str, key: &[u8]) -> Pending<MapGet> {
        self.call(&json!({"op": "map.get", "object": object, "key": hex(key)}))
    }

    pub fn map_scan(&self, object: &str, prefix: &[u8], after: Option<&str>, limit: u64) -> Pending<MapScan> {
        let mut m = Map::new();
        m.insert("op".into(), "map.scan".into());
        m.insert("object".into(), object.into());
        m.insert("prefix".into(), hex(prefix).into());
        if limit > 0 {
            m.insert("limit".into(), limit.into());
        }
        put(&mut m, "after", after.filter(|a| !a.is_empty()));
        self.call(&Value::Object(m))
    }

    pub fn map_set(&self, object: &str, key: &[u8], fields: &[Field]) -> Pending<WriteResult> {
        let fs: Vec<Value> = fields.iter().map(|f| json!({"tag": f.tag, "value": hex(&f.value)})).collect();
        self.call(&json!({"op": "map.set", "object": object, "key": hex(key), "fields": fs}))
    }

    pub fn map_delete(&self, object: &str, key: &[u8], tags: &[u64]) -> Pending<WriteResult> {
        self.call(&json!({"op": "map.delete", "object": object, "key": hex(key), "tags": tags}))
    }

    pub fn map_add(&self, object: &str, key: &[u8], tag: u64, element: &[u8]) -> Pending<WriteResult> {
        self.call(&json!({"op": "map.add", "object": object, "key": hex(key), "tag": tag, "element": hex(element)}))
    }

    pub fn map_remove(&self, object: &str, key: &[u8], tag: u64, element: &[u8]) -> Pending<WriteResult> {
        self.call(&json!({"op": "map.remove", "object": object, "key": hex(key), "tag": tag, "element": hex(element)}))
    }

    pub fn map_redact(&self, object: &str, key: &[u8]) -> Pending<Ack> {
        self.call(&json!({"op": "map.redact", "object": object, "key": hex(key)}))
    }

    pub fn text_read(&self, object: &str) -> Pending<Text> {
        self.call(&json!({"op": "text.read", "object": object}))
    }

    pub fn text_spans(&self, object: &str) -> Pending<Spans> {
        self.call(&json!({"op": "text.spans", "object": object}))
    }

    pub fn text_edit(&self, object: &str, pos: u64, remove: u64, insert: &str) -> Pending<WriteResult> {
        self.call(&json!({"op": "text.edit", "object": object, "pos": pos, "remove": remove, "insert": insert}))
    }

    pub fn text_redact(&self, object: &str, pos: u64, len: u64) -> Pending<Ack> {
        self.call(&json!({"op": "text.redact", "object": object, "pos": pos, "len": len}))
    }

    pub fn tree_read(&self, object: &str, path: &str, line: Option<&str>) -> Pending<TreeText> {
        let mut m = Map::new();
        m.insert("op".into(), "tree.read".into());
        m.insert("object".into(), object.into());
        m.insert("path".into(), path.into());
        put(&mut m, "line", line);
        self.call(&Value::Object(m))
    }

    pub fn tree_list(&self, object: &str, path: &str, line: Option<&str>) -> Pending<TreeList> {
        let mut m = Map::new();
        m.insert("op".into(), "tree.list".into());
        m.insert("object".into(), object.into());
        m.insert("path".into(), path.into());
        put(&mut m, "line", line);
        self.call(&Value::Object(m))
    }

    pub fn tree_write(&self, object: &str, path: &str, text: &str, line: Option<&str>) -> Pending<TreeWritten> {
        let mut m = Map::new();
        m.insert("op".into(), "tree.write".into());
        m.insert("object".into(), object.into());
        m.insert("path".into(), path.into());
        m.insert("text".into(), text.into());
        put(&mut m, "line", line);
        self.call(&Value::Object(m))
    }

    pub fn tree_remove(&self, object: &str, path: &str, line: Option<&str>) -> Pending<TreeWritten> {
        let mut m = Map::new();
        m.insert("op".into(), "tree.remove".into());
        m.insert("object".into(), object.into());
        m.insert("path".into(), path.into());
        put(&mut m, "line", line);
        self.call(&Value::Object(m))
    }

    pub fn tree_blame(&self, object: &str, path: &str, line: Option<&str>) -> Pending<Blame> {
        let mut m = Map::new();
        m.insert("op".into(), "tree.blame".into());
        m.insert("object".into(), object.into());
        m.insert("path".into(), path.into());
        put(&mut m, "line", line);
        self.call(&Value::Object(m))
    }

    pub fn tree_sync(&self, object: &str, root: &str) -> Pending<Ack> {
        self.call(&json!({"op": "tree.sync", "object": object, "root": root}))
    }

    pub fn catalog_find(&self, space: &str, text: &str) -> Pending<CatalogRows> {
        self.call(&json!({"op": "catalog.find", "space": space, "text": text}))
    }

    pub fn account_devices(&self) -> Pending<Devices> {
        self.call(&json!({"op": "account.devices"}))
    }

    pub fn search_mode(&self, space: &str, mode: Option<&str>) -> Pending<SearchMode> {
        let mut m = Map::new();
        m.insert("op".into(), "search.mode".into());
        m.insert("space".into(), space.into());
        put(&mut m, "mode", mode);
        self.call(&Value::Object(m))
    }

    pub fn object_uploaded(&self, object: &str) -> Pending<Uploaded> {
        self.call(&json!({"op": "object.uploaded", "object": object}))
    }

    pub fn search(&self, query: &str, space: Option<&str>, limit: u64) -> Pending<SearchResults> {
        let mut m = Map::new();
        m.insert("op".into(), "search".into());
        m.insert("query".into(), query.into());
        if limit > 0 {
            m.insert("limit".into(), limit.into());
        }
        put(&mut m, "space", space);
        self.call(&Value::Object(m))
    }

    pub fn account_login(&self, subject: &str, label: &str, relay: Option<&str>, relay_key: Option<&str>) -> Pending<LoginResult> {
        let mut m = Map::new();
        m.insert("op".into(), "account.login".into());
        m.insert("subject".into(), subject.into());
        m.insert("label".into(), label.into());
        put(&mut m, "relay", relay);
        put(&mut m, "relay_key", relay_key);
        self.call(&Value::Object(m))
    }

    pub fn account_login_prf(&self, subject: &str, credential_hex: &str, prf_hex: &str, label: &str, relay: Option<&str>, relay_key: Option<&str>) -> Pending<LoginResult> {
        let mut m = Map::new();
        m.insert("op".into(), "account.login_prf".into());
        m.insert("subject".into(), subject.into());
        m.insert("credential".into(), credential_hex.into());
        m.insert("prf".into(), prf_hex.into());
        m.insert("label".into(), label.into());
        put(&mut m, "relay", relay);
        put(&mut m, "relay_key", relay_key);
        self.call(&Value::Object(m))
    }

    pub fn account_idp_salt(&self, subject: &str) -> Pending<Salt> {
        self.call(&json!({"op": "account.idp_salt", "subject": subject}))
    }

    pub fn account_login_cross_device(&self, subject: &str) -> Pending<LoginResult> {
        self.call(&json!({"op": "account.login_cross_device", "subject": subject}))
    }

    pub fn account_login_recovery(&self, subject: &str, key: &str) -> Pending<LoginResult> {
        self.call(&json!({"op": "account.login_recovery", "subject": subject, "key": key}))
    }

    pub fn account_state(&self) -> Pending<AccountState> {
        self.call(&json!({"op": "account.state"}))
    }

    pub fn approvals(&self) -> Pending<Approvals> {
        self.call(&json!({"op": "approval.list"}))
    }

    pub fn approve(&self, code: &str, approve: bool) -> Pending<Ack> {
        self.call(&json!({"op": "approval.respond", "code": code, "approve": approve}))
    }

    pub fn passkey_add(&self, label: &str, credential_hex: &str, prf_hex: &str) -> Pending<Ack> {
        self.call(&json!({"op": "account.passkey_add", "label": label, "credential": credential_hex, "prf": prf_hex}))
    }

    pub fn space_leave(&self, space: &str, device_only: bool) -> Pending<SpaceLeft> {
        self.call(&json!({"op": "space.leave", "space": space, "device_only": device_only}))
    }

    pub fn sign_out(&self, keep_relay: bool) -> Pending<SignedOut> {
        self.call(&json!({"op": "account.sign_out", "keep_relay": keep_relay}))
    }
}
