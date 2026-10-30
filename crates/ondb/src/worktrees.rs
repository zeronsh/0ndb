//! Managed worktrees: git worktrees (or any folders) that 0ndb creates or
//! adopts, mounts, and keeps across restarts.
//!
//! Each managed worktree has its own history database under the manager's
//! state directory, so nothing but the small `.0ndb/` folder lands in the
//! checkout. Mounts hibernate when idle (see `MountOptions::idle_unload`),
//! so keeping many worktrees managed costs little until they're used.
//! Hosting-provider calls (change requests) go through [`Forges`], so any
//! provider registered there works.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ondb_git::{ChangeRequest, Checkout, Forges, NewChangeRequest, Repo, slugify};
use serde::{Deserialize, Serialize};

use crate::{Error, Mount, MountHandle, MountOptions, Workspace};

/// Branches created for new worktrees are named `<prefix><slug>`.
pub const BRANCH_PREFIX: &str = "ondb/";

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
        let info = self.register(title, path, Some(main), Some(branch), true)?;
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
        self.register(title, path, main, None, false)
    }

    fn register(
        &self,
        title: &str,
        path: PathBuf,
        repo: Option<PathBuf>,
        branch: Option<String>,
        created: bool,
    ) -> Result<WorktreeInfo, Error> {
        let id = uuid::Uuid::new_v4().simple().to_string()[..12].to_string();
        let info = WorktreeInfo {
            db: self.state_dir.join("histories").join(format!("{id}.db")),
            id,
            title: title.to_string(),
            path,
            repo,
            branch,
            created,
            created_ms: ondb_core::now_ms(),
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
    /// `delete_branch`, its branch.
    pub fn remove(&self, id: &str, force: bool, delete_branch: bool) -> Result<(), Error> {
        let info = self.get(id).ok_or_else(|| Error::Invalid(format!("no managed worktree {id}")))?;
        if info.created
            && !force
            && let Ok(repo) = Repo::open(&info.path)
            && !repo.status()?.is_clean()
        {
            return Err(Error::Invalid(format!("{} has uncommitted changes", info.path.display())));
        }
        if let Some(live) = self.lock().live.remove(&info.id) {
            live.mount.stop();
            drop(live.ws);
        }
        if info.created
            && let Some(main) = info.repo.as_ref().and_then(|r| Repo::open(r).ok())
        {
            main.remove_worktree(&info.path, true)?;
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

/// The main checkout of the repository `repo` belongs to.
fn main_checkout(repo: &Repo) -> Result<PathBuf, Error> {
    let wts = repo.worktrees()?;
    Ok(wts.into_iter().find(|w| !w.bare).map(|w| w.path).unwrap_or_else(|| repo.root().to_path_buf()))
}
