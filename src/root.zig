pub const core = struct {
    pub const id = @import("core/id.zig");
    pub const version = @import("core/version.zig");
    pub const dag = @import("core/dag.zig");
    pub const diff = @import("core/diff.zig");
    pub const text = @import("core/text.zig");
    pub const tree = @import("core/tree.zig");
    pub const op = @import("core/op.zig");
    pub const history = @import("core/history.zig");
};

pub const store = struct {
    pub const mmap = @import("store/mmap.zig");
    pub const lru = @import("store/lru.zig");
    pub const manifest = @import("store/manifest.zig");
    pub const segments = @import("store/segments.zig");
    pub const codec = @import("store/codec.zig");
    pub const crypto = @import("store/crypto.zig");
    pub const log = @import("store/log.zig");
    pub const blobs = @import("store/blobs.zig");
    pub const shadow = @import("store/shadow.zig");
};

pub const fs = struct {
    pub const git = @import("fs/git.zig");
    pub const git_dirs = @import("fs/git_dirs.zig");
    pub const git_index = @import("fs/git_index.zig");
    pub const git_odb = @import("fs/git_odb.zig");
    pub const vcs = @import("fs/vcs.zig");
    pub const watch = @import("fs/watch.zig");
    pub const workspace = @import("fs/workspace.zig");
    pub const worktrees = @import("fs/worktrees.zig");
    pub const pool = @import("fs/pool.zig");
    pub const timeline = @import("fs/timeline.zig");
    pub const git_remote = @import("fs/git_remote.zig");
};

pub const providers = struct {
    pub const interface = @import("providers/interface.zig");
    pub const json_rpc = @import("providers/json_rpc.zig");
    pub const claude = @import("providers/claude.zig");
    pub const codex = @import("providers/codex.zig");
    pub const pi = @import("providers/pi.zig");
    pub const muse = @import("providers/muse.zig");
    pub const acp = @import("providers/acp.zig");
    pub const models = @import("providers/models.zig");
    pub const pool = @import("providers/pool.zig");
    pub const registry = @import("providers/registry.zig");
};

pub const session = struct {
    pub const model = @import("session/model.zig");
    pub const pager = @import("session/pager.zig");
    pub const journal = @import("session/journal.zig");
    pub const engine = @import("session/engine.zig");
};

pub const sync = struct {
    pub const wire = @import("sync/wire.zig");
    pub const relay = @import("sync/relay.zig");
    pub const client = @import("sync/client.zig");
};

pub const playground = struct {
    pub const server = @import("playground/server.zig");
};

pub const thread = struct {
    pub const model = @import("thread/model.zig");
    pub const store = @import("thread/store.zig");
};
