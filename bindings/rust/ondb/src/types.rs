use serde::{Deserialize, Serialize};

pub type Id = String;
pub type Rid = String;
pub type ObjectRef = String;

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Ack {}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Link {
    pub space: Option<Id>,
    pub error: String,
    pub reason: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct DaemonStatus {
    pub version: String,
    pub proto: u64,
    pub api: u64,
    pub pid: u64,
    pub home: String,
    pub socket: String,
    pub uptime_ms: i64,
    pub rss: i64,
    pub runner: bool,
    pub connections: u64,
    pub local_relay: bool,
    pub mcp_sessions: u64,
    pub wakeups: u64,
    pub timeout_ms: i64,
    pub host_plugs: Vec<String>,
    pub host_pending: u64,
    pub hosts: Vec<String>,
    pub links: Vec<Link>,
    pub timers: Vec<ArmedTimer>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct ArmedTimer {
    pub site: String,
    pub due_ms: i64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Uploaded {
    pub uploaded: bool,
    pub dropped: bool,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SearchArgs {
    pub query: String,
    pub space: Option<String>,
    pub limit: u64,
    pub cursor: Option<String>,
    pub sort: Option<String>,
    pub semantic: bool,
    pub collapse: bool,
    pub scope: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Identity {
    pub id: Option<Id>,
    pub sign: String,
    #[serde(rename = "box")]
    pub box_key: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Space {
    pub id: Option<Id>,
    pub name: String,
    pub relay: String,
    pub relay_key: String,
    pub mode: String,
    pub open: bool,
    pub connected: bool,
    pub catalog: Option<Id>,
    pub relay_usage: u64,
    pub relay_quota: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Spaces {
    pub spaces: Vec<Space>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct SpaceCreated {
    pub space: Option<Id>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Created {
    pub object: Option<ObjectRef>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct WriteResult {
    pub item: Option<Rid>,
    pub off: i64,
    pub leaf: Option<Rid>,
    pub tick: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Usage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct ConvoStatus {
    pub status: String,
    pub head: Option<Rid>,
    pub position: Option<Rid>,
    pub browsing: bool,
    pub head_status: String,
    pub queued: u64,
    pub waiting: u64,
    pub intents: u64,
    pub running: bool,
    pub awaiting: bool,
    pub revive: bool,
    pub head_hlc: u64,
    pub held: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Blob {
    pub oid: String,
    pub size: u64,
    pub preview: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Block {
    pub index: u64,
    pub kind: String,
    pub failed: bool,
    pub id: String,
    pub name: String,
    pub text: String,
    pub is_ref: bool,
    pub blob: Blob,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct FileRef {
    pub mount: String,
    pub tree: Option<Id>,
    pub line: Option<Id>,
    pub version: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct LineRef {
    pub mount: String,
    pub line: Option<Id>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Message {
    pub id: Option<Rid>,
    pub role: String,
    pub author: Option<Id>,
    pub parent: Option<Rid>,
    pub depth: i64,
    pub runner: Option<Id>,
    pub hlc: u64,
    pub provider: String,
    pub model: String,
    pub native: String,
    pub intent: Option<Rid>,
    pub status: String,
    pub open: bool,
    pub open_state: String,
    pub seal: Option<Rid>,
    pub usage: Usage,
    pub redacted: bool,
    pub sibling: u64,
    pub siblings: u64,
    pub superseded: bool,
    pub landed: bool,
    pub claim: Option<Rid>,
    pub files: Vec<FileRef>,
    pub lines: Vec<LineRef>,
    pub blocks: Vec<Block>,
}

impl Message {
    pub fn text(&self) -> String {
        self.blocks
            .iter()
            .filter(|b| b.kind == "text")
            .map(|b| b.text.as_str())
            .collect::<Vec<_>>()
            .join("")
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Position {
    pub msg: Option<Rid>,
    pub seal: Option<Rid>,
    pub seal_known: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Page {
    pub messages: Vec<Message>,
    pub next: Option<Position>,
    pub more: bool,
    pub cursor: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Window {
    pub messages: Vec<Message>,
    pub anchor: u64,
    pub older: Option<Position>,
    pub newer: Option<Position>,
    pub more_older: bool,
    pub more_newer: bool,
    pub leaf: Option<Rid>,
    pub older_cursor: String,
    pub newer_cursor: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct MessageReply {
    pub message: Message,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Xref {
    pub object: Option<Id>,
    pub msg: Option<Rid>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct CatalogRow {
    pub object: Option<ObjectRef>,
    pub kind: String,
    pub title: String,
    pub parent: Xref,
    pub workspace: Option<Id>,
    pub agent: Option<Id>,
    pub status: String,
    pub activity: u64,
    pub archived: bool,
    pub pinned: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct CatalogList {
    pub rows: Vec<CatalogRow>,
    pub more: bool,
    pub next: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct CatalogEntry {
    pub object: Option<ObjectRef>,
    pub kind: String,
    pub title: String,
    pub parent: Xref,
    pub workspace: Option<Id>,
    pub agent: Option<Id>,
    pub participants: Vec<Id>,
    pub status: String,
    pub activity: u64,
    pub archived: bool,
    pub pinned: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct CatalogGet {
    pub found: bool,
    pub entry: CatalogEntry,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Delta {
    pub kind: String,
    pub object: Option<ObjectRef>,
    pub rid: Option<Rid>,
    pub msg: Option<Rid>,
    pub record: u64,
    pub by: Option<Id>,
    pub local: bool,
    pub hlc: u64,
    pub role: String,
    pub index: u64,
    pub block: String,
    #[serde(default = "seal_open")]
    pub seal: String,
    #[serde(default = "status_idle")]
    pub status: String,
    pub usage: Usage,
    pub text: String,
    pub key: String,
    pub tag: u64,
    pub removed: bool,
    pub length: i64,
    pub draft: bool,
}

fn seal_open() -> String {
    "open".into()
}

fn status_idle() -> String {
    "idle".into()
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Deltas {
    pub deltas: Vec<Delta>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Event {
    pub kind: String,
    pub space: Option<Id>,
    pub object: Option<Id>,
    pub device: Option<Id>,
    pub tick: u64,
    pub length: i64,
    pub status: String,
    pub detail: String,
    pub state: String,
    pub msg: Option<Rid>,
    pub runner: Option<Id>,
    pub provider: String,
    pub since_ms: i64,
    pub last_runner: Option<Id>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Placement {
    pub state: String,
    pub msg: Option<Rid>,
    pub runner: Option<Id>,
    pub provider: String,
    pub since_ms: i64,
    pub last_runner: Option<Id>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Runner {
    pub device: Id,
    pub name: String,
    pub kind: String,
    pub state: String,
    pub providers: Vec<String>,
    pub signed_in: Vec<String>,
    pub current: bool,
    pub last: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Runners {
    pub runners: Vec<Runner>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct FileChange {
    pub mount: String,
    pub path: String,
    pub change: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct ForkDiff {
    pub changes: Vec<FileChange>,
    pub diff: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct TakeoverPolicy {
    pub policy: String,
    pub effective: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct LoginResult {
    pub path: String,
    pub status: String,
    pub code: String,
    pub spaces: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct AccountState {
    pub signed_in: bool,
    pub account: String,
    pub subject: String,
    pub pool: String,
    pub relay: String,
    pub waiting: bool,
    pub code: String,
    pub no_approver: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Approval {
    pub device: Option<Id>,
    pub code: String,
    pub label: String,
    pub at: i64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Approvals {
    pub approvals: Vec<Approval>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Salt {
    pub salt: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct SignedOut {
    pub spaces: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct SpaceLeft {
    pub removed: u64,
    pub skipped: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Receipt {
    pub receipt: String,
    pub msg: Option<Rid>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Match {
    pub start: u64,
    pub len: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Hit {
    pub object: Option<ObjectRef>,
    pub participant: Option<Id>,
    pub msg: Option<Rid>,
    #[serde(rename = "ref")]
    pub reference: String,
    pub part: u64,
    pub kind: String,
    pub title: bool,
    pub hlc: u64,
    pub score: f64,
    pub snippet: String,
    pub snippet_at: u64,
    pub matches: Vec<Match>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct SearchSource {
    pub device: Option<Id>,
    pub local: bool,
    pub state: String,
    pub behind: u64,
    pub hits: u64,
    pub rejected: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct SearchResults {
    pub hits: Vec<Hit>,
    pub cursor: String,
    pub incomplete: bool,
    pub verified: u64,
    pub partial: bool,
    pub behind: u64,
    pub sources: Vec<SearchSource>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Mounted {
    pub object: Option<ObjectRef>,
    pub root: String,
    pub line: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct MountedList {
    pub mounts: Vec<Mounted>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct TreeFind {
    pub object: Option<ObjectRef>,
    pub root: String,
    pub rel: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct RuntimeStats {
    pub runner: bool,
    pub active_runs: u64,
    pub warm_processes: u64,
    pub runs_started: u64,
    pub runs_finished: u64,
    pub evaluations: u64,
    pub spawns: u64,
    pub warm_hits: u64,
    pub raw_lines: u64,
    pub tool_calls: u64,
    pub schedules: u64,
    pub timers: u64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct State {
    pub default_space: Option<Id>,
    pub current: Option<ObjectRef>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Dir {
    #[default]
    Older,
    Newer,
}

impl Dir {
    pub fn name(self) -> &'static str {
        match self {
            Dir::Older => "older",
            Dir::Newer => "newer",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct PageArgs {
    pub from: Option<Rid>,
    pub limit: u64,
    pub dir: Dir,
    pub leaf: Option<Rid>,
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct RecordArgs {
    pub source: String,
    pub external_id: String,
    pub sequence: u64,
    pub role: String,
    pub parent: Option<Rid>,
    pub text: String,
    pub status: Option<String>,
    pub provider: String,
    pub model: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Register {
    pub tag: u64,
    pub hlc: u64,
    pub by: Option<Id>,
    pub value: String,
}

impl Register {
    pub fn bytes(&self) -> Vec<u8> {
        crate::codec::unhex(&self.value).unwrap_or_default()
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes()).into_owned()
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Element {
    pub tag: u64,
    pub value: String,
    pub live: u64,
}

impl Element {
    pub fn bytes(&self) -> Vec<u8> {
        crate::codec::unhex(&self.value).unwrap_or_default()
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Counter {
    pub tag: u64,
    pub value: i64,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Entry {
    pub key: String,
    pub registers: Vec<Register>,
    pub elements: Vec<Element>,
    pub counters: Vec<Counter>,
}

impl Entry {
    pub fn key_bytes(&self) -> Vec<u8> {
        crate::codec::unhex(&self.key).unwrap_or_default()
    }

    pub fn register(&self, tag: u64) -> Option<&Register> {
        self.registers.iter().filter(|r| r.tag == tag).max_by_key(|r| r.hlc).filter(|r| !r.value.is_empty())
    }

    pub fn elements(&self, tag: u64) -> impl Iterator<Item = &Element> {
        self.elements.iter().filter(move |e| e.tag == tag && e.live > 0)
    }

    pub fn counter(&self, tag: u64) -> i64 {
        self.counters.iter().find(|c| c.tag == tag).map(|c| c.value).unwrap_or(0)
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct MapGet {
    pub found: bool,
    pub entry: Entry,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct MapScan {
    pub rows: Vec<Entry>,
    pub more: bool,
    pub next: String,
}

#[derive(Debug, Clone)]
pub struct Field {
    pub tag: u64,
    pub value: Vec<u8>,
}

impl Field {
    pub fn bytes(tag: u64, value: &[u8]) -> Field {
        Field { tag, value: value.to_vec() }
    }

    pub fn text(tag: u64, value: &str) -> Field {
        Field { tag, value: value.as_bytes().to_vec() }
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Text {
    pub text: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Span {
    pub lo: u64,
    pub hi: u64,
    pub line_lo: u64,
    pub line_hi: u64,
    pub actor: Option<Id>,
    pub seq: u64,
    pub op_actor: Option<Id>,
    pub op_seq: u64,
    pub redacted: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Spans {
    pub spans: Vec<Span>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Blame {
    pub line: String,
    pub text: String,
    pub spans: Vec<Span>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct TreeList {
    pub names: Vec<String>,
    pub line: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct TreeText {
    pub text: String,
    pub line: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct TreeWritten {
    pub line: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct CatalogRows {
    pub rows: Vec<CatalogRow>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Device {
    pub device: Option<Id>,
    pub kind: String,
    pub method: String,
    pub spaces: u64,
    pub removed: bool,
    #[serde(rename = "self")]
    pub this_device: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Devices {
    pub devices: Vec<Device>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct SearchMode {
    pub mode: String,
}
