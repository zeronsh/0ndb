import ctypes, os, sys, time, subprocess, bisect, struct, signal
libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.ptrace.restype = ctypes.c_long
libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
PTRACE_SEIZE, PTRACE_INTERRUPT, PTRACE_GETREGS, PTRACE_CONT, PTRACE_DETACH = 0x4206, 0x4207, 12, 7, 17
bin_, soakdir = sys.argv[1], sys.argv[2]
syms = []
for l in subprocess.run(["nm", "--defined-only", bin_], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if len(p) == 3 and p[1] in "tT":
        syms.append((int(p[0], 16), p[2]))
syms.sort(); addrs = [a for a, _ in syms]
child = subprocess.Popen(["python3", "tools/soak/soak.py", "--minutes", "4", "--restart", "9", "--seed", "3", "--skip", "redo", "--stop", "--keep", "--bin", bin_, "--dir", soakdir], stdin=subprocess.DEVNULL, stdout=open(soakdir + ".out", "w"), stderr=subprocess.STDOUT, env=dict(os.environ, SOAK_HOME_MAX_MB="1500"))
def daemon_pid():
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                cl = open("/proc/%s/cmdline" % p, "rb").read().split(b"\0")
                if cl and (cl[0].endswith(b"0ndb-soak") or cl[0].endswith(b"0ndb-dbg")) and len(cl) > 1 and cl[1] == b"daemon":
                    return int(p)
            except OSError:
                pass
    return None
time.sleep(100)
pid = None
while pid is None and child.poll() is None:
    pid = daemon_pid(); time.sleep(0.5)
print("daemon pid", pid, "cpu", open("/proc/%d/stat" % pid).read().split()[13:15])
base = None
for l in open("/proc/%d/maps" % pid):
    if bin_.split("/")[-1] in l and "r-xp" in l:
        base = int(l.split("-")[0], 16); break
    if bin_.split("/")[-1] in l and base is None:
        base = int(l.split("-")[0], 16)
samples = []
for i in range(150):
    t = pid
    if libc.ptrace(PTRACE_SEIZE, t, None, None) != 0:
        print("seize errno", ctypes.get_errno()); break
    libc.ptrace(PTRACE_INTERRUPT, t, None, None)
    os.waitpid(t, 0x40000000)
    regs = (ctypes.c_ulong * 27)()
    libc.ptrace(PTRACE_GETREGS, t, None, regs)
    frames = [regs[16]]
    try:
        with open("/proc/%d/mem" % t, "rb") as f:
            f.seek(regs[19]); data = f.read(8 * 400)
        for k in range(0, len(data), 8):
            v = struct.unpack_from("<Q", data, k)[0]
            if base <= v < base + (64 << 20):
                frames.append(v)
            if len(frames) > 6: break
    except OSError:
        pass
    samples.append(frames)
    libc.ptrace(PTRACE_DETACH, t, None, None)
    time.sleep(0.05)
rips = {}
for f in samples:
    rips[f[0] - base] = rips.get(f[0] - base, 0) + 1
top = sorted(rips.items(), key=lambda x: -x[1])[:25]
out = subprocess.run(["addr2line", "-f", "-i", "-e", bin_] + [hex(u) for u, _ in top], capture_output=True, text=True).stdout.splitlines()
import itertools
blocks, cur = [], []
for l in out:
    cur.append(l)
print("top rips:")
import re
res = subprocess.run(["addr2line", "-f", "-i", "-e", bin_] + [hex(u) for u, _ in top], capture_output=True, text=True).stdout
print(res[:6000])
for (u, n) in top: print(n, hex(u))
print("===")
uniq = sorted({x - base for f in samples for x in f})
names = {}
out = subprocess.run(["addr2line", "-f", "-e", bin_] + [hex(u) for u in uniq], capture_output=True, text=True).stdout.splitlines()
for u, l in zip(uniq, out[::2]):
    names[u] = l
hits = {}
for f in samples:
    k = " <- ".join(names.get(x - base, "?") for x in f[:5])
    hits[k] = hits.get(k, 0) + 1
for k, n in sorted(hits.items(), key=lambda x: -x[1])[:12]:
    print(n, k[:400])
child.terminate(); time.sleep(1)
try:
    os.kill(pid, signal.SIGKILL)
except Exception:
    pass
