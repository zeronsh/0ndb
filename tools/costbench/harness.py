#!/usr/bin/env python3
import atexit, hashlib, json, os, random, re, shutil, signal, socket, struct, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BIN = os.environ.get("ONDB_BIN", os.path.join(REPO, "bin", "0ndb"))
BIN_LEASE = os.environ.get("ONDB_BIN_LEASE", os.path.join(REPO, "bin", "0ndb-lease10"))
PACKLIVE = os.environ.get("COST_PACKLIVE", os.path.join(REPO, "bin", "packlive"))
OUT = os.environ.get("COST_OUT", os.path.join(tempfile.gettempdir(), "costbench"))
TRANSCRIPT = os.environ.get("COST_TRANSCRIPT", "")
SETTLE = float(os.environ.get("COST_SETTLE", "5"))
LIMIT = ["bash", "-c", 'ulimit -v 4000000; exec "$@"', "x"]


def run(args, cwd, env=None, stdin=None, timeout=120, check=True):
    p = subprocess.run(LIMIT + args, cwd=cwd, env=env, input=stdin, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError("%s -> %d\n%s%s" % (" ".join(args), p.returncode, p.stdout, p.stderr))
    return p.stdout


PROCS = []


def spawn(args, cwd, log, env=None, mode="w"):
    f = open(os.path.join(cwd, log), mode)
    p = subprocess.Popen(LIMIT + args, cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
    PROCS.append(p)
    return p


def term(p, timeout=30):
    if p.poll() is not None:
        return
    try:
        os.killpg(p.pid, signal.SIGTERM)
        p.wait(timeout=timeout)
    except Exception:
        try:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait(timeout=10)
        except Exception:
            pass


def cleanup():
    for p in PROCS:
        if p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except Exception:
                pass


atexit.register(cleanup)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def du(path, disk=False):
    total = 0
    files = 0
    for root, _, names in os.walk(path):
        for n in names:
            try:
                st = os.stat(os.path.join(root, n))
                total += st.st_blocks * 512 if disk else st.st_size
                files += 1
            except OSError:
                pass
    return total, files


def zstd3(data):
    p = subprocess.run(["zstd", "-3", "-q", "-c"], input=data, capture_output=True)
    return len(p.stdout)


def zstd_size(data):
    p = subprocess.run(["zstd", "-19", "-q", "-c"], input=data, capture_output=True)
    return len(p.stdout)


class Client:
    def __init__(self, sock_path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(sock_path)
        self.s.sendall(b"0NDB\x01")
        self.tag = 0
        self.buf = b""

    def _read(self, n):
        while len(self.buf) < n:
            d = self.s.recv(65536)
            if not d:
                raise RuntimeError("daemon closed")
            self.buf += d
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def call(self, op, timeout_ms=60000, **args):
        self.tag += 1
        req = json.dumps(dict(op=op, **args)).encode()
        payload = struct.pack("<QBQ", self.tag, 1, timeout_ms) + req
        self.s.sendall(struct.pack("<IB", len(payload), 1) + payload)
        while True:
            ln, kind = struct.unpack("<IB", self._read(5))
            body = self._read(ln)
            if kind != 2:
                continue
            tag, status = struct.unpack("<QB", body[:9])
            if tag != self.tag:
                continue
            res = json.loads(body[9:] or b"{}")
            if status != 0:
                raise RuntimeError("%s -> status %d %s" % (op, status, res))
            return res

    def close(self):
        self.s.close()


class Relay:
    def __init__(self, d):
        self.dir = d
        self.port = free_port()
        self.proc = spawn([BIN, "relay", "--dir", "relay", "--objects", "objects", "--listen", "127.0.0.1:%d" % self.port, "--open"], d, "relay.log")
        for _ in range(100):
            time.sleep(0.05)
            m = re.search(r"relay key ([0-9a-f]{64})", open(os.path.join(d, "relay.log")).read())
            if m:
                self.key = m.group(1)
                return
        raise RuntimeError("relay did not start")

    def addr(self):
        return "127.0.0.1:%d" % self.port

    def stop(self):
        wrote = 0
        try:
            for line in open("/proc/%d/io" % self.proc.pid):
                if line.startswith("write_bytes:"):
                    wrote = int(line.split()[1])
        except OSError:
            pass
        self.proc.send_signal(signal.SIGINT)
        self.proc.wait(timeout=60)
        log = open(os.path.join(self.dir, "relay.log")).read()
        m = re.search(r"relay stopped \((\d+) appends, ([^,]+) in, ([^,]+) out, (\d+) object-store writes, ([^)]+)\)", log)
        row = dict(appends=int(m.group(1)), bytes_in=m.group(2), bytes_out=m.group(3), puts=int(m.group(4)), put_bytes=m.group(5)) if m else {}
        if wrote:
            row["relay_write_bytes"] = wrote
        w = re.search(r"object-store rewrites (\d+) \(([^)]+)\)", log)
        row.update(rewrite_puts=int(w.group(1)) if w else 0, rewrite_bytes=w.group(2) if w else "0 B")
        g = re.search(r"object-store reads (\d+) \(([^)]+)\)", log)
        if g:
            row.update(gets=int(g.group(1)), get_bytes=g.group(2))
        return row


class Device:
    def __init__(self, d, name, relay, env_extra=None, daemon_args=()):
        self.dir = d
        self.home = name
        self.env = dict(os.environ)
        self.env.update(env_extra or {})
        self.daemon = spawn([BIN, "daemon", "--home", name, "--host-plugs", "sealed_store,unlock"] + list(daemon_args), d, name + ".daemon.log", self.env)
        sock = os.path.join(d, name, "run", "daemon.sock")
        for _ in range(200):
            time.sleep(0.05)
            if os.path.exists(sock):
                break
        time.sleep(0.2)
        self.host = spawn([BIN, "host", "--home", name, "--plugs", "sealed_store,unlock", "--store", name + ".store", "--passkey", name + ".pk"], d, name + ".host.log", self.env)
        time.sleep(0.5)
        if relay:
            self.cli("login", "--subject", "user-" + name, "--relay", relay.addr(), "--relay-key", relay.key)

    def cli(self, *args, stdin=None, timeout=120, check=True):
        return run([BIN] + list(args) + ["--home", self.home], self.dir, self.env, stdin=stdin, timeout=timeout, check=check)

    def client(self):
        cwd = os.getcwd()
        os.chdir(self.dir)
        try:
            return Client(os.path.join(self.home, "run", "daemon.sock"))
        finally:
            os.chdir(cwd)

    def stop(self):
        term(self.daemon)
        term(self.host)


def settle(seconds):
    time.sleep(seconds)


class Sampler:
    def __init__(self, relay, total):
        self.relay = relay
        self.marks = set(max(1, total * k // 4) for k in range(1, 5))
        self.rows = []

    def tick(self, i):
        if i in self.marks:
            pack, _ = du(os.path.join(self.relay.dir, "relay", "spaces"))
            obj, files = du(os.path.join(self.relay.dir, "objects"))
            self.rows.append([i, pack, files, obj])


def pack_breakdown(spaces):
    tmp = spaces.rstrip("/") + ".copy"
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(spaces, tmp)
    out = run([PACKLIVE, tmp, tmp], HERE, timeout=120, check=False)
    shutil.rmtree(tmp, ignore_errors=True)
    b = dict(container_bytes=0, container_live=0, sys_stream_bytes=0, object_stream_bytes=0, index_snapshot_bytes=0, top_streams=[])
    streams = []
    for line in out.splitlines():
        m = re.match(r"containers (\d+) bytes, (\d+) live", line)
        if m:
            b["container_live"] = int(m.group(2))
            continue
        m = re.match(r"F (\d+) (.*)", line)
        if not m:
            continue
        size, path = int(m.group(1)), m.group(2)[len(tmp) + 1:]
        parts = path.split("/")
        if len(parts) >= 3 and parts[1] == "s":
            if parts[2].startswith("ffffffffffffffffffffffffffffffff"):
                b["sys_stream_bytes"] += size
            else:
                b["object_stream_bytes"] += size
                streams.append(size)
        elif len(parts) >= 3 and parts[1] == "o":
            b["index_snapshot_bytes"] += size
    for f in os.listdir(spaces):
        if f.startswith("c"):
            b["container_bytes"] += os.path.getsize(os.path.join(spaces, f))
    b["top_streams"] = sorted(streams, reverse=True)[:4]
    b["object_streams"] = len(streams)
    return b


def measure(relay, info, extra=None, sampler=None):
    st = relay.stop()
    pack, _ = du(os.path.join(relay.dir, "relay", "spaces"))
    disk, _ = du(os.path.join(relay.dir, "relay", "spaces"), disk=True)
    obj, files = du(os.path.join(relay.dir, "objects"))
    row = dict(pack_bytes=pack, pack_disk_bytes=disk, object_files=files, object_live_bytes=obj, info_bytes=info)
    row.update(st)
    row.update(extra or {})
    if sampler:
        row["samples"] = sampler.rows
    row["pack"] = pack_breakdown(os.path.join(relay.dir, "relay", "spaces"))
    return row


def scenario_dir(name):
    d = os.path.join(OUT, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    return d


def transcript_messages(path, limit):
    if not path:
        raise RuntimeError("set COST_TRANSCRIPT to a Claude Code session .jsonl")
    out = []
    for line in open(path):
        try:
            e = json.loads(line)
        except Exception:
            continue
        t = e.get("type")
        if t not in ("user", "assistant"):
            continue
        msg = e.get("message") or {}
        c = msg.get("content")
        parts = []
        if isinstance(c, str):
            parts.append(c)
        elif isinstance(c, list):
            for b in c:
                if isinstance(b, dict):
                    if b.get("type") == "text":
                        parts.append(b.get("text", ""))
                    elif b.get("type") == "tool_use":
                        parts.append(json.dumps(b.get("input", {})))
                    elif b.get("type") == "tool_result":
                        r = b.get("content")
                        parts.append(r if isinstance(r, str) else json.dumps(r))
                    elif b.get("type") == "thinking":
                        parts.append(b.get("thinking", ""))
        text = "\n".join(p for p in parts if p)
        if not text:
            continue
        out.append((e.get("uuid") or hashlib.sha1(line.encode()).hexdigest(), t, text))
        if len(out) >= limit:
            break
    return out


def s1_transcript():
    d = scenario_dir("s1_transcript")
    msgs = transcript_messages(TRANSCRIPT, int(os.environ.get("COST_MSGS", "2769")))
    relay = Relay(d)
    dev = Device(d, "a", relay)
    dev.cli("new", "transcript")
    sm = Sampler(relay, len(msgs))
    t0 = time.time()
    for i, (mid, role, text) in enumerate(msgs):
        dev.cli("record", "--source", "claude", "--id", mid, "--seq", str(i + 1), "--role", role, "--stdin", stdin=text)
        sm.tick(i + 1)
    dt = time.time() - t0
    settle(SETTLE)
    dev.stop()
    raw = "\n".join(t for _, _, t in msgs).encode()
    per = sum(zstd3(t.encode()) for _, _, t in msgs)
    return measure(relay, zstd_size(raw), dict(messages=len(msgs), raw_bytes=len(raw), info_per_message_zstd3=per, seconds=round(dt, 1)), sm)


WORDS = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango".split()


def code_line(rng):
    return "    %s = %s(%s, %d)  # %s" % (rng.choice(WORDS), rng.choice(WORDS), rng.choice(WORDS), rng.randint(0, 9999), " ".join(rng.choice(WORDS) for _ in range(rng.randint(2, 8))))


def git(args, cwd):
    return run(["git"] + args, cwd, env=dict(os.environ, GIT_AUTHOR_NAME="bench", GIT_COMMITTER_NAME="bench", GIT_AUTHOR_EMAIL="b@x", GIT_COMMITTER_EMAIL="b@x"))


def s2_rewrites(commit):
    name = "s2b_rewrite_commit" if commit else "s2a_rewrite"
    d = scenario_dir(name)
    rng = random.Random(42)
    repo = os.path.join(d, "repo")
    os.makedirs(repo)
    git(["init", "-q", "-b", "main"], repo)
    files = {"f%d.py" % i: [code_line(rng) for _ in range(200)] for i in range(5)}
    for f, lines in files.items():
        open(os.path.join(repo, f), "w").write("\n".join(lines) + "\n")
    git(["add", "-A"], repo)
    git(["commit", "-q", "-m", "init"], repo)
    if commit:
        run(["git", "init", "-q", "--bare", "remote.git"], d)
        git(["remote", "add", "origin", os.path.join(d, "remote.git")], repo)
        git(["push", "-q", "origin", "main"], repo)
    relay = Relay(d)
    dev = Device(d, "a", relay)
    dev.cli("mount", "repo")
    versions = [("\n".join(l) + "\n").encode() for l in files.values()]
    rewrites = int(os.environ.get("COST_REWRITES", "300"))
    sm = Sampler(relay, rewrites)
    t0 = time.time()
    for i in range(rewrites):
        f = rng.choice(sorted(files))
        lines = files[f]
        for _ in range(rng.randint(1, 6)):
            j = rng.randrange(len(lines))
            lines[j] = code_line(rng)
        if rng.random() < 0.2:
            lines.insert(rng.randrange(len(lines)), code_line(rng))
        data = ("\n".join(lines) + "\n").encode()
        tmp = os.path.join(repo, f + ".tmp")
        open(tmp, "wb").write(data)
        os.replace(tmp, os.path.join(repo, f))
        versions.append(data)
        if commit and (i + 1) % 10 == 0:
            git(["add", "-A"], repo)
            git(["commit", "-q", "-m", "edit %d" % i], repo)
            git(["push", "-q", "origin", "main"], repo)
        time.sleep(0.25)
        sm.tick(i + 1)
    dt = time.time() - t0
    settle(max(8, SETTLE))
    dev.stop()
    final = b"".join(("\n".join(l) + "\n").encode() for l in files.values())
    extra = dict(rewrites=rewrites, seconds=round(dt, 1), info_final=zstd_size(final), info_history=zstd_size(b"".join(versions)))
    if commit:
        extra["git_remote_bytes"] = du(os.path.join(d, "remote.git"))[0]
    return measure(relay, extra["info_history"], extra, sm)


class FakeAnthropic(BaseHTTPRequestHandler):
    reply_bytes = 30000
    delta_bytes = 24
    count = 0

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        self.rfile.read(n)
        FakeAnthropic.count += 1
        corpus = FakeAnthropic.corpus
        at = (FakeAnthropic.count * 7919 * self.reply_bytes) % max(1, len(corpus) - self.reply_bytes)
        text = corpus[at : at + self.reply_bytes]
        FakeAnthropic.texts.append(text)
        raw = []
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()

        def ev(name, obj):
            line = "data: %s" % json.dumps(obj)
            raw.append(line)
            self.wfile.write(("event: %s\n%s\n\n" % (name, line)).encode())

        ev("message_start", {"type": "message_start", "message": {"id": "msg_%d" % self.count, "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
        ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        for i in range(0, len(text), self.delta_bytes):
            ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text[i : i + self.delta_bytes]}})
            self.wfile.flush()
            time.sleep(0.002)
        ev("content_block_stop", {"type": "content_block_stop", "index": 0})
        ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": len(text) // 4}})
        ev("message_stop", {"type": "message_stop"})
        self.wfile.flush()
        FakeAnthropic.raw.append("\n".join(raw))


FakeAnthropic.texts = []
FakeAnthropic.raw = []


def s3_drafts():
    d = scenario_dir("s3_drafts")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeAnthropic)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    FakeAnthropic.texts = []
    FakeAnthropic.raw = []
    FakeAnthropic.count = 0
    FakeAnthropic.corpus = "\n\n".join(t for _, role, t in transcript_messages(TRANSCRIPT, 100000) if role == "assistant")
    url = "http://127.0.0.1:%d" % srv.server_address[1]
    relay = Relay(d)
    dev = Device(d, "a", relay, env_extra={"ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": "x"})
    dev.cli("new", "drafts", "--provider", "native", "--model", "claude-opus-5-5")
    replies = int(os.environ.get("COST_REPLIES", "20"))
    sm = Sampler(relay, replies)
    t0 = time.time()
    for i in range(replies):
        dev.cli("send", "write me a long answer %d" % i, "--wait", timeout=300)
        sm.tick(i + 1)
    dt = time.time() - t0
    settle(SETTLE)
    dev.stop()
    srv.shutdown()
    content = "\n".join(FakeAnthropic.texts).encode()
    raw = "\n".join(FakeAnthropic.raw).encode()
    return measure(relay, zstd_size(content), dict(replies=replies, served=len(FakeAnthropic.texts), reply_bytes=FakeAnthropic.reply_bytes, delta_bytes=FakeAnthropic.delta_bytes, raw_sse_bytes=len(raw), info_raw_lines=zstd_size(raw), info_per_reply_zstd3=sum(zstd3(t.encode()) for t in FakeAnthropic.texts), seconds=round(dt, 1)), sm)


def s4_catalog():
    d = scenario_dir("s4_catalog")
    rng = random.Random(7)
    relay = Relay(d)
    dev = Device(d, "a", relay)
    c = dev.client()
    convos = []
    for i in range(20):
        out = dev.cli("new", "convo %d" % i)
        convos.append(out.split()[-1])
    spaces = c.call("space.list")
    sp = spaces["spaces"][0].get("id") or spaces["spaces"][0].get("space")
    rows = c.call("catalog.list", space=sp, limit=100).get("rows", [])
    objs = [r["object"] for r in rows if r.get("kind") == "conversation"]
    steps = int(os.environ.get("COST_CATALOG_STEPS", "1000"))
    sm = Sampler(relay, steps)
    records = []
    t0 = time.time()
    for i in range(steps):
        o = rng.choice(objs)
        k = rng.random()
        if k < 0.5:
            t = " ".join(rng.choice(WORDS) for _ in range(rng.randint(2, 6)))
            c.call("catalog.set", object=o, set=1, title=t)
        elif k < 0.7:
            c.call("catalog.set", object=o, set=4, pinned=bool(rng.getrandbits(1)))
        elif k < 0.8:
            c.call("catalog.set", object=o, set=2, archived=bool(rng.getrandbits(1)))
        else:
            sid = rng.choice(convos)
            dev.cli("record", sid, "--source", "bench", "--id", "m%d" % i, "--role", "assistant", "--status", rng.choice(["open", "done", "interrupted"]), "ok %d" % i)
            records.append("ok %d" % i)
        sm.tick(i + 1)
    dt = time.time() - t0
    final_rows = c.call("catalog.list", space=sp, limit=100).get("rows", [])
    c.close()
    settle(SETTLE)
    dev.stop()
    final = (json.dumps(sorted(json.dumps(r, sort_keys=True) for r in final_rows)) + "\n".join(records)).encode()
    return measure(relay, zstd_size(final), dict(steps=steps, objects=len(objs), seconds=round(dt, 1)), sm)


def wait_log(path, pattern, timeout):
    t = time.time() + timeout
    while time.time() < t:
        try:
            m = re.findall(pattern, open(path).read())
            if m:
                return len(m)
        except OSError:
            pass
        time.sleep(0.1)
    return 0


def s5_runner():
    global BIN
    saved = BIN
    BIN = BIN_LEASE
    try:
        return _s5_runner()
    finally:
        BIN = saved


def _s5_runner():
    d = scenario_dir("s5_runner")
    lease = int(os.environ.get("COST_LEASE_S", "10"))
    wakes = int(os.environ.get("COST_WAKES", "100"))
    mode = os.environ.get("COST_SLEEP", "restart")
    relay = Relay(d)
    pool = Device(d, "pool", None, daemon_args=["--pool-host"])
    card = ""
    for _ in range(100):
        try:
            card = open(os.path.join(d, "pool", "pool.card")).read().strip()
        except OSError:
            pass
        if card:
            break
        time.sleep(0.1)
    psock = os.path.join("pool", "run", "daemon.sock")
    dev = Device(d, "a", relay, env_extra={"ONDB_POOL_CARD": card, "ONDB_POOL_HOST_SOCK": psock})
    dev.cli("new", "work")
    settle(3)
    token = pool.cli("pool", "token").strip()
    renv = dict(os.environ, ONDB_POOL_HOST_SOCK=psock)
    log = os.path.join(d, "r.log")

    def start(args):
        return spawn([BIN, "runner", "--home", "r"] + args, d, "r.log", renv, "a")

    r = start(["--pool-token", token])
    if not wait_log(log, r"enrolled into [1-9]\d* spaces", 60):
        raise RuntimeError("runner did not enroll:\n" + open(log).read())
    settle(3)
    base_pack, _ = du(os.path.join(relay.dir, "relay", "spaces"))
    base_obj, base_files = du(os.path.join(relay.dir, "objects"))
    sm = Sampler(relay, wakes)
    renewed = 0
    t0 = time.time()
    for w in range(wakes):
        if mode == "freeze":
            os.killpg(r.pid, signal.SIGSTOP)
            time.sleep(lease + 2)
            os.killpg(r.pid, signal.SIGCONT)
        else:
            term(r)
            time.sleep(lease + 2)
            r = start([])
        n = 0
        t = time.time() + 30
        while time.time() < t:
            n = open(log).read().count("the pool renewed the lease")
            if n > renewed:
                break
            time.sleep(0.1)
        renewed = n
        time.sleep(2)
        sm.tick(w + 1)
    dt = time.time() - t0
    term(r)
    dev.stop()
    pool.stop()
    return measure(relay, 0, dict(wakes=wakes, mode=mode, lease_s=lease, renewals=renewed, seconds=round(dt, 1), base_pack=base_pack, base_object_bytes=base_obj, base_object_files=base_files), sm)


class FakeTools(BaseHTTPRequestHandler):
    per_turn = 100
    count = 0

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        msgs = body.get("messages", [])
        done = 0
        for m in reversed(msgs):
            if m.get("role") == "user" and isinstance(m.get("content"), str):
                break
            if m.get("role") == "user":
                done += 1
        FakeTools.count += 1
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()

        def ev(name, obj):
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(obj))).encode())

        ev("message_start", {"type": "message_start", "message": {"id": "msg_%d" % self.count, "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
        if done < self.per_turn:
            path = "f%d.txt" % (FakeTools.count % 5)
            inp = json.dumps({"path": path, "content": "line %d\n" % FakeTools.count * 4})
            ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_%d" % self.count, "name": "write_file", "input": {}}})
            ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": inp}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 1}})
        else:
            ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "done"}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 1}})
        ev("message_stop", {"type": "message_stop"})
        self.wfile.flush()


def proc_writes(pid):
    try:
        for line in open("/proc/%d/io" % pid):
            if line.startswith("write_bytes:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def s6_tool_calls():
    d = scenario_dir("s6_tool_calls")
    FakeTools.count = 0
    FakeTools.per_turn = int(os.environ.get("COST_TOOLS_PER_TURN", "100"))
    total = int(os.environ.get("COST_TOOL_CALLS", "10000"))
    turns = max(1, total // FakeTools.per_turn)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeTools)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d" % srv.server_address[1]
    relay = Relay(d)
    dev = Device(d, "a", relay, env_extra={"ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": "x"})
    conv = dev.cli("new", "tools", "--provider", "native", "--model", "claude-opus-5-5").strip().split()[-1]
    work = os.path.join(d, "work")
    os.makedirs(work)
    dev.cli("mount", work, "--convo", conv, "--name", "work")
    settle(1)
    w0 = proc_writes(dev.daemon.pid)
    samples = []
    t0 = time.time()
    for t in range(turns):
        dev.cli("send", "turn %d" % t, "--wait", timeout=600)
        if (t + 1) * 4 % turns == 0 or t + 1 == turns:
            calls = (t + 1) * FakeTools.per_turn
            w = proc_writes(dev.daemon.pid)
            rss = json.loads(dev.cli("status", "--json")).get("daemon", {}).get("rss", 0)
            pack, _ = du(os.path.join(d, "a", "engine", "pack"))
            samples.append(dict(tool_calls=calls, device_write_bytes=w - w0, write_bytes_per_call=round((w - w0) / calls), daemon_rss=rss, device_pack_bytes=pack))
    dt = time.time() - t0
    dev.stop()
    srv.shutdown()
    return measure(relay, 0, dict(tool_calls=turns * FakeTools.per_turn, turns=turns, seconds=round(dt, 1), device=samples))


def s7_cold_restore():
    d = scenario_dir("s7_cold_restore")
    msgs = transcript_messages(TRANSCRIPT, int(os.environ.get("COST_MSGS", "2769")))
    relay = Relay(d)
    a = Device(d, "a", relay)
    a.cli("new", "transcript")
    for i, (mid, role, text) in enumerate(msgs):
        a.cli("record", "--source", "claude", "--id", mid, "--seq", str(i + 1), "--role", role, "--stdin", stdin=text)
    settle(SETTLE)
    convo = re.search(r'"object":"[0-9a-f]+/([0-9a-f]+)"', a.cli("ls", "--json")).group(1)
    b = Device(d, "b", None)
    card = b.cli("join").strip()
    ticket = a.cli("pair", card).strip().split()[-1]
    b.cli("join", ticket)
    obj = convo
    settle(10)
    a.stop()
    t0 = time.time()
    log = b.cli("log", obj, "-n", str(len(msgs) + 10), "--json", "--timeout", os.environ.get("COST_LOG_TIMEOUT", "600000"), timeout=1800)
    cold = round(time.time() - t0, 1)
    ids = re.findall(r'"msg":"([^"]+)"', log) or re.findall(r'"id":"([^"]+)"', log)
    victim = ids[len(ids) // 10] if ids and os.environ.get("COST_REDACT", "1") != "0" else None
    if victim:
        b.cli("redact", obj, victim)
    settle(max(10, SETTLE))
    b.stop()
    raw = "\n".join(t for _, _, t in msgs).encode()
    return measure(relay, zstd_size(raw), dict(messages=len(msgs), cold_read_seconds=cold, cold_log_bytes=len(log), cold_ids=len(ids), redacted=victim))

SCENARIOS = {"s1": s1_transcript, "s2a": lambda: s2_rewrites(False), "s2b": lambda: s2_rewrites(True), "s3": s3_drafts, "s4": s4_catalog, "s5": s5_runner, "s6": s6_tool_calls, "s7": s7_cold_restore, "s7n": s7_cold_restore}

if __name__ == "__main__":
    names = sys.argv[1:] or list(SCENARIOS)
    results = {}
    for n in names:
        results[n] = SCENARIOS[n]()
        print(n, json.dumps(results[n]), flush=True)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "results-%d.json" % int(time.time())), "w") as f:
        json.dump(results, f, indent=1)
