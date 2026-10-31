//! Massive-repository benchmark: one mount of a large git checkout.
//!
//! `cargo run --release -p ondb --example bigrepo -- <repo> [scratch]`
//!
//! Works on a throwaway `git worktree` of `<repo>` (the repo itself is not
//! touched). Reports first-mount time, store size, heap and RSS, hibernate
//! and wake cost, a no-change rescan, git-index churn (`git status` storms
//! from editors) and branch switches touching many files.

use std::alloc::{GlobalAlloc, Layout, System};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::time::{Duration, Instant};

use ondb::{Mount, MountOptions, Workspace};

struct Counting;
static LIVE: AtomicIsize = AtomicIsize::new(0);
static PEAK: AtomicIsize = AtomicIsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(l) };
        if !p.is_null() {
            let now = LIVE.fetch_add(l.size() as isize, Ordering::Relaxed) + l.size() as isize;
            PEAK.fetch_max(now, Ordering::Relaxed);
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
            let now = LIVE.fetch_add(new as isize - l.size() as isize, Ordering::Relaxed) + new as isize - l.size() as isize;
            PEAK.fetch_max(now, Ordering::Relaxed);
        }
        q
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn mb(b: isize) -> f64 {
    b as f64 / (1 << 20) as f64
}

fn sh(dir: &Path, script: &str) -> String {
    let out = Command::new("sh").arg("-c").arg(script).current_dir(dir).output().unwrap();
    assert!(out.status.success(), "{script}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn cpu_and_rss() -> (Duration, f64) {
    let pid = std::process::id().to_string();
    let ps = sh(Path::new("."), &format!("ps -o time=,rss= -p {pid}"));
    let mut it = ps.split_whitespace();
    let t = it.next().unwrap_or("0");
    let mut secs = 0.0;
    for part in t.split(':') {
        secs = secs * 60.0 + part.parse::<f64>().unwrap_or(0.0);
    }
    let rss = it.next().and_then(|r| r.parse::<f64>().ok()).unwrap_or(0.0) / 1024.0;
    (Duration::from_secs_f64(secs), rss)
}

fn dir_size(p: &Path) -> u64 {
    fs::read_dir(p).map(|d| d.flatten().map(|e| e.metadata().map(|m| m.len()).unwrap_or(0)).sum()).unwrap_or(0)
}

fn line(label: &str, t: Option<Duration>, cpu0: Duration) {
    let (cpu, rss) = cpu_and_rss();
    println!(
        "{label:<34} heap {:>8.1} MiB (peak {:>8.1})  rss {:>7.1} MiB  cpu {:>7.2}s{}",
        mb(LIVE.load(Ordering::Relaxed)),
        mb(PEAK.swap(LIVE.load(Ordering::Relaxed), Ordering::Relaxed)),
        rss,
        cpu.saturating_sub(cpu0).as_secs_f64(),
        t.map(|t| format!("  took {t:.2?}")).unwrap_or_default()
    );
}

fn main() {
    let mut args = std::env::args().skip(1);
    let repo = PathBuf::from(args.next().expect("usage: bigrepo <repo> [scratch]"));
    let scratch = PathBuf::from(args.next().unwrap_or_else(|| "/tmp/ondb-bigrepo".into()));
    let _ = fs::remove_dir_all(&scratch);
    fs::create_dir_all(&scratch).unwrap();
    let wt = scratch.join("wt");
    let git = "git -c user.name=b -c user.email=b@b";
    sh(&repo, &format!("git worktree add -q --detach {}", wt.display()));
    let files: usize = sh(&wt, "git ls-files | wc -l").trim().parse().unwrap();
    let bytes: u64 = sh(&wt, "git ls-files -z | xargs -0 stat -f %z | awk '{s+=$1} END {print s}'").trim().parse().unwrap_or(0);
    println!("{} files, {:.1} MiB in {}", files, bytes as f64 / (1 << 20) as f64, wt.display());
    // A second commit touching many files, for branch switches.
    sh(
        &wt,
        &format!(
            "{git} switch -q -c bench-a && git ls-files | grep -E '\\.(c|h)$' | head -2000 | while read f; do echo '/* bench */' >> \"$f\"; done && {git} commit -qam bench-a && {git} switch -q --detach HEAD~1"
        ),
    );

    let cpu0 = cpu_and_rss().0;
    let opts = MountOptions { idle_unload: None, ..MountOptions::default() };
    let db = scratch.join("0ndb.db");
    let sampling = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    if std::env::var("BIGREPO_SAMPLE").is_ok() {
        let on = sampling.clone();
        std::thread::spawn(move || {
            let t = Instant::now();
            while on.load(Ordering::Relaxed) {
                eprintln!("  t={:>5.1}s heap {:>8.1} MiB", t.elapsed().as_secs_f64(), mb(LIVE.load(Ordering::Relaxed)));
                std::thread::sleep(Duration::from_millis(1500));
            }
        });
    }
    let t = Instant::now();
    let ws = Workspace::open(&db, None).unwrap();
    let mount = Mount::start(&ws, &wt, opts.clone()).unwrap();
    let first = t.elapsed();
    sampling.store(false, Ordering::Relaxed);
    line("first mount (adopt)", Some(first), cpu0);
    println!(
        "{:<34} {:.1} MiB on disk ({:.2}x the checkout)",
        "store",
        dir_size(&scratch) as f64 / (1 << 20) as f64,
        dir_size(&scratch) as f64 / bytes.max(1) as f64
    );

    let c = cpu_and_rss().0;
    std::thread::sleep(Duration::from_secs(5));
    println!("{:<34} {:.3}s cpu over 5s", "idle", cpu_and_rss().0.saturating_sub(c).as_secs_f64());

    // No-change rescan (what restarts, overflows and fence timeouts cost).
    drop(mount);
    let t = Instant::now();
    let mount = Mount::start(&ws, &wt, opts.clone()).unwrap();
    line("remount, nothing changed", Some(t.elapsed()), cpu0);

    // Hibernate + wake.
    let t = Instant::now();
    ws.hibernate();
    line("hibernate", Some(t.elapsed()), cpu0);
    let t = Instant::now();
    let _ = ws.read(|h| h.walk().len());
    line("wake (reload history)", Some(t.elapsed()), cpu0);

    // Editors run `git status` constantly; each may rewrite the index.
    let c = cpu_and_rss().0;
    let t = Instant::now();
    for _ in 0..10 {
        sh(&wt, "touch -c Makefile && git status --porcelain >/dev/null");
        std::thread::sleep(Duration::from_millis(300));
    }
    mount.fence().unwrap();
    println!(
        "{:<34} {:.2}s cpu in 0ndb for 10 status runs ({:.2?})",
        "git index churn",
        cpu_and_rss().0.saturating_sub(c).as_secs_f64(),
        t.elapsed()
    );

    // Branch switches across 2000 files.
    for (i, target) in ["bench-a", "-"].iter().enumerate() {
        let t = Instant::now();
        sh(&wt, &format!("git switch -q --detach {target} 2>/dev/null || git switch -q {target}"));
        mount.fence().unwrap();
        line(&format!("branch switch {} (2000 files)", i + 1), Some(t.elapsed()), cpu0);
    }

    // One small edit.
    let t = Instant::now();
    fs::write(wt.join("README"), "edited\n").unwrap();
    mount.fence().unwrap();
    line("single edit + fence", Some(t.elapsed()), cpu0);

    drop(mount);
    drop(ws);
    println!("{:<34} {:.1} MiB on disk", "store after", dir_size(&scratch) as f64 / (1 << 20) as f64);
    sh(&repo, &format!("git worktree remove --force {} && git branch -D bench-a >/dev/null", wt.display()));
}
