# Embedding 0ndb from another app

This guide is for an application (a desktop UI, an editor, a server) that
uses 0ndb as its engine through the device daemon instead of linking
lib0ndb. The app gets durable, end-to-end encrypted, synced conversations,
a session list, file trees and maps; agent runs with durable queueing and
steering; search; and live updates, all over one local socket. The wire
protocol is `docs/daemon-protocol.md`; the reference client is the Rust crate
`bindings/rust/ondb`.

## 1. Shape

```
  UI process ──────────┐                      ┌── other devices (their daemons)
  (ondb::Client,       │   local socket       │
   Unlock host)        ├──── 0ndb daemon ─────┼── relay (0ndb relay, or a
  host process ────────┘   (engine, runtime,  │    Durable Object speaking
  (Sealed_Store,            runner, links)    │    docs/relay-protocol.md)
   Credentials, pool)                         └── cloud runners (pool)
```

- One daemon per user and data directory. It keeps running when the UI quits
  (runs continue, other devices sync) and serves any number of clients.
- The UI is a client: typed calls, subscriptions and events. It never polls.
- Plug points the app owns (the account server, the platform passkey, relay
  credentials, a cloud runner pool) are answered by a host connection over the
  same socket (section 5). The UI process can be the host for the plugs it
  owns (typically `unlock`); a separate local process (the app's background
  helper, or the UI again) proxies `sealed_store` and `credentials` to the
  app's backend.
- What 0ndb owns: storage, history, branching and sync of every conversation
  and of the session list (the catalog); running agents through provider CLIs
  (Claude Code, Codex, Pi and ACP harnesses) or the native model loop, with
  queueing, steering, interrupts, permissions and placement on any of the
  user's devices or a cloud pool; folders and git checkouts mounted as synced
  trees with write attribution and rewind; search across devices.
- What the app owns: identity (its login provider decides the account
  subject), the account server that stores the sealed account record, the
  passkey UI, provisioning of cloud machines, and its own UI state.

Two ways to run agents:

1. Through the 0ndb runtime. Create a conversation with a provider and model,
   then `send`, `queue`, `steer`, `edit`, `interrupt`, `answer`. Runs are
   placed on a runner (this device unless started with `--no-runner`, another
   signed-in device, or a cloud pool runner), survive restarts, and stream
   back as deltas on every device.
2. The app runs the harness and records through 0ndb. Call `record(object,
   source, external_id, sequence, role, parent, blocks, status, usage,
   provider, model)` for every message the harness produces. Recording is
   idempotent by `(source, external_id, sequence)`: replaying after a crash
   never duplicates, a higher sequence supersedes. Everything else (sync,
   session list, search, paging, other devices following live) works the same.

## 2. Connection lifecycle

Connect or start. A UI connects to the socket (`docs/daemon-protocol.md` 1)
and, if nothing answers, runs `0ndb daemon start [flags]` and connects again.
`daemon start` detaches the daemon (own session, no inherited pipes, log in
`daemon.log`), returns once it accepts connections, and does nothing when one
already runs. Keep the daemon's flags stable across starts (for example
`--host-plugs sealed_store,unlock`), since they are fixed for its lifetime.

```rust
let client = ondb::Client::connect_with(ondb::Options {
    autostart: Some(ondb::Autostart::new("0ndb").arg("--host-plugs").arg("sealed_store,unlock")),
    ..Default::default()
})?;
```

Reconnect. When the daemon goes away (update, crash, `daemon stop`) every
pending call fails with `Disconnected`, `connection_states()` yields
`Disconnected`, and the client reconnects (starting the daemon again when
autostart is set) with backoff from 50 ms to 2 s. On reconnect it resends
the events filter and every subscription, and puts a `Gap { reason:
Reconnected }` into each subscription stream: re-read what is on screen and
keep going; nothing on screen needs to be reset. A host built with
`HostBuilder` reconnects and re-registers the same way.

Headless. `0ndb daemon` in the foreground is the whole engine with no UI:
run it on a server or a VPS, sign it in once (`0ndb login`), and it syncs and
runs agents for the account. UIs on other devices drive it through sync:
conversations created anywhere can be placed on it (`assign`, or its runner
being the one that claims), and its output streams to every device.

Stopping. `daemon.stop` (or `0ndb daemon stop`) for updates and sign-out
flows; otherwise leave it running.

## 3. Event-driven by construction

- The daemon writes only when state changes: one Deltas frame per
  subscription per engine tick (consecutive streamed text of a block is
  joined within the tick), with every frame of a loop step flushed in one
  write. No heartbeats or periodic status on local sockets, no timers for
  idle connections.
- The Rust client has one reader thread blocked in `read()` and delivers
  through futures and streams (`recv().await`, or `blocking_recv()`); it
  arms no timers. Calls can be pipelined.
- A slow UI never makes the daemon buffer without bound. Past 1 MiB queued it
  keeps the latest state instead of every step: the set of changed session
  rows, the latest event per key (placement, presence, connectivity), and a
  gap mark for conversations; then it sends `Gap` frames and the UI re-reads
  rows or pages from its cursor. The client applies the same policy to its own
  bounded queues (`Options::queue_limit`, default 1024 items).
- Subscriptions use compact JSON deltas (zero fields omitted) and the events
  stream leaves out per-tick `durable` and `uploaded` notifications.

Measured on Linux x86-64 (8 cores, load 11 to 13 from other work), release
builds, daemon and client on one machine:

| measurement | result |
|---|---|
| idle 60 s, client subscribed to catalog, one conversation, events (presence, placement, status) and connection state | daemon: 0 context switches, no armed timer (`timeout_ms` -1); client reader thread: 0 context switches, 0 socket reads, 0 bytes |
| call round trip (`identity`, JSON) | p50 13 to 30 µs, p99 0.13 to 2.5 ms |
| call round trip (`identity`, binary) | p50 13 to 29 µs |
| `convo.page` of 20 messages | p50 57 to 87 µs |
| `convo.status` | p50 22 µs |
| pipelined calls | 58,700 calls/s on one connection |
| streamed reply (Claude Code, haiku, 654 output tokens in 5.0 s) with conversation, catalog and events subscribed | 178 conversation frames, 176 client socket reads (35 wakeups/s, 0.27 per token), 43,010 bytes = 66 bytes per output token |
| the same before compact deltas and the events filter (588 tokens) | 309 frames (155 of them `durable` events), 66 wakeups/s, 185 bytes per token |
| sign-in through host plugs (create account: get, register, put) | 3 to 7 ms |
| conversation created on device A visible on device B through `0ndb relay` | about 20 ms |

The idle and streaming figures come from `bindings/rust/ondb/examples/bench.rs`
(`bench idle 60`, `bench stream claude haiku "..."`), which reads
`/proc/<pid>/task/*/status` context-switch counters of both processes.

## 4. Data the UI shows

- Spaces (`space.list`, `space.create`): the unit of sharing and sync. A
  signed-in account brings its spaces to every device.
- The session list is the catalog of a space: `catalog.list` pages rows
  (title, kind, status, activity, archived, pinned, parent, workspace, agent)
  and `subscribe.catalog` streams changes. `catalog.set` renames, archives,
  pins.
- Conversations: `convo.window` around a message, `convo.page` both ways with
  cursors, `convo.message`, `convo.siblings` and `switch`/`back` for branches,
  `convo.status` and `status` deltas for running, queued, awaiting permission,
  waiting for a runner. `placement` and `placement` events say which device
  runs the next turn, or that the conversation is `idle` because its last
  runner stopped. Recipes: `docs/daemon-protocol.md` 7.
- Device switcher: `runners(space, object)` (and `subscribe.runners`) lists
  each device and each pool once, with `online`/`offline`/`wakeable`,
  providers installed and signed in, and the current and last runner;
  `assign(object, runner)` resumes the conversation there, continuing a
  cut-off turn with its full context. `takeover.set` picks what happens when
  a runner goes away: `default` (devices: the conversation goes idle; pool
  runners: a placement request naming the runner), `auto` or `never`.
- Folders and repositories: `mount.add(object, root)` keeps a folder synced as
  a tree; `mount` attaches a tree to a conversation so its runs edit it;
  `tree.find(path)` maps a path to its tree; `convo.files_at`, `go_back` and
  `revert` rewind files with the conversation. A git checkout is an ordinary
  folder; worktrees are separate folders mounted separately (0ndb never moves
  or deletes a branch).
- Search: `search(query, space, scope)` across this device's index and, when
  another device keeps a full index of the space, that index too; remote hits
  are fetched and verified locally.
- Redaction: `redact(object, msg)` zero-fills a message's content everywhere
  it replicates.

## 5. Sign-in through host plugs

An account is identified by an opaque subject from the app's identity
provider. Its record (the account signing and box keys sealed under passkey
PRF outputs and a recovery key, plus a manifest of the account's spaces)
lives on the app's account server; the server stores ciphertext only and
never sees a key. Signing in on a device:

1. `account.login(subject, label, relay, relay_key)`: the daemon fetches the
   record (`sealed_store.get`). With none it creates the account, registers a
   passkey (`unlock.register`) and stores the record (`sealed_store.put`):
   `path: created`.
2. With a record it asks for the passkey (`unlock.unlock`, credentials and
   salts from the record): `path: passkey`.
3. Without a usable passkey it asks a signed-in device to approve:
   `status: waiting`, with `code`. The other device gets an
   `approval_requested` event and calls `approval.respond(code, true)`; this
   device gets `login_done`.
4. With no device online (`account.state` shows `no_approver`):
   `account.login_cross_device` (a passkey on a phone, hybrid transport) or
   `account.login_recovery(subject, key)`.

`account.sign_out` keeps every space on the device, working local-only.
Without any sign-in the daemon is fully local-only: every feature that needs
no other device works, and a later sign-in brings the existing spaces into the
account with their history.

A space replicates only when it names a relay. A space with no relay is
local-only whatever transport the embedder supplies: no replicator runs and
nothing is announced. A host transport (`ondb_transport`) carries the bytes to
the relay the space names (`ondb_peer.relay`); it does not make a relay-less
space replicate. Everything written while local-only, including tree contents
ingested from disk, is announced once the space gets a relay (sign-in or
`space.set_relay`).

### Worked example: WorkOS

- Subject: the WorkOS user id (`user_01...`) from AuthKit, after the app's
  normal WorkOS sign-in (hosted or loopback code exchange).
- Account server: three endpoints on the app's backend, authorized with the
  user's WorkOS access token and keyed by its `sub` (refuse any other
  subject):
  - `GET /account/{subject}`: the record and entries, 404 when absent;
  - `PUT /account/{subject}` with `prev_seq` and `seq`: compare-and-swap on
    the stored seq (0 when absent), 409 on mismatch, 200 when the stored
    record is already byte-identical;
  - `POST /account/{subject}/entries`: append one entry.
  A key-value row per subject (a Durable Object per account, or a database
  row with a version column) is enough; records are at most 64 KiB and
  entries at most 4 MiB in all.
- Sealed_Store host: a local process maps plug requests to those calls.
  Requests are asynchronous: the daemon keeps serving everything else while
  one waits for the backend, and several may be outstanding at once (the
  Rust host runs each on its own thread with a `CancelToken`).

```rust
struct WorkosStore { http: MyHttp, token: TokenSource }

impl ondb::SealedStore for WorkosStore {
    fn get(&self, subject: &[u8], _c: &ondb::CancelToken) -> ondb::PlugResult<Option<ondb::AccountRecord>> {
        match self.http.get_account(&self.token.bearer()?, subject) {
            Ok(Some((record, entries))) => Ok(Some(ondb::AccountRecord { record, entries })),
            Ok(None) => Ok(None),
            Err(e) if e.unauthorized() => Err(ondb::PlugError::PERMISSION),
            Err(_) => Err(ondb::PlugError::IO),
        }
    }
    fn put(&self, subject: &[u8], record: &[u8], prev_seq: u64, seq: u64, _c: &ondb::CancelToken) -> ondb::PlugResult<()> {
        match self.http.put_account(&self.token.bearer()?, subject, record, prev_seq, seq) {
            Ok(()) => Ok(()),
            Err(e) if e.status() == 409 => Err(ondb::PlugError::CONFLICT),
            Err(_) => Err(ondb::PlugError::IO),
        }
    }
    fn add(&self, subject: &[u8], entry: &[u8], _c: &ondb::CancelToken) -> ondb::PlugResult<()> {
        self.http.add_entry(&self.token.bearer()?, subject, entry).map_err(|_| ondb::PlugError::IO)
    }
}
```

- Unlock host: the UI's native passkey, with the WebAuthn PRF extension and
  user verification required. Relying party: the app's domain; `rp_user` from
  the request is the WebAuthn user handle. `unlock` passes
  `prf.evalByCredential` with each credential's salt and returns the chosen
  credential id and its 32-byte output; `mode: cross_device` means "use a
  passkey on another device" (hybrid/QR). `register` creates a passkey and
  evaluates PRF with the given salt. On macOS 15+ that is
  `ASAuthorizationPlatformPublicKeyCredentialProvider` with the PRF
  extension, on Windows 11 the WebAuthn API with `hmac-secret`/PRF, on Linux
  there is no platform passkey: use approval, a phone (cross-device) or the
  recovery key.

```rust
let host = ondb::HostBuilder::new()
    .sealed_store(WorkosStore { http, token })
    .unlock(NativePasskeys::new(window_handle))
    .spawn()?;
host.wait_registered(std::time::Duration::from_secs(5))?;
let r = client.account_login(&workos_user_id, "MacBook", Some(relay), Some(relay_key)).await?;
```

- If the app runs WebAuthn in its own web origin (or WorkOS ever exposes the
  PRF output), skip the `unlock` plug: `account.idp_salt(subject)` gives the
  salt, the browser evaluates PRF, and `account.login_prf(subject,
  credential, prf, ...)` signs in; `account.passkey_add` adds such a passkey.

### Relay credentials

`0ndb relay` authenticates devices with the space's member credentials; no
plug is needed. A hosted relay that wants its own bearer (a WorkOS token per
connection, say) uses the `credentials` plug: the host lists the spaces it
supplies credentials for when it registers (`Credentials::spaces` in Rust),
and `produce(space, binding)` returns one credential bound to the relay's
challenge; the relay connection waits for it without holding anything else
up.

## 6. Cloud runners through a runner pool

A runner pool is a member of the account's spaces whose key lives with the
app's backend; it enrolls short-lived runners (one per cloud sandbox) without
any user device online. Pieces:

- Pool host: a daemon in the backend started with `--host-plugs runner_pool`
  (or `--pool-host` for the built-in reference), with a host that implements
  `RunnerPool`: `identity` (the pool's public keys: the pool host daemon's
  own `identity`, whose private key can sit behind a KMS keyring),
  `verify(token, runner)` (check the launch token the provisioning service
  issued for that sandbox, return the lease in ms), optional `attest`.
- User devices: their accounts include the pool on first sign-in when the
  daemon has `pool_user` (host plug) or `ONDB_POOL_CARD` (the pool's card);
  `space.pool(space, on)` includes or removes it per space. The `joined`
  notification carries the proof the pool host passes to
  `space.join_enrollment`, so the backend learns every space it may serve.
- Launch: provisioning starts a sandbox running `0ndb runner --pool-token
  TOKEN` (storage `stored`), with the pool host's daemon socket reachable as
  `ONDB_POOL_HOST_SOCK` (a forwarded Unix socket). The runner makes its own
  device key, sends its card and the token (`pool.enroll`), applies the
  returned enrollment (`runner.enroll`) and renews its lease on one timer.
  Every user device sees `runner_enrolled`; more than the alarm threshold in a
  minute raises `runner_anomaly`.
- Placement: a conversation's run goes to a pool runner when it is assigned
  (`assign`) or when the placement policy picks it; `placement` events report
  `waiting_runner` until one claims the run, which is when provisioning should
  start a sandbox. When the conversation last ran on a pool runner that has
  gone to sleep, the request names that runner (`runner`): wake it (its disk
  keeps the checkout and caches; on wake it asks the pool host to renew its
  lapsed lease, `Runner_Pool.renew`, and takes the work) or launch another and `assign` it. `assign(object,
  pool)` from a UI ("continue in Cloud") is the same request. The
  `scheduler` host plug (`ondb::Scheduler` in Rust, `ondb_scheduler` in C)
  answers every placement in the host's own code, asynchronously.

```rust
struct Sandboxes { tokens: TokenVerifier, pool_identity: ondb::PublicIdentity }

impl ondb::RunnerPool for Sandboxes {
    fn identity(&self) -> ondb::PlugResult<ondb::PublicIdentity> { Ok(self.pool_identity) }
    fn verify(&self, token: &[u8], _runner: &ondb::PublicIdentity, _c: &ondb::CancelToken) -> ondb::PlugResult<u64> {
        self.tokens.check(token).map(|_| 15 * 60 * 1000).ok_or(ondb::PlugError::PERMISSION)
    }
}
```

## 7. Relays

- `0ndb relay --listen ADDR [--dir DIR] [--open] [--quota BYTES]`: TCP with
  kernel TLS, prints its key (`relay key ...`). Pass `relay` and `relay_key`
  to `account.login` or `space.create`. It stores ciphertext and the
  membership log, enforces member credentials, leases and quotas, and keeps
  no plaintext.
- Local: two daemons on one machine sync through each other's socket (a
  connection that does not start with `0NDB` is the relay protocol).
- A Cloudflare Durable Object (or any server) that implements
  `docs/relay-protocol.md` is a drop-in relay; that document is being written
  alongside this one.
- No relay: local-only. Everything works on the device; sign-in, other
  devices and cloud runners need a relay.

## 8. Live editor buffers

Editors open a text object, or a file of a mounted tree by path, as a live
buffer and edit it surgically: LSP-style edits, pipelined, merged with every
other writer (other editors, agents, other devices) and streamed back as
retain/delete/insert deltas. The wire surface is `docs/daemon-protocol.md`
section 9. In Rust, `ondb::LiveBuffer` does the client side:

```rust
let mut buf = ondb::LiveBuffer::open(&client, &ondb::OpenArgs {
    object: notes.clone(), units: ondb::Units::Utf16, ..Default::default()
}).await?;
buf.edit(&[ondb::TextEdit { pos: 0, del: 0, ins: "# ".into() }], 1)?;
while let Some(change) = buf.recv().await {
    match change {
        ondb::Change::Delta { ops, .. } => editor.apply(&ondb::ops_to_edits(&ops)),
        ondb::Change::Cursors(c) => editor.show_cursors(&c),
        ondb::Change::Reopen | ondb::Change::Closed(_) => break,
    }
}
```

`edit` applies locally at once, sends without waiting and returns the edit's
sequence number; acknowledgements are absorbed as they arrive (`flush_blocking`
waits for all of them, and an edit the daemon refuses surfaces as
`Change::Closed` with its status on the next `recv`); incoming deltas are transformed
over the unacknowledged edits, so the text never jumps. `read` and
`load_all_blocking` fill a large file's unloaded ranges, `anchors`/`resolve`
give positions that survive every edit, `set_cursors` publishes this editor's
selections, `undo`/`redo` act on this actor's edit groups. `Reopen` means the
connection or the client queue lost events and the buffer must be opened
again; `Closed` carries the daemon's status (`conflict` also means reopen).
Measured against the live-buffer daemon: two actors on one connection
sending about 345 random edits each run (multi-byte and astral characters,
UTF-16 units), with up to dozens in flight, converged byte-for-byte with the
daemon's text, and anchors moved with a concurrent insert.

## 9. Try it today

Linux or macOS, from a checkout of `odin-rewrite`:

```sh
odin build src/cli -out:$HOME/bin/0ndb -o:speed
export ONDB_BIN=$HOME/bin/0ndb

$ONDB_BIN relay --listen 127.0.0.1:47900 --dir /tmp/ondb-relay --open &
KEY=...            # the "relay key" line it prints

export ONDB_HOME=/tmp/ondb-a
$ONDB_BIN daemon start --host-plugs sealed_store,unlock
$ONDB_BIN host --plugs sealed_store,unlock --store /tmp/ondb-account &
$ONDB_BIN login --subject me@example.com --relay 127.0.0.1:47900 --relay-key $KEY
$ONDB_BIN new "First" -m "hello"
$ONDB_BIN log
```

`0ndb host` is the reference host: a file account store (shared directory =
your account server), a software passkey, runner-pool launch tokens and
static relay credentials. It reconnects when the daemon restarts.

From Rust, the quickstart starts a daemon, serves the plugs from Rust (a
directory store and a test passkey), signs in, creates a conversation,
records six messages through the provider-less record path, follows them
live and pages both ways:

```sh
cd bindings/rust/ondb
cargo run --release --example quickstart -- /tmp/ondb-a $ONDB_BIN /tmp/ondb-account
```

A second device (another data directory on the same machine) signs in with
the same store and passkey file, waits for the conversation through a catalog
subscription and pages it both ways:

```sh
ONDB_RELAY=127.0.0.1:47900 ONDB_RELAY_KEY=$KEY \
  cargo run --release --example quickstart -- /tmp/ondb-a $ONDB_BIN /tmp/ondb-account
cargo run --release --example sync_check -- /tmp/ondb-b $ONDB_BIN /tmp/ondb-account /tmp/ondb-a/test-passkey Quickstart
```

To run agents, start a daemon without `--no-runner` and create the
conversation with a provider: `client.convo_create(&space, "Task",
Some("claude"), Some("sonnet"))`, then `client.send(&object, "...")` and read
the subscription. `0ndb models` lists the providers installed on the device.

## 10. Current limits

- The daemon socket is local only; remote UIs drive a device through sync.
- The Rust crate uses std sockets on Linux and macOS and the `uds_windows`
  crate for AF_UNIX on Windows; it passes `cargo clippy` for
  `x86_64-pc-windows-gnu` and `aarch64-apple-darwin` but has been run only on
  Linux so far.
