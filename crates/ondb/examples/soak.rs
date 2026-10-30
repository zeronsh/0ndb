//! Soak test: many cycles of edit -> attributed scope -> branch switch ->
//! hibernate -> wake across several git worktrees in one process. Fails if
//! live heap, open files or threads grow.
//!
//! `cargo run --release -p ondb --example soak -- [worktrees] [cycles]`

use std::alloc::{GlobalAlloc, Layout, System};
use std::fs;
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::time::{Duration, Instant};

use ondb::{ActorKind, Mount, MountOptions, Recorder, ScopeKind, Workspace};

struct Counting;
static LIVE: AtomicIsize = AtomicIsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(l) };
        if !p.is_null() {
            LIVE.fetch_add(l.size() as isize, Ordering::Relaxed);
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) };
        LIVE.fetch_sub(l.size() as isize, Ordering::Relaxed);
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let q = unsafe { System.realloc(p, l, new) };
        if !q.is_null() {
            LIVE.fetch_add(new as isize - l.size() as isize, Ordering::Relaxed);
        }
        q
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn sh(dir: &Path, script: &str) {
    let ok = Command::new("sh").arg("-c").arg(script).current_dir(dir).status().unwrap().success();
    assert!(ok, "{script}");
}

fn fds() -> usize {
    fs::read_dir("/dev/fd").map(|d| d.count()).unwrap_or(0)
}

fn threads() -> usize {
    let pid = std::process::id().to_string();
    let out = Command::new("ps").args(["-M", "-p", &pid]).output().map(|o| o.stdout).unwrap_or_default();
    String::from_utf8_lossy(&out).lines().count().saturating_sub(1)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let n: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(8);
    let cycles: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(200);
    let dir = tempfile::tempdir().unwrap();
    let git = "git -c user.name=t -c user.email=t@t";
    let src = dir.path().join("src");
    fs::create_dir_all(&src).unwrap();
    sh(&src, &format!("{git} init -q -b main"));
    for i in 0..200 {
        fs::create_dir_all(src.join(format!("mod{}", i % 20))).unwrap();
        fs::write(src.join(format!("mod{}/f{i}.rs", i % 20)), format!("pub fn f{i}() -> u32 {{ {i} }}\n").repeat(20)).unwrap();
    }
    sh(
        &src,
        &format!(
            "{git} add -A && {git} commit -qm base && {git} branch side && {git} checkout -q side && echo side >> mod0/f0.rs && {git} commit -qam side && {git} checkout -q main"
        ),
    );
    let opts = MountOptions { idle_unload: Some(Duration::from_millis(150)), ..MountOptions::default() };
    let mut set = Vec::new();
    for i in 0..n {
        let root = dir.path().join(format!("wt{i}"));
        sh(&src, &format!("{git} worktree add -q --detach {}", root.display()));
        let ws = Workspace::open(dir.path().join(format!("{i}.db")), None).unwrap();
        let mount = Mount::start(&ws, &root, opts.clone()).unwrap();
        let agent = ws.actor("soak", ActorKind::Agent).unwrap();
        set.push((ws, mount, root, agent));
    }
    let t = Instant::now();
    let mut samples = Vec::new();
    for cycle in 0..cycles {
        for (ws, mount, root, agent) in &set {
            let rec = Recorder::new(ws, vec![mount.handle()]).unwrap();
            rec.scoped(ScopeKind::Command, "edit", Some(*agent), None, |_| {
                let p = root.join("mod1/f1.rs");
                let mut s = fs::read_to_string(&p).unwrap();
                s.push_str(&format!("// cycle {cycle}\n"));
                fs::write(&p, s).unwrap();
            })
            .unwrap();
            if cycle % 10 == 0 {
                sh(
                    root,
                    &format!("{git} checkout -q -- . && {git} checkout -q --detach side && {git} checkout -q --detach main"),
                );
                mount.fence().unwrap();
            }
        }
        // Let everything hibernate, then sample.
        let deadline = Instant::now() + Duration::from_secs(5);
        while !set.iter().all(|(ws, ..)| ws.is_hibernating()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        if cycle % (cycles / 10).max(1) == 0 || cycle == cycles - 1 {
            let heap = LIVE.load(Ordering::Relaxed) as f64 / (1 << 20) as f64;
            let cache = ondb_core::cache_bytes() as f64 / (1 << 20) as f64;
            println!("cycle {cycle:>4}: heap {heap:>6.2} MiB (cache {cache:>5.2}), fds {:>4}, threads {:>3}", fds(), threads());
            samples.push((heap - cache, fds(), threads()));
        }
    }
    println!("{} cycles x {n} worktrees in {:.1?}", cycles, t.elapsed());
    let (h0, f0, t0) = samples[1.min(samples.len() - 1)];
    let (h1, f1, t1) = *samples.last().unwrap();
    println!("heap excl. cache {h0:.2} -> {h1:.2} MiB, fds {f0} -> {f1}, threads {t0} -> {t1}");
    assert!(h1 <= h0 * 1.15 + 1.0, "heap grew");
    assert!(f1 <= f0 && t1 <= t0, "fds or threads grew");
    println!("ok: flat");
}
