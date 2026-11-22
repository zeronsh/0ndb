import os, sys, time, re, socket, threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import harness as H
n = int(sys.argv[1])

class Relay(H.Relay):
    def __init__(self, d):
        self.dir = d
        self.port = H.free_port()
        self.proc = H.spawn([H.BIN, "relay", "--dir", "relay", "--objects", "objects", "--hot-kb", "4", "--flush-ms", "500", "--listen", "127.0.0.1:%d" % self.port, "--open"], d, "relay.log")
        for _ in range(100):
            time.sleep(0.05)
            m = re.search(r"relay key ([0-9a-f]+)", open(os.path.join(d, "relay.log")).read())
            if m:
                self.key = m.group(1)
                break

def probe(port, out, stop):
    while not stop.is_set():
        t0 = time.perf_counter()
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=5)
            s.sendall(b"\x00\x10" + b"\x00" * 16)
            try:
                s.recv(64)
            except ConnectionResetError:
                pass
            s.close()
            out.append((time.perf_counter() - t0) * 1000)
        except Exception:
            out.append(5000.0)
        time.sleep(0.01)

def summ(name, xs):
    xs = sorted(xs)
    return "%s: n=%d p50=%.1fms p99=%.1fms max=%.1fms over50ms=%d" % (name, len(xs), xs[len(xs)//2], xs[min(len(xs)-1, int(len(xs)*0.99))], xs[-1], sum(1 for x in xs if x > 50))

def run():
    d = H.scenario_dir("stall")
    relay = Relay(d)
    import subprocess
    st = subprocess.Popen(["sudo", "strace", "-f", "-y", "-T"] + (["-k"] if os.environ.get("STRACE_K") else []) + [  "-e", "trace=fsync,fdatasync,sync_file_range", "-o", os.path.join(d, "st.txt"), "-p", str(relay.proc.pid)]) if os.environ.get("STRACE") else None
    time.sleep(0.5)
    a = H.Device(d, "a", relay)
    cid = a.cli("new", "transcript").split()[1]
    for i, (mid, role, text) in enumerate(H.transcript_messages(H.TRANSCRIPT, n)):
        a.cli("record", "--source", "claude", "--id", mid, "--seq", str(i + 1), "--role", role, "--stdin", stdin=text)
    time.sleep(4)
    la = a.cli("log", cid, "-n", "100000")
    disk, _ = H.du(os.path.join(d, "relay", "spaces"), disk=True)
    time.sleep(int(os.environ.get("EXTRA_WAIT", "0")))
    disk2, _ = H.du(os.path.join(d, "relay", "spaces"), disk=True)
    print("pack on disk at 4s %d, after extra wait %d" % (disk, disk2))
    base, during = [], []
    stop = threading.Event()
    th = threading.Thread(target=probe, args=(relay.port, base, stop), daemon=True); th.start(); time.sleep(3); stop.set(); th.join()
    b = H.Device(d, "b", None)
    H.term(b.host)
    b.host = H.spawn([H.BIN, "host", "--home", "b", "--plugs", "sealed_store,unlock", "--store", "a.store", "--passkey", "a.pk"], d, "b.host2.log", b.env)
    time.sleep(0.5)
    stop = threading.Event()
    th = threading.Thread(target=probe, args=(relay.port, during, stop), daemon=True); th.start()
    t0 = time.time()
    b.cli("login", "--subject", "user-a", "--relay", relay.addr(), "--relay-key", relay.key)
    lb = ""
    for _ in range(240):
        time.sleep(0.25)
        lb = b.cli("log", cid, "-n", "100000", check=False)
        if lb.count("\n") >= la.count("\n") and lb.strip():
            break
    sync_s = time.time() - t0
    stop.set(); th.join()
    strip = lambda s: "\n".join(l for l in s.splitlines() if not l.startswith("● "))
    print("pack on disk after eviction %d bytes; synced %s in %.1fs" % (disk, strip(la) == strip(lb), sync_s))
    print(summ("probe before", base))
    print(summ("probe during cold sync", during))
    a.stop(); b.stop()
    if st:
        subprocess.run(["sudo", "kill", "-INT", str(st.pid)]); time.sleep(1)
    relay.stop()
    print([l for l in open(os.path.join(d, "relay.log")).read().splitlines() if "object-store" in l])

try:
    run()
finally:
    H.cleanup()
