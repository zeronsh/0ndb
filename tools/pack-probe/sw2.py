import os, sys, time, subprocess, signal
edits, idle, sdir, binp, label = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
LIMIT, MAXT = 3000000000, 600
os.makedirs(sdir + "/repo"); os.makedirs(sdir + "/state")
g = ["git", "-c", "user.name=t", "-c", "user.email=t@t"]
subprocess.run(["git", "init", "-q", "."], cwd=sdir + "/repo", check=True)
open(sdir + "/repo/a.txt", "w").write("line 0\nline 1\n")
subprocess.run(g + ["add", "a.txt"], cwd=sdir + "/repo", check=True)
subprocess.run(g + ["commit", "-q", "-m", "init"], cwd=sdir + "/repo", check=True)
def du():
    total = c = r = 0
    for d, _, fs in os.walk(sdir + "/state"):
        for f in fs:
            try:
                total += os.path.getsize(os.path.join(d, f))
            except OSError:
                continue
            if d.endswith("/pack") and len(f) == 9:
                c += f[0] == "c"; r += f[0] == "r"
    return total, c, r
out = open(sdir + "/out", "w")
p = subprocess.Popen(["bash", "--norc", "--noprofile", "-c", 'ulimit -v 4000000; exec "$@"', "x", binp, sdir + "/state", sdir + "/repo", str(edits), str(idle)] + ([sys.argv[6]] if len(sys.argv) > 6 else []), stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
t0 = time.time(); marks = [m for m in (20, 50, 100, 150, 200, 250, 300, 350, 400, 700, 1000) if m <= edits]; last = 0; why = ""; tlast = 0
def stat():
    s = open("/proc/%d/stat" % p.pid).read().rsplit(")", 1)[1].split()
    return (int(s[11]) + int(s[12])) / os.sysconf("SC_CLK_TCK")
def io():
    try:
        return int([l for l in open("/proc/%d/io" % p.pid) if l.startswith("write_bytes")][0].split()[1])
    except Exception:
        return -1
while p.poll() is None:
    t = time.time() - t0
    try:
        n = sum(1 for _ in open(sdir + "/repo/a.txt")) - 2; cpu = stat(); w = io()
    except Exception:
        time.sleep(0.2); continue
    b, c, r = du()
    if marks and n >= marks[0]:
        print("%s edits=%d t=%.1f cpu=%.1f disk=%d containers=%d runs=%d written=%d" % (label, n, t, cpu, b, c, r, w), flush=True); marks.pop(0)
    if t - tlast > 15:
        tlast = t; print("%s .. edits=%d t=%.1f cpu=%.1f disk=%d containers=%d runs=%d written=%d" % (label, n, t, cpu, b, c, r, w), flush=True)
    if b > LIMIT or t > MAXT:
        why = "disk limit" if b > LIMIT else "time limit"
        os.killpg(p.pid, signal.SIGKILL); p.wait(); break
    time.sleep(0.5)
b, c, r = du()
print("%s END %s rc=%s t=%.1f disk=%d containers=%d runs=%d edits=%d" % (label, why or "finished", p.returncode, time.time() - t0, b, c, r, sum(1 for _ in open(sdir + "/repo/a.txt")) - 2))
out.close(); print(open(sdir + "/out").read()[-300:].strip())
