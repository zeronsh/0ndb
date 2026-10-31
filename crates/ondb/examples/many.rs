//! Many-worktree resource benchmark: one process mounting N git worktrees.
//! Reports resident memory, threads, open files and CPU at each phase, and
//! checks that churn and remounting don't grow them.
//!
//! `cargo run --release -p ondb --example many -- <repo> <n> [scratch-dir]`
//!
//! Worktrees are created (once) from a local clone of `<repo>` under the
//! scratch dir, so the source repository is never touched.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicIsize, Ordering};

use ondb::{ActorKind, Mount, MountOptions, Recorder, ScopeKind, Workspace};

/// Live Rust heap bytes (SQLite's own allocations aren't included).
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

fn heap_mb() -> f64 {
    LIVE.load(Ordering::Relaxed) as f64 / (1 << 20) as f64
}

fn take_peak_mb() -> f64 {
    PEAK.swap(LIVE.load(Ordering::Relaxed), Ordering::Relaxed) as f64 / (1 << 20) as f64
}

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = Command::new(args[0]).args(&args[1..]).current_dir(dir).output().unwrap();
    assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

struct Usage {
    rss_mb: f64,
    threads: usize,
    fds: usize,
    cpu: Duration,
}

fn usage() -> Usage {
    let pid = std::process::id().to_string();
    let ps = sh(Path::new("."), &["ps", "-o", "rss=,time=", "-p", &pid]);
    let mut it = ps.split_whitespace();
    let rss_mb = it.next().unwrap().parse::<f64>().unwrap() / 1024.0;
    let cpu = parse_cpu(it.next().unwrap());
    let threads = if cfg!(target_os = "macos") {
        sh(Path::new("."), &["ps", "-M", "-p", &pid]).lines().count().saturating_sub(1)
    } else {
        fs::read_dir("/proc/self/task").map(|d| d.count()).unwrap_or(0)
    };
    let fds = fs::read_dir("/dev/fd").map(|d| d.count()).unwrap_or(0);
    Usage { rss_mb, threads, fds, cpu }
}

fn parse_cpu(s: &str) -> Duration {
    // [[hh:]mm:]ss.cc
    let mut secs = 0.0;
    for part in s.split(':') {
        secs = secs * 60.0 + part.parse::<f64>().unwrap_or(0.0);
    }
    Duration::from_secs_f64(secs)
}

fn report(label: &str, base: &Usage, t: Option<Duration>) -> Usage {
    let u = usage();
    println!(
        "{label:<30} heap {:>7.1} MiB (peak {:>7.1})  rss {:>7.1} MiB  threads {:>4}  fds {:>5}  cpu {:>6.2}s{}",
        heap_mb(),
        take_peak_mb(),
        u.rss_mb,
        u.threads,
        u.fds,
        (u.cpu.saturating_sub(base.cpu)).as_secs_f64(),
        t.map(|t| format!("  took {t:.2?}")).unwrap_or_default()
    );
    u
}

fn main() {
    let mut args = std::env::args().skip(1);
    let repo = PathBuf::from(args.next().expect("usage: many <repo> <n> [scratch]"));
    let n: usize = args.next().and_then(|a| a.parse().ok()).unwrap_or(20);
    let scratch = PathBuf::from(args.next().unwrap_or_else(|| "/tmp/ondb-many".into()));
    fs::create_dir_all(&scratch).unwrap();
    let src = scratch.join("src");
    if !src.exists() {
        sh(&scratch, &["git", "clone", "-q", "--local", repo.to_str().unwrap(), "src"]);
    }
    let roots: Vec<PathBuf> = (0..n).map(|i| scratch.join(format!("wt{i:03}"))).collect();
    for r in &roots {
        if !r.exists() {
            sh(&src, &["git", "worktree", "add", "-q", "--detach", r.to_str().unwrap()]);
        }
    }
    let dbs = scratch.join("dbs");
    let _ = fs::remove_dir_all(&dbs);
    fs::create_dir_all(&dbs).unwrap();
    for r in &roots {
        let _ = fs::remove_dir_all(r.join(".0ndb"));
    }
    let files = sh(&roots[0], &["git", "ls-files"]).lines().count();
    println!("{n} worktrees of {} ({files} files each)", repo.display());

    let base = usage();
    report("start", &base, None);

    let opts = MountOptions { idle_unload: Some(Duration::from_secs(3)), ..MountOptions::default() };
    let open = |i: usize| Workspace::open(dbs.join(format!("{i:03}.db")), None).unwrap();
    let t = Instant::now();
    let mut wss: Vec<Workspace> = (0..n).map(open).collect();
    let mut mounts: Vec<Mount> = wss.iter().zip(&roots).map(|(ws, r)| Mount::start(ws, r, opts.clone()).unwrap()).collect();
    let adopted = report("adopt all (first mount)", &base, Some(t.elapsed()));
    println!("{:<30} {:.1} MiB live heap per mounted worktree", "", heap_mb() / n as f64);

    let c = usage().cpu;
    std::thread::sleep(Duration::from_secs(10));
    let idle = usage().cpu.saturating_sub(c);
    println!("{:<30} {:.3}s cpu over 10s ({:.2}% of one core)", "idle", idle.as_secs_f64(), idle.as_secs_f64() * 10.0);

    // Edit churn: every worktree, several rounds, attributed scopes.
    let rounds = 20;
    let t = Instant::now();
    for round in 0..rounds {
        for ((ws, m), r) in wss.iter().zip(&mounts).zip(&roots) {
            let agent = ws.actor("bench", ActorKind::Agent).unwrap();
            let rec = Recorder::new(ws, vec![m.handle()]).unwrap();
            rec.scoped(ScopeKind::Command, "edit", Some(agent), None, |_| {
                let p = r.join("README.md");
                let mut s = fs::read_to_string(&p).unwrap_or_default();
                s.push_str(&format!("churn {round}\n"));
                fs::write(&p, s).unwrap();
            })
            .unwrap();
        }
        if round == 0 || round == rounds - 1 {
            report(&format!("churn round {}", round + 1), &base, None);
        }
    }
    println!("{:<30} {:.2?} per attributed edit", "", t.elapsed() / (rounds * n) as u32);

    // Branch switches in every worktree.
    let t = Instant::now();
    for r in &roots {
        sh(r, &["git", "checkout", "-q", "--", "."]);
        sh(r, &["git", "checkout", "-q", "--detach", "HEAD~20"]);
    }
    for m in &mounts {
        m.fence().unwrap();
    }
    for r in &roots {
        sh(r, &["git", "checkout", "-q", "-"]);
    }
    for m in &mounts {
        m.fence().unwrap();
    }
    report("2 checkouts per worktree", &base, Some(t.elapsed()));

    let c = usage().cpu;
    std::thread::sleep(Duration::from_secs(10));
    let idle = usage().cpu.saturating_sub(c);
    println!("{:<30} {:.3}s cpu over 10s ({:.2}% of one core)", "idle after work", idle.as_secs_f64(), idle.as_secs_f64() * 10.0);
    let asleep = wss.iter().filter(|w| w.is_hibernating()).count();
    report(&format!("hibernated ({asleep}/{n})"), &base, None);
    // Steady state: everything asleep, nothing happening.
    let c = usage().cpu;
    std::thread::sleep(Duration::from_secs(10));
    let idle = usage().cpu.saturating_sub(c);
    println!("{:<30} {:.3}s cpu over 10s ({:.2}% of one core)", "idle while hibernated", idle.as_secs_f64(), idle.as_secs_f64() * 10.0);
    println!(
        "{:<30} {:.2} MiB live heap per hibernated worktree (excl. shared cache {:.1} MiB)",
        "",
        (heap_mb() - ondb_core::cache_bytes() as f64 / (1 << 20) as f64) / n as f64,
        ondb_core::cache_bytes() as f64 / (1 << 20) as f64
    );

    // Build output into an ignored directory of every worktree.
    let c = usage().cpu;
    for r in &roots {
        let d = r.join("target/bench");
        fs::create_dir_all(&d).unwrap();
        for i in 0..500 {
            fs::write(d.join(format!("obj{i}.o")), b"object").unwrap();
        }
    }
    std::thread::sleep(Duration::from_secs(2));
    let asleep = wss.iter().filter(|w| w.is_hibernating()).count();
    println!(
        "{:<30} {:.3}s cpu for {} ignored writes; {asleep}/{n} still hibernating",
        "ignored build output",
        usage().cpu.saturating_sub(c).as_secs_f64(),
        500 * n
    );
    for r in &roots {
        fs::remove_dir_all(r.join("target/bench")).unwrap();
    }

    // Wake every worktree with one edit.
    let t = Instant::now();
    for (m, r) in mounts.iter().zip(&roots) {
        fs::write(r.join("WAKE.md"), "wake\n").unwrap();
        m.fence().unwrap();
    }
    report("woken by an edit each", &base, Some(t.elapsed()));
    for (m, r) in mounts.iter().zip(&roots) {
        fs::remove_file(r.join("WAKE.md")).unwrap();
        m.fence().unwrap();
    }

    // Unmount everything: memory, threads and files should come back.
    let t = Instant::now();
    mounts.clear();
    wss.clear();
    let dropped = report("unmount + close all", &base, Some(t.elapsed()));

    // Remount from the stores (what a restart does), several cycles.
    let mut last = dropped.rss_mb;
    for cycle in 1..=3 {
        let t = Instant::now();
        let h0 = heap_mb();
        wss = (0..n).map(open).collect();
        let h1 = heap_mb();
        mounts = wss.iter().zip(&roots).map(|(ws, r)| Mount::start(ws, r, opts.clone()).unwrap()).collect();
        println!("  per worktree: history {:.2} MiB, mount {:.2} MiB", (h1 - h0) / n as f64, (heap_mb() - h1) / n as f64);
        let u = report(&format!("remount cycle {cycle}"), &base, Some(t.elapsed()));
        mounts.clear();
        wss.clear();
        let d = report(&format!("  closed after cycle {cycle}"), &base, None);
        if cycle > 1 && d.rss_mb > last * 1.10 + 8.0 {
            println!("  !! rss grew across cycles ({last:.1} -> {:.1} MiB)", d.rss_mb);
        }
        last = d.rss_mb;
        let _ = u;
    }
    let _ = adopted;
    println!("final live heap {:.2} MiB", heap_mb());
}
