import os, sys, time, subprocess, signal
edits, idle, sdir, binp = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
limit = 3000000000
os.makedirs(sdir + "/repo"); os.makedirs(sdir + "/state")
subprocess.run(["git", "init", "-q", "."], cwd=sdir + "/repo", check=True)
open(sdir + "/repo/a.txt", "w").write("line 0\nline 1\n")
subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "add", "a.txt"], cwd=sdir + "/repo", check=True)
subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], cwd=sdir + "/repo", check=True)
def du():
    total = n = 0
    for d, _, fs in os.walk(sdir + "/state"):
        for f in fs:
            p = os.path.join(d, f)
            try:
                total += os.path.getsize(p)
            except OSError:
                continue
            if f.startswith("c") and "/pack" in d and len(f) == 9:
                n += 1
    return total, n
p = subprocess.Popen(["bash", "--norc", "--noprofile", "-c", 'ulimit -v 4000000; exec "$@"', "x", binp, sdir + "/state", sdir + "/repo", str(edits), str(idle)], stdin=subprocess.DEVNULL, stdout=open(sdir + "/out", "w"), stderr=subprocess.STDOUT)
t0 = time.time()
tripped = False
cpu0 = 0.0
while p.poll() is None:
    b, n = du()
    try:
        st = open("/proc/%d/stat" % p.pid).read().rsplit(")", 1)[1].split()
        kids = [x for x in subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()]
        pid = int(kids[0]) if kids else p.pid
        st = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
        cpu = (int(st[11]) + int(st[12])) / os.sysconf("SC_CLK_TCK")
        rss = int(open("/proc/%d/statm" % pid).read().split()[1]) * 4096 // 1048576
    except Exception:
        cpu, rss = -1, -1
    print("t=%.0f bytes=%d containers=%d cpu=%.1f rss_mb=%s" % (time.time() - t0, b, n, cpu, rss), flush=True)
    if b > limit and not tripped:
        tripped = True
        print("WATCHDOG tripped at %d" % b, flush=True)
        kids = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()
        for k in kids:
            os.kill(int(k), signal.SIGKILL)
        p.kill()
    time.sleep(1)
print("exit", p.returncode, "tripped", tripped)
print(open(sdir + "/out").read()[-400:])
