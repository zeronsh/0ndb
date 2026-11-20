//! Managed worktrees: git worktrees (or any folders) that 0ndb creates or
//! adopts, mounts, and keeps across restarts.
//!
//! Each managed worktree has its own history database under the manager's
//! state directory, so nothing but the small `.0ndb/` folder lands in the
//! checkout. Mounts hibernate when idle (see `MountOptions::idle_unload`),
//! so keeping many worktrees managed costs little until they're used.
//! Hosting-provider calls (change requests) go through [`Forges`], so any
//! provider registered there works.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ondb_core::{BatchId, BlobRef, FileMode, FileState, NodeKind, Version};
use ondb_git::{ChangeRequest, Checkout, Forges, NewChangeRequest, Repo, slugify};
use serde::{Deserialize, Serialize};

use crate::mount::disk;
use crate::{Error, Mount, MountHandle, MountOptions, Workspace};

/// Branches created for new worktrees are named `<prefix><slug>`.
pub const BRANCH_PREFIX: &str = "ondb/";

/// Binary content larger than this is streamed from git's objects when
/// forking, never held in memory.
const FORK_STREAM_BYTES: u64 = 8 << 20;

/// Where a forked worktree's files came from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForkOrigin {
    /// The worktree it was forked from.
    pub worktree: String,
    /// The version of that worktree its files were made from.
    pub version: Version,
    /// Its own history's heads right after the fork; while they still are,
    /// nothing has changed in it since.
    pub heads: Version,
    /// It replicates the source's history (same history id), so its work can
    /// be synced and landed back. False when the source's history was pruned
    /// past `version` and the fork had to start its own.
    #[serde(default)]
    pub shared: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeInfo {
    pub id: String,
    pub title: String,
    /// Where the files are.
    pub path: PathBuf,
    /// The repository's main checkout (for linked worktrees), if any.
    pub repo: Option<PathBuf>,
    /// Branch created for it, if 0ndb created one.
    pub branch: Option<String>,
    /// History database.
    pub db: PathBuf,
    /// 0ndb created the git worktree (so removing it removes the checkout).
    pub created: bool,
    pub created_ms: u64,
    /// Set when it was forked from another managed worktree.
    #[serde(default)]
    pub forked_from: Option<ForkOrigin>,
}

/// What a fork writes at one path.
enum Planned {
    Absent,
    Dir,
    Bytes(Vec<u8>, bool),
    /// Binary content streamed from git's objects.
    Stream(BlobRef, bool),
    Link(String),
}

struct Live {
    ws: Workspace,
    mount: Mount,
}

struct State {
    entries: Vec<WorktreeInfo>,
    live: HashMap<String, Live>,
}

/// Creates, adopts, mounts and removes worktrees.
#[derive(Clone)]
pub struct Worktrees {
    state_dir: PathBuf,
    checkouts_dir: PathBuf,
    opts: MountOptions,
    forges: Arc<Forges>,
    state: Arc<Mutex<State>>,
}

impl Worktrees {
    /// Opens the manager and remounts every worktree it manages. Entries
    /// whose folders are gone are dropped (and their git worktrees pruned).
    pub fn open(
        state_dir: impl AsRef<Path>,
        checkouts_dir: impl AsRef<Path>,
        opts: MountOptions,
        forges: Forges,
    ) -> Result<Worktrees, Error> {
        let state_dir = state_dir.as_ref().to_path_buf();
        fs::create_dir_all(state_dir.join("histories"))?;
        let entries: Vec<WorktreeInfo> = match fs::read(state_dir.join("worktrees.json")) {
            Ok(b) => serde_json::from_slice(&b).map_err(|e| Error::Invalid(format!("worktrees.json: {e}")))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.into()),
        };
        let wt = Worktrees {
            state_dir,
            checkouts_dir: checkouts_dir.as_ref().to_path_buf(),
            opts,
            forges: Arc::new(forges),
            state: Arc::new(Mutex::new(State { entries: Vec::new(), live: HashMap::new() })),
        };
        let mut kept = Vec::new();
        for e in entries {
            if !e.path.is_dir() {
                tracing::warn!(path = %e.path.display(), "managed worktree is gone; forgetting it");
                if let Some(repo) = e.repo.as_ref().and_then(|r| Repo::open(r).ok()) {
                    let _ = repo.prune_worktrees();
                }
                continue;
            }
            // Kept even when it can't be mounted now (e.g. another process
            // has it mounted); it just isn't live here.
            match wt.mount(&e) {
                Ok(live) => {
                    wt.lock().live.insert(e.id.clone(), live);
                }
                Err(err) => tracing::warn!(path = %e.path.display(), error = %err, "managed worktree not mounted here"),
            }
            kept.push(e);
        }
        wt.lock().entries = kept;
        wt.save()?;
        Ok(wt)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn save(&self) -> Result<(), Error> {
        let bytes = serde_json::to_vec_pretty(&self.lock().entries).map_err(|e| Error::Invalid(e.to_string()))?;
        let tmp = self.state_dir.join("worktrees.json.tmp");
        fs::write(&tmp, bytes)?;
        fs::rename(tmp, self.state_dir.join("worktrees.json"))?;
        Ok(())
    }

    fn mount(&self, e: &WorktreeInfo) -> Result<Live, Error> {
        let ws = Workspace::open(&e.db, None)?;
        let mount = Mount::start(&ws, &e.path, self.opts.clone())?;
        Ok(Live { ws, mount })
    }

    pub fn forges(&self) -> &Forges {
        &self.forges
    }

    /// Creates a git worktree of the repository containing `repo` on a new
    /// branch named after `title`, starting from `base` (default: the
    /// remote's default branch, else the current HEAD), and mounts it.
    pub fn create(&self, repo: impl AsRef<Path>, title: &str, base: Option<&str>) -> Result<WorktreeInfo, Error> {
        let repo = Repo::open(repo.as_ref())?;
        let main = main_checkout(&repo)?;
        let main_repo = Repo::open(&main)?;
        let branch = main_repo.unique_branch(BRANCH_PREFIX, title)?;
        let base = match base {
            Some(b) => b.to_string(),
            None => {
                let remote = main_repo.primary_remote(None)?;
                remote
                    .and_then(|r| main_repo.default_branch(&r.name).ok().flatten().map(|b| format!("{}/{b}", r.name)))
                    .unwrap_or_else(|| "HEAD".into())
            }
        };
        let repo_name = main.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "repo".into());
        let dir = self.checkouts_dir.join(slugify(&repo_name));
        fs::create_dir_all(&dir)?;
        let slug = branch.strip_prefix(BRANCH_PREFIX).unwrap_or(&branch).to_string();
        let path = dir.join(&slug);
        if path.exists() {
            return Err(Error::Invalid(format!("{} already exists", path.display())));
        }
        main_repo.add_worktree(&path, &Checkout::NewBranch { name: branch.clone(), base })?;
        let path = fs::canonicalize(&path)?;
        let info = self.register(title, path, Some(main), Some(branch), true, None)?;
        Ok(info)
    }

    /// A new worktree whose files are exactly `source`'s at `version`, then
    /// mounted; `source` is left untouched.
    ///
    /// * A git checkout gets a git worktree checked out as `checkout`;
    ///   uncommitted changes and untracked files are carried over,
    ///   git-ignored files aren't.
    /// * Any other folder (`checkout: None`) is cloned (copy-on-write where
    ///   the filesystem can), ignored files included.
    ///
    /// Either way only paths that can differ from that starting point are
    /// rewritten: those changed between the checkout's commit and
    /// `source`'s HEAD, dirty in `source`, or touched since `version`.
    /// The fork replicates `source`'s history up to `version`, so its work
    /// can later be synced and landed back (see `land.rs`); if that history
    /// was pruned, it starts a history of its own instead.
    pub fn fork(&self, source: &str, version: &Version, title: &str, checkout: Option<Checkout>) -> Result<WorktreeInfo, Error> {
        let src = self.get(source).ok_or_else(|| Error::Invalid(format!("no managed worktree {source}")))?;
        let (ws, mount) = self.workspace(&src.id).ok_or_else(|| Error::Invalid(format!("worktree {} isn't mounted", src.id)))?;
        mount.fence()?;
        let repo = match &checkout {
            Some(_) => Some(Repo::open(&src.path).map_err(|_| {
                Error::Invalid(format!("{} isn't a git checkout, so it can't get a git worktree", src.path.display()))
            })?),
            None => None,
        };
        // The mounted folder, relative to the repository's root.
        let prefix = match &repo {
            Some(repo) => src
                .path
                .strip_prefix(fs::canonicalize(repo.root())?)
                .map_err(|_| Error::Invalid(format!("{} is outside its repository", src.path.display())))?
                .to_string_lossy()
                .into_owned(),
            None => String::new(),
        };
        let under = |p: String| -> Option<String> {
            let rel = if prefix.is_empty() { Some(p) } else { p.strip_prefix(&format!("{prefix}/")).map(str::to_string) }?;
            (!disk::is_internal(&rel)).then_some(rel)
        };
        let mut paths = BTreeSet::new();
        if let (Some(repo), Some(checkout)) = (&repo, &checkout) {
            let rev = match checkout {
                Checkout::NewBranch { base, .. } => base,
                Checkout::Branch(b) => b,
                Checkout::Detached(r) => r,
            };
            let commit = repo.resolve(rev)?.ok_or_else(|| Error::Invalid(format!("{rev} isn't a commit here")))?;
            if let Some(head) = repo.head()?.oid
                && head != commit
            {
                paths.extend(repo.changed_paths(&commit, &head)?.into_iter().filter_map(under));
            }
            paths.extend(repo.dirty_paths()?.into_iter().filter_map(under));
        }
        let missing: Vec<BatchId> = ws.batches_missing_from(version)?.iter().map(|b| b.id()).collect();
        let plan = ws.with(|ctx| -> Result<Vec<(String, Planned)>, Error> {
            let touched = ctx.touched_by(missing.iter().copied())?;
            let h = ctx.history();
            let excluded = h.exclusions_for(version);
            let (then, now, tree) = (h.excluding(&excluded), h.current(), h.tree());
            for i in &touched {
                paths.extend([tree.path_of(&now, i), tree.path_of(&then, i)].into_iter().flatten().filter_map(under));
            }
            let mut plan = Vec::with_capacity(paths.len());
            for p in paths {
                let Some(i) = tree.lookup(&then, &p) else {
                    plan.push((p, Planned::Absent));
                    continue;
                };
                let item = match h.inode(&i).map(|n| &n.kind) {
                    Some(NodeKind::Dir) => Planned::Dir,
                    Some(NodeKind::Symlink { .. }) => h.symlink_target(&then, &i).map_or(Planned::Absent, Planned::Link),
                    Some(NodeKind::File(_)) => match h.file_state(&then, &i) {
                        Some(FileState::Text { bytes, ending, mode }) => {
                            Planned::Bytes(disk::smudge(&bytes, ending), mode == FileMode::Executable)
                        }
                        Some(FileState::Binary { blob, mode }) => {
                            let exec = mode == FileMode::Executable;
                            match (blob.len <= FORK_STREAM_BYTES).then(|| ctx.blob(&blob.oid)).transpose()?.flatten() {
                                Some(bytes) => Planned::Bytes(bytes, exec),
                                None => Planned::Stream(blob, exec),
                            }
                        }
                        None => Planned::Absent,
                    },
                    None => Planned::Absent,
                };
                plan.push((p, item));
            }
            Ok(plan)
        })?;

        // Where the copy goes: <checkouts>/<repository or folder>/<title>.
        let main = repo.as_ref().map(main_checkout).transpose()?;
        let home = main.as_deref().unwrap_or(&src.path);
        let group = home.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "folder".into());
        let dir = self.checkouts_dir.join(slugify(&group));
        fs::create_dir_all(&dir)?;
        let slug = slugify(title);
        let mut checkout_path = dir.join(&slug);
        for n in 2.. {
            if !checkout_path.exists() {
                break;
            }
            checkout_path = dir.join(format!("{slug}-{n}"));
        }
        let main_repo = main.as_ref().map(Repo::open).transpose()?;
        let undo = |path: &Path| match &main_repo {
            Some(r) => drop(r.remove_worktree(path, true)),
            None => drop(fs::remove_dir_all(path)),
        };
        match (&main_repo, &checkout) {
            (Some(r), Some(c)) => drop(r.add_worktree(&checkout_path, c)?),
            _ => clone_dir(&src.path, &checkout_path)?,
        }
        let checkout_path = fs::canonicalize(&checkout_path)?;
        let root = if prefix.is_empty() { checkout_path.clone() } else { checkout_path.join(&prefix) };
        let dest_repo = main_repo.as_ref().map(|_| Repo::open(&checkout_path)).transpose()?;
        if let Err(e) = write_plan(&root, &plan, dest_repo.as_ref()) {
            undo(&checkout_path);
            return Err(e);
        }
        let id = new_worktree_id();
        let db = self.db_path(&id);
        let shared = match replicate(&ws, version, &db, dest_repo.as_ref(), &id) {
            Ok(shared) => shared,
            Err(e) => {
                undo(&checkout_path);
                return Err(e);
            }
        };
        let branch = match checkout {
            Some(Checkout::NewBranch { name, .. } | Checkout::Branch(name)) => Some(name),
            _ => None,
        };
        let origin = ForkOrigin { worktree: src.id.clone(), version: version.clone(), heads: Version::root(), shared };
        let mut info = self.register_as(id, title, root, main, branch, true, Some(origin))?;
        // The mount's first pass took in the files; remember the heads it
        // left, so an unchanged fork can be reused.
        if let Some((ws, mount)) = self.workspace(&info.id) {
            mount.fence()?;
            let heads = ws.heads();
            let mut st = self.lock();
            if let Some(e) = st.entries.iter_mut().find(|e| e.id == info.id)
                && let Some(o) = e.forked_from.as_mut()
            {
                o.heads = heads;
                info = e.clone();
            }
        }
        self.save()?;
        Ok(info)
    }

    /// Manages an existing folder (a main checkout, a worktree made
    /// elsewhere, or a plain directory) without creating anything.
    pub fn adopt(&self, path: impl AsRef<Path>, title: &str) -> Result<WorktreeInfo, Error> {
        let path = fs::canonicalize(path.as_ref())?;
        if let Some(e) = self.lock().entries.iter().find(|e| e.path == path) {
            return Ok(e.clone());
        }
        let main = Repo::open(&path).ok().and_then(|r| main_checkout(&r).ok());
        self.register(title, path, main, None, false, None)
    }

    /// A new, empty folder for a chat that has none of its own, managed like
    /// any other (so whatever the agent makes there is tracked and can be
    /// undone or forked).
    pub fn scratch(&self, title: &str) -> Result<WorktreeInfo, Error> {
        let id = new_worktree_id();
        let path = self.checkouts_dir.join("scratch").join(format!("{}-{}", slugify(title), &id[..6]));
        fs::create_dir_all(&path)?;
        let path = fs::canonicalize(&path)?;
        self.register_as(id, title, path, None, None, true, None)
    }

    fn register(
        &self,
        title: &str,
        path: PathBuf,
        repo: Option<PathBuf>,
        branch: Option<String>,
        created: bool,
        forked_from: Option<ForkOrigin>,
    ) -> Result<WorktreeInfo, Error> {
        self.register_as(new_worktree_id(), title, path, repo, branch, created, forked_from)
    }

    fn db_path(&self, id: &str) -> PathBuf {
        self.state_dir.join("histories").join(format!("{id}.db"))
    }

    #[allow(clippy::too_many_arguments)]
    fn register_as(
        &self,
        id: String,
        title: &str,
        path: PathBuf,
        repo: Option<PathBuf>,
        branch: Option<String>,
        created: bool,
        forked_from: Option<ForkOrigin>,
    ) -> Result<WorktreeInfo, Error> {
        let info = WorktreeInfo {
            db: self.db_path(&id),
            id,
            title: title.to_string(),
            path,
            repo,
            branch,
            created,
            created_ms: ondb_core::now_ms(),
            forked_from,
        };
        let live = self.mount(&info)?;
        {
            let mut st = self.lock();
            st.live.insert(info.id.clone(), live);
            st.entries.push(info.clone());
        }
        self.save()?;
        Ok(info)
    }

    pub fn list(&self) -> Vec<WorktreeInfo> {
        self.lock().entries.clone()
    }

    pub fn get(&self, id: &str) -> Option<WorktreeInfo> {
        self.lock().entries.iter().find(|e| e.id == id || e.path.as_os_str() == id).cloned()
    }

    /// The worktree's history and mount, for recording and attribution.
    pub fn workspace(&self, id: &str) -> Option<(Workspace, MountHandle)> {
        self.lock().live.get(id).map(|l| (l.ws.clone(), l.mount.handle()))
    }

    /// Stops managing a worktree: unmounts it and deletes its history. For
    /// worktrees 0ndb created, also removes the git worktree (refusing when
    /// it has uncommitted changes unless `force`) and, with
    /// `delete_branch`, its branch; a folder 0ndb created outside git
    /// (a scratch folder or a plain folder's fork) is deleted, refusing
    /// when it holds files unless `force`.
    pub fn remove(&self, id: &str, force: bool, delete_branch: bool) -> Result<(), Error> {
        let info = self.get(id).ok_or_else(|| Error::Invalid(format!("no managed worktree {id}")))?;
        let repo = Repo::open(&info.path).ok();
        if info.created && !force {
            let busy = match &repo {
                Some(repo) => !repo.status()?.is_clean(),
                None => fs::read_dir(&info.path)?.flatten().any(|e| e.file_name() != crate::mount::STATE_DIR),
            };
            if busy {
                return Err(Error::Invalid(format!(
                    "{} has {}",
                    info.path.display(),
                    if repo.is_some() { "uncommitted changes" } else { "files in it" }
                )));
            }
        }
        if let Some(live) = self.lock().live.remove(&info.id) {
            live.mount.stop();
            drop(live.ws);
        }
        if info.created && repo.is_none() {
            fs::remove_dir_all(&info.path)?;
        }
        if info.created
            && let Some(main) = info.repo.as_ref().and_then(|r| Repo::open(r).ok())
        {
            // A fork of a subfolder is mounted below its checkout's root.
            let checkout = Repo::open(&info.path).map(|r| r.root().to_path_buf()).unwrap_or_else(|_| info.path.clone());
            main.remove_worktree(&checkout, true)?;
            if delete_branch && let Some(b) = &info.branch {
                main.delete_branch(b, true)?;
            }
        }
        for suffix in ["", "-wal", "-shm"] {
            let _ = fs::remove_file(format!("{}{suffix}", info.db.display()));
        }
        self.lock().entries.retain(|e| e.id != info.id);
        self.save()
    }

    /// The change request (pull/merge request) for the worktree's branch,
    /// from whichever provider hosts its remote.
    pub fn change_request(&self, id: &str) -> Result<Option<ChangeRequest>, Error> {
        let (_, branch, remote) = self.branch_and_remote(id)?;
        let forge = self.forges.for_remote(&remote)?;
        Ok(forge.change_request_for_branch(&remote, &branch, None)?)
    }

    /// Pushes the worktree's branch and opens a change request against the
    /// remote's default branch (or `base`).
    pub fn open_change_request(
        &self,
        id: &str,
        title: &str,
        body: &str,
        base: Option<&str>,
        draft: bool,
    ) -> Result<ChangeRequest, Error> {
        let (repo, branch, remote) = self.branch_and_remote(id)?;
        let forge = self.forges.for_remote(&remote)?;
        let remote_name = repo.primary_remote(Some(&branch))?.map(|r| r.name).unwrap_or_else(|| "origin".into());
        repo.push(&remote_name, &branch, true)?;
        let base = match base {
            Some(b) => b.to_string(),
            None => repo
                .default_branch(&remote_name)?
                .or_else(|| forge.repository(&remote).ok().and_then(|r| r.default_branch))
                .ok_or_else(|| Error::Invalid("can't tell the default branch; pass a base".into()))?,
        };
        let req = NewChangeRequest { title: title.into(), body: body.into(), head: branch, base, draft };
        Ok(forge.create_change_request(&remote, &req)?)
    }

    fn branch_and_remote(&self, id: &str) -> Result<(Repo, String, ondb_git::RemoteUrl), Error> {
        let info = self.get(id).ok_or_else(|| Error::Invalid(format!("no managed worktree {id}")))?;
        let repo = Repo::open(&info.path)?;
        let branch = repo.head()?.branch.ok_or_else(|| Error::Invalid("detached HEAD has no change request".into()))?;
        let remote = repo
            .primary_remote(Some(&branch))?
            .and_then(|r| r.parsed)
            .ok_or_else(|| Error::Invalid("no hosted remote".into()))?;
        Ok((repo, branch, remote))
    }
}

fn new_worktree_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..12].to_string()
}

/// Creates the fork's history at `db`: a replica of `source`'s history cut
/// at `version` (same history id, so batches flow between the two). Returns
/// false, leaving no database behind, when that history can't be replicated
/// (batches older than `version` were pruned); the fork then starts its own.
fn replicate(source: &Workspace, version: &Version, db: &Path, repo: Option<&Repo>, fork_id: &str) -> Result<bool, Error> {
    let excluded = source.read(|h| h.exclusions_for(version));
    let batches: Vec<_> =
        source.batches_missing_from(&Version::root())?.into_iter().filter(|b| !excluded.contains(&b.id())).collect();
    let replica = Workspace::open(db, Some(source.id()))?;
    if let Some(repo) = repo {
        // Content held in git's objects stays readable, pinned under a ref
        // of the fork's own (the mount keeps it).
        let pin = format!("refs/0ndb/{}-{fork_id}", source.id());
        let common = repo.common_dir().to_string_lossy().into_owned();
        replica.with(|c| {
            let (store, key) = c.store();
            store.set_external_record(key, "git", &common, &pin)
        })?;
    }
    let report = replica.integrate(batches)?;
    if report.rejected.is_empty() && report.waiting.is_empty() && replica.heads() == *version {
        return Ok(true);
    }
    tracing::warn!(
        rejected = report.rejected.len(),
        waiting = report.waiting.len(),
        "fork can't replicate its source's history; starting its own"
    );
    drop(replica);
    for suffix in ["", "-wal", "-shm"] {
        let _ = fs::remove_file(format!("{}{suffix}", db.display()));
    }
    Ok(false)
}

/// Copies a folder, copy-on-write where the filesystem can (APFS clones,
/// btrfs/XFS reflinks), without 0ndb's own state folder.
fn clone_dir(from: &Path, to: &Path) -> Result<(), Error> {
    let (src, dst) = (from.to_string_lossy().into_owned(), to.to_string_lossy().into_owned());
    let attempts: &[&[&str]] =
        if cfg!(target_os = "macos") { &[&["-cR"], &["-R"]] } else { &[&["-R", "--reflink=auto"], &["-R"]] };
    let mut last = String::new();
    for flags in attempts {
        let _ = fs::remove_dir_all(to);
        let out = std::process::Command::new("cp").args(*flags).arg(&src).arg(&dst).output()?;
        if out.status.success() {
            let _ = fs::remove_dir_all(to.join(crate::mount::STATE_DIR));
            return Ok(());
        }
        last = String::from_utf8_lossy(&out.stderr).trim().to_string();
    }
    let _ = fs::remove_dir_all(to);
    Err(Error::Invalid(format!("couldn't copy {} to {}: {last}", from.display(), to.display())))
}

/// Lays a fork's planned paths onto its fresh copy: removals deepest first,
/// then everything else parents first.
fn write_plan(root: &Path, plan: &[(String, Planned)], repo: Option<&Repo>) -> Result<(), Error> {
    for (p, _) in plan.iter().rev().filter(|(_, w)| matches!(w, Planned::Absent)) {
        match disk::remove(root, p) {
            Err(e) if e.kind() == std::io::ErrorKind::NotADirectory => {}
            r => r?,
        }
    }
    let mut objects = None;
    for (p, item) in plan {
        match item {
            Planned::Absent => {}
            Planned::Dir => {
                let abs = disk::abs(root, p);
                if fs::symlink_metadata(&abs).is_ok_and(|m| !m.is_dir()) {
                    fs::remove_file(&abs)?;
                }
                fs::create_dir_all(abs)?;
            }
            Planned::Bytes(bytes, exec) => {
                disk::write_atomic(root, p, bytes, *exec)?;
            }
            Planned::Stream(blob, exec) => {
                let Some(repo) = repo else {
                    return Err(Error::Invalid(format!("{p}: its content isn't available locally")));
                };
                let objects = objects.get_or_insert_with(|| ondb_git::Objects::open(repo.common_dir()));
                disk::write_atomic_with(root, p, *exec, |f| {
                    let n = objects.copy_to(&blob.oid.0, f)?;
                    if n == blob.len { Ok(()) } else { Err(std::io::Error::other(format!("{p}: content missing from git"))) }
                })?;
            }
            Planned::Link(target) => disk::write_symlink(root, p, target)?,
        }
    }
    Ok(())
}

/// The main checkout of the repository `repo` belongs to.
fn main_checkout(repo: &Repo) -> Result<PathBuf, Error> {
    let wts = repo.worktrees()?;
    Ok(wts.into_iter().find(|w| !w.bare).map(|w| w.path).unwrap_or_else(|| repo.root().to_path_buf()))
}
