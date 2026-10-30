//! Filesystem watching.
//!
//! * **Tree** (macOS, Windows): one recursive OS watch per mount. FSEvents
//!   and `ReadDirectoryChangesW` cover a whole tree kernel-side for the price
//!   of one stream.
//! * **Dirs** (Linux): inotify watches single directories, and instances are
//!   scarce (128 per user by default). Every mount in the process shares one
//!   watcher instance and watches only directories it tracks, so ignored
//!   trees (`node_modules`, `target`) cost no watches at all. Directories are
//!   followed as they appear, move and disappear.
//!
//! `ONDB_WATCH=tree|dirs` overrides the default (diagnostics; Dirs relies on
//! inotify's semantics and is only meant for Linux).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use crossbeam_channel::Sender;
use notify::event::{Flag, ModifyKind};
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};

use super::disk::{self, STATE_DIR};
use super::git::GitDirs;
use super::ignore::{Ignore, walker};
use crate::Error;

pub(crate) type EventTx = Sender<notify::Result<Event>>;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Tree,
    Dirs,
}

fn kind() -> Kind {
    match std::env::var("ONDB_WATCH").as_deref() {
        Ok("tree") => Kind::Tree,
        Ok("dirs") => Kind::Dirs,
        _ if cfg!(target_os = "linux") => Kind::Dirs,
        _ => Kind::Tree,
    }
}

pub(crate) struct Watch {
    mode: Mode,
}

enum Mode {
    Tree(#[allow(dead_code)] RecommendedWatcher),
    Dirs { hub: Arc<Hub>, id: u64, watched: HashSet<PathBuf>, refs: Option<PathBuf> },
}

impl Watch {
    /// Starts watching `root` plus the git directories that live outside it.
    pub fn start(root: &Path, git: Option<&GitDirs>, ignore: &Ignore, tx: EventTx) -> Result<Watch, Error> {
        match kind() {
            Kind::Tree => {
                let mut w = notify::recommended_watcher(move |res| {
                    let _ = tx.send(res);
                })?;
                w.watch(root, RecursiveMode::Recursive)?;
                for (dir, recursive) in git.iter().flat_map(|g| g.external_watches(root)) {
                    let mode = if recursive { RecursiveMode::Recursive } else { RecursiveMode::NonRecursive };
                    if let Err(e) = w.watch(&dir, mode) {
                        tracing::warn!(dir = %dir.display(), "can't watch git dir: {e}");
                    }
                }
                Ok(Watch { mode: Mode::Tree(w) })
            }
            Kind::Dirs => {
                static IDS: AtomicU64 = AtomicU64::new(1);
                let hub = Hub::shared()?;
                let id = IDS.fetch_add(1, Ordering::Relaxed);
                hub.register(id, tx);
                let refs = git.map(|g| g.common.join("refs"));
                let mut w = Watch { mode: Mode::Dirs { hub, id, watched: HashSet::new(), refs: refs.clone() } };
                w.watch_tree(root, Some((root, ignore)));
                w.watch_one(&root.join(STATE_DIR).join("fences"));
                if let Some(g) = git {
                    w.watch_one(&g.dir);
                    w.watch_one(&g.common);
                    if let Some(refs) = &refs {
                        w.watch_tree(refs, None);
                    }
                }
                Ok(w)
            }
        }
    }

    /// Dirs mode: follows directories created, moved or removed by `event`.
    pub fn follow(&mut self, root: &Path, ignore: &Ignore, event: &Event) {
        let Mode::Dirs { watched, refs, .. } = &self.mode else { return };
        if !matches!(
            event.kind,
            EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(ModifyKind::Name(_)) | EventKind::Any
        ) {
            return;
        }
        let refs = refs.clone();
        let mut add = Vec::new();
        let mut drop = Vec::new();
        for p in &event.paths {
            let in_refs = refs.as_ref().is_some_and(|r| p.starts_with(r));
            if !in_refs && !p.starts_with(root) {
                continue;
            }
            if p.is_dir() {
                if !watched.contains(p) {
                    add.push((p.clone(), in_refs));
                }
            } else if watched.contains(p) {
                drop.push(p.clone());
            }
        }
        for p in drop {
            self.unwatch_under(&p);
        }
        for (p, in_refs) in add {
            if in_refs {
                self.watch_tree(&p, None);
            } else if let Ok(rel) = p.strip_prefix(root) {
                let rel = rel.to_string_lossy();
                if !disk::is_internal(&rel) && !ignore.is_ignored(&rel, true) {
                    self.watch_tree(&p, Some((root, ignore)));
                }
            }
        }
    }

    /// Dirs mode: after ignore rules change, watches directories that are no
    /// longer ignored. (Newly ignored ones stay watched; their events are
    /// filtered.)
    pub fn resync(&mut self, root: &Path, ignore: &Ignore) {
        if matches!(self.mode, Mode::Dirs { .. }) {
            self.watch_tree(root, Some((root, ignore)));
        }
    }

    /// Watches `dir` and every directory below it (ignore-aware when
    /// `tracked` gives the mount root and rules).
    fn watch_tree(&mut self, dir: &Path, tracked: Option<(&Path, &Ignore)>) {
        let mut dirs = vec![dir.to_path_buf()];
        let mut w = walker(dir);
        if tracked.is_none() {
            w.git_ignore(false).git_exclude(false).ignore(false).filter_entry(|_| true);
        }
        for e in w.build().flatten() {
            if !e.file_type().is_some_and(|t| t.is_dir()) || e.path() == dir {
                continue;
            }
            if let Some((root, ignore)) = tracked
                && let Ok(rel) = e.path().strip_prefix(root)
                && ignore.is_ignored(&rel.to_string_lossy(), true)
            {
                continue;
            }
            dirs.push(e.path().to_path_buf());
        }
        for d in dirs {
            self.watch_one(&d);
        }
    }

    fn watch_one(&mut self, dir: &Path) {
        let Mode::Dirs { hub, id, watched, .. } = &mut self.mode else { return };
        if !dir.is_dir() || !watched.insert(dir.to_path_buf()) {
            return;
        }
        if let Err(e) = hub.watch(dir, *id) {
            watched.remove(dir);
            tracing::warn!(dir = %dir.display(), "can't watch directory: {e}");
        }
    }

    fn unwatch_under(&mut self, dir: &Path) {
        let Mode::Dirs { hub, id, watched, .. } = &mut self.mode else { return };
        let gone: Vec<PathBuf> = watched.iter().filter(|w| w.starts_with(dir)).cloned().collect();
        for g in gone {
            watched.remove(&g);
            hub.unwatch(&g, *id);
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        if let Mode::Dirs { hub, id, watched, .. } = &mut self.mode {
            for d in watched.drain() {
                hub.unwatch(&d, *id);
            }
            hub.deregister(*id);
        }
    }
}

/// One OS watcher shared by every mount in the process (Dirs mode).
struct Hub {
    watcher: Mutex<Box<dyn Watcher + Send>>,
    state: Arc<RwLock<Routes>>,
}

#[derive(Default)]
struct Routes {
    /// Watched directory -> mounts interested in it.
    dirs: HashMap<PathBuf, Vec<u64>>,
    sinks: HashMap<u64, EventTx>,
}

impl Hub {
    fn shared() -> Result<Arc<Hub>, Error> {
        static HUB: OnceLock<Arc<Hub>> = OnceLock::new();
        if let Some(h) = HUB.get() {
            return Ok(h.clone());
        }
        let state: Arc<RwLock<Routes>> = Arc::default();
        let routes = state.clone();
        let handler = move |res: notify::Result<Event>| route(&routes, res);
        let watcher: Box<dyn Watcher + Send> = Box::new(notify::recommended_watcher(handler)?);
        let hub = Arc::new(Hub { watcher: Mutex::new(watcher), state });
        Ok(HUB.get_or_init(|| hub).clone())
    }

    fn register(&self, id: u64, tx: EventTx) {
        self.state.write().unwrap_or_else(|p| p.into_inner()).sinks.insert(id, tx);
    }

    fn deregister(&self, id: u64) {
        self.state.write().unwrap_or_else(|p| p.into_inner()).sinks.remove(&id);
    }

    fn watch(&self, dir: &Path, id: u64) -> notify::Result<()> {
        // Routes are updated before (and never while) calling into the
        // watcher: its event thread takes the routes lock to deliver.
        let first = {
            let mut st = self.state.write().unwrap_or_else(|p| p.into_inner());
            let ids = st.dirs.entry(dir.to_path_buf()).or_default();
            ids.push(id);
            ids.len() == 1
        };
        if first {
            let r = self.watcher.lock().unwrap_or_else(|p| p.into_inner()).watch(dir, RecursiveMode::NonRecursive);
            if r.is_err() {
                self.drop_route(dir, id);
            }
            return r;
        }
        Ok(())
    }

    fn unwatch(&self, dir: &Path, id: u64) {
        if self.drop_route(dir, id) {
            let _ = self.watcher.lock().unwrap_or_else(|p| p.into_inner()).unwatch(dir);
        }
    }

    /// Removes one interest; returns whether the directory has none left.
    fn drop_route(&self, dir: &Path, id: u64) -> bool {
        let mut st = self.state.write().unwrap_or_else(|p| p.into_inner());
        let Some(ids) = st.dirs.get_mut(dir) else { return false };
        if let Some(i) = ids.iter().position(|x| *x == id) {
            ids.swap_remove(i);
        }
        if ids.is_empty() {
            st.dirs.remove(dir);
            return true;
        }
        false
    }
}

/// Delivers an event to every mount watching the directory it happened in
/// (or that directory itself). Overflows and errors reach every mount as a
/// rescan request.
fn route(routes: &RwLock<Routes>, res: notify::Result<Event>) {
    let st = routes.read().unwrap_or_else(|p| p.into_inner());
    let ev = match res {
        Ok(ev) if !ev.paths.is_empty() && !ev.need_rescan() => ev,
        Ok(_) | Err(_) => {
            let rescan = Event::new(EventKind::Other).set_flag(Flag::Rescan);
            for tx in st.sinks.values() {
                let _ = tx.send(Ok(rescan.clone()));
            }
            return;
        }
    };
    let mut sent: Vec<u64> = Vec::new();
    for p in &ev.paths {
        for dir in [Some(p.as_path()), p.parent()].into_iter().flatten() {
            for id in st.dirs.get(dir).into_iter().flatten() {
                if !sent.contains(id) {
                    sent.push(*id);
                    if let Some(tx) = st.sinks.get(id) {
                        let _ = tx.send(Ok(ev.clone()));
                    }
                }
            }
        }
    }
}
