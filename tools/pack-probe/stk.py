import ctypes, os, sys, time, subprocess, struct, signal, collections
libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.ptrace.restype = ctypes.c_long
libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
S, I, G, D = 0x4206, 0x4207, 12, 17
bin_, args, delay, n, outp = sys.argv[1], sys.argv[2:6], float(sys.argv[6]), int(sys.argv[7]), sys.argv[8]
sdir = args[0]
p = subprocess.Popen(["bash", "--norc", "--noprofile", "-c", 'ulimit -v 4000000; exec "$@"', "x", bin_] + args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
t0 = time.time()
while time.time() - t0 < delay and p.poll() is None:
    time.sleep(0.5)
base = None
for l in open("/proc/%d/maps" % p.pid):
    if "stepdbg" in l or "stepdbg2" in l:
        lo = int(l.split("-")[0], 16)
        off = int(l.split()[2], 16)
        base = lo - off if base is None else base
        break
print("pid", p.pid, "alive", p.poll() is None, "base", base and hex(base), flush=True)
counts = collections.Counter(); nsamp = 0
frames = []
for i in range(n):
    for t in sorted(os.listdir("/proc/%d/task" % p.pid), key=int):
        t = int(t)
        if libc.ptrace(S, t, None, None) != 0: continue
        libc.ptrace(I, t, None, None)
        try: os.waitpid(t, 0x40000000)
        except ChildProcessError: pass
        regs = (ctypes.c_ulong * 27)()
        libc.ptrace(G, t, None, regs)
        rip, rsp, rbp = regs[16], regs[19], regs[4]
        st = open("/proc/%d/task/%d/stat" % (p.pid, t)).read().rsplit(")", 1)[1].split()
        fr = [rip]
        try:
            with open("/proc/%d/mem" % p.pid, "rb") as f:
                f.seek(rsp); data = f.read(8 * 300)
            for k in range(0, len(data) - 8, 8):
                v = struct.unpack_from("<Q", data, k)[0]
                if base and base <= v < base + (32 << 20):
                    fr.append(v)
                if len(fr) > 40: break
        except OSError: pass
        frames.append(tuple(x - base for x in fr))
        libc.ptrace(D, t, None, None)
    time.sleep(0.1)
    nsamp += 1
os.killpg(p.pid, signal.SIGKILL)
p.wait()
uniq = sorted({x for f in frames for x in f[:30]})
ll = subprocess.run(["addr2line", "-f", "-C", "-e", bin_] + [hex(u) for u in uniq], capture_output=True, text=True).stdout.splitlines()
name = {u: ll[2 * i] for i, u in enumerate(uniq)}
tops = collections.Counter(); chains = collections.Counter(); seen = collections.Counter()
for f in frames:
    tops[name[f[0]]] += 1
    ch = [name[x] for x in f[:30]]
    # drop runtime noise for a readable chain
    s = " <- ".join(x[:60] for x in [c for c in ch if c != "??"][:8])
    chains[s] += 1
    for c in set(ch):
        seen[c] += 1
print("samples", len(frames)); print("top rip:")
for k, v in tops.most_common(15): print(v, k[:150])
print("functions appearing anywhere on sampled stacks:")
for k, v in seen.most_common(60): print(v, k[:130])
