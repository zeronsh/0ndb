#!/usr/bin/env python3
import json, os, platform, random, shutil, signal, socket, struct, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BIN = os.environ.get("ONDB_BIN", os.path.join(REPO, "bin", "0ndb"))
OUT = os.environ.get("FLOWS_OUT", os.path.join(tempfile.gettempdir(), "flows"))
RUNS = int(os.environ.get("FLOWS_RUNS", "30"))
WINDOWS = os.name == "nt"
LIMIT = [] if WINDOWS else ["bash", "-c", 'ulimit -v 4000000; exec "$@"', "x"]
INSTANT_MS = 50.0
TAIL = 60
PROCS = []


def now():
    return time.perf_counter()


def spawn(args, cwd, log, env):
    group = dict(creationflags=subprocess.CREATE_NEW_PROCESS_GROUP) if WINDOWS else dict(start_new_session=True)
    p = subprocess.Popen(LIMIT + args, cwd=cwd, env=env, stdout=open(os.path.join(cwd, log), "w"), stderr=subprocess.STDOUT, **group)
    PROCS.append(p)
    return p


def stop_proc(p, sig):
    if p.poll() is not None:
        return
    try:
        if WINDOWS:
            p.terminate() if sig == signal.SIGTERM else p.kill()
        else:
            os.killpg(p.pid, sig)
    except Exception:
        pass


def kill_all():
    for p in PROCS:
        stop_proc(p, signal.SIGKILL)


def unix_connect(path):
    if hasattr(socket, "AF_UNIX"):
        s = socket.socket(socket.AF_UNIX)
        s.connect(path)
        return s
    import ctypes
    ws2 = ctypes.WinDLL("ws2_32")
    ws2.socket.restype = ctypes.c_size_t
    ws2.connect.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    data = ctypes.create_string_buffer(512)
    ws2.WSAStartup(0x0202, data)

    class Sun(ctypes.Structure):
        _fields_ = [("family", ctypes.c_ushort), ("path", ctypes.c_char * 108)]

    h = ws2.socket(1, 1, 0)
    sa = Sun(1, path.replace("/", "\\").encode())
    if ws2.connect(h, ctypes.byref(sa), ctypes.sizeof(sa)) != 0:
        ws2.closesocket(ctypes.c_size_t(h))
        raise OSError("connect %s failed: %d" % (path, ws2.WSAGetLastError()))
    return socket.socket(fileno=h)


class Client:
    def __init__(self, path):
        self.s = unix_connect(path)
        self.s.sendall(b"0NDB\x01")
        self.tag = 0
        self.lock = threading.Condition()
        self.results = {}
        self.deltas = {}
        self.closed = False
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        buf = b""
        while True:
            try:
                d = self.s.recv(1 << 20)
            except OSError:
                d = b""
            t = now()
            if not d:
                with self.lock:
                    self.closed = True
                    self.lock.notify_all()
                return
            buf += d
            while len(buf) >= 5:
                ln, kind = struct.unpack("<IB", buf[:5])
                if len(buf) < 5 + ln:
                    break
                body, buf = buf[5 : 5 + ln], buf[5 + ln :]
                tag = struct.unpack("<Q", body[:8])[0]
                with self.lock:
                    if kind == 2:
                        self.results[tag] = (t, body[8], body[9:])
                    elif kind == 4:
                        self.deltas.setdefault(tag, []).append((t, body[8:]))
                    self.lock.notify_all()

    def _send(self, kind, payload):
        self.s.sendall(struct.pack("<IB", len(payload), kind) + payload)

    def call_async(self, op, timeout_ms=60000, **args):
        with self.lock:
            self.tag += 1
            tag = self.tag
        self._send(1, struct.pack("<QBQ", tag, 1, timeout_ms) + json.dumps(dict(op=op, **args)).encode())
        return tag

    def wait_result(self, tag, timeout=120):
        end = now() + timeout
        with self.lock:
            while tag not in self.results:
                if self.closed:
                    raise RuntimeError("daemon closed the connection")
                left = end - now()
                if left <= 0:
                    raise RuntimeError("timed out waiting for result %d" % tag)
                self.lock.wait(left)
            t, st, body = self.results.pop(tag)
        return t, st, json.loads(body or b"{}")

    def call(self, op, timeout_ms=60000, **args):
        _, st, res = self.wait_result(self.call_async(op, timeout_ms, **args), timeout_ms / 1000 + 10)
        if st != 0:
            raise RuntimeError("%s %s -> status %d %s" % (op, json.dumps(args)[:200], st, res))
        return res

    def subscribe(self, **req):
        with self.lock:
            self.tag += 1
            tag = self.tag
        self._send(3, struct.pack("<QB", tag, 1) + json.dumps(req).encode())
        _, st, res = self.wait_result(tag)
        if st != 0:
            raise RuntimeError("subscribe %s -> status %d %s" % (req, st, res))
        return tag, res

    def take(self, tag):
        with self.lock:
            out = self.deltas.pop(tag, [])
        return out

    def wait_delta(self, tag, pred, timeout=30):
        end = now() + timeout
        with self.lock:
            while True:
                got = self.deltas.get(tag, [])
                for i, (t, body) in enumerate(got):
                    try:
                        v = json.loads(body)
                    except Exception:
                        v = None
                    if pred(v):
                        self.deltas[tag] = got[i + 1 :]
                        return t, v
                self.deltas[tag] = []
                left = end - now()
                if left <= 0 or self.closed:
                    return None, None
                self.lock.wait(left)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


class Daemon:
    def __init__(self, d, env_extra=None):
        self.dir = d
        base = tempfile.gettempdir()
        self.rt = tempfile.mkdtemp(prefix="0f", dir=base if len(base) < 40 else "/tmp")
        self.env = dict(os.environ, ONDB_HOME=os.path.join(d, "home"), ONDB_RUNTIME_DIR=self.rt)
        self.env.update(env_extra or {})
        self.proc = spawn([BIN, "daemon"], d, "daemon.log", self.env)
        self.sock = os.path.join(self.rt, "daemon.sock")
        for _ in range(400):
            if os.path.exists(self.sock):
                break
            time.sleep(0.025)
        self.space = None

    def cli(self, *args, timeout=120):
        p = subprocess.run(LIMIT + [BIN] + list(args) + ["--json"], cwd=self.dir, env=self.env, capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0:
            raise RuntimeError("0ndb %s -> %d %s%s" % (" ".join(args), p.returncode, p.stdout, p.stderr))
        return json.loads(p.stdout or "{}")

    def client(self):
        return Client(self.sock)

    def default_space(self):
        if not self.space:
            obj = self.cli("new", "flows-space")["object"]
            self.space = obj.split("/")[0]
        return self.space

    def stop(self):
        if self.proc.poll() is None:
            stop_proc(self.proc, signal.SIGTERM)
            try:
                self.proc.wait(timeout=30)
            except Exception:
                stop_proc(self.proc, signal.SIGKILL)
        shutil.rmtree(self.rt, ignore_errors=True)


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def row(flow, samples, instant, notes=None, parts=None):
    ms = [s * 1000 for s in samples]
    r = dict(flow=flow, runs=len(ms), p50_ms=round(pct(ms, 50), 2) if ms else None, p95_ms=round(pct(ms, 95), 2) if ms else None, max_ms=round(max(ms), 2) if ms else None, instant=instant)
    if parts:
        r["parts"] = {k: dict(p50_ms=round(pct([x * 1000 for x in v], 50), 2), p95_ms=round(pct([x * 1000 for x in v], 95), 2)) for k, v in parts.items() if v}
    r["slow"] = bool(instant and ms and pct(ms, 95) > INSTANT_MS)
    if notes:
        r["notes"] = notes
    return r


def flow_dir(name):
    d = os.path.join(OUT, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    return d


class FakeAnthropic(BaseHTTPRequestHandler):
    arrivals = []
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        FakeAnthropic.arrivals.append(now())
        self.rfile.read(int(self.headers.get("content-length", "0")))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()

        def ev(name, obj):
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(obj))).encode())
            self.wfile.flush()

        ev("message_start", {"type": "message_start", "message": {"id": "msg_flows", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [], "stop_reason": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})
        ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        for i in range(8):
            ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "token%d " % i}})
        ev("content_block_stop", {"type": "content_block_stop", "index": 0})
        ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 8}})
        ev("message_stop", {"type": "message_stop"})


def has_kind(v, *kinds, draft=None):
    if not v:
        return False
    for dl in v.get("deltas", []):
        if dl.get("kind") in kinds and (draft is None or bool(dl.get("draft")) == draft) and (draft is None or dl.get("text")):
            return True
    return False


def has_token(v):
    if not v:
        return False
    return any(dl.get("kind") in ("block", "chunk") and "token" in (dl.get("text") or "") for dl in v.get("deltas", []))


def is_idle(v):
    if not v:
        return False
    for dl in v.get("deltas", []):
        if dl.get("kind") == "status" and dl.get("status") == "idle":
            return True
    return False


def f_send_first_token():
    d = flow_dir("send_first_token")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeAnthropic)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    FakeAnthropic.arrivals = []
    dm = Daemon(d, {"ANTHROPIC_BASE_URL": "http://127.0.0.1:%d" % srv.server_address[1], "ANTHROPIC_API_KEY": "x"})
    try:
        obj = dm.cli("new", "flows-send", "--provider", "native", "--model", "claude-opus-5-5")["object"]
        c = dm.client()
        tag, _ = c.subscribe(op="subscribe", object=obj, kind="conversation")
        first, request, ack = [], [], []
        for i in range(RUNS):
            c.take(tag)
            n = len(FakeAnthropic.arrivals)
            t0 = now()
            st = c.call_async("send", object=obj, text="flows message %d" % i)
            t1, _ = c.wait_delta(tag, has_token)
            if t1 is None:
                _, sst, sres = c.wait_result(st, 5)
                raise RuntimeError("no streamed token for send %d (send status %d %s, provider requests %d)" % (i, sst, sres, len(FakeAnthropic.arrivals) - n))
            ta, _, _ = c.wait_result(st)
            first.append(t1 - t0)
            ack.append(ta - t0)
            if len(FakeAnthropic.arrivals) > n:
                request.append(FakeAnthropic.arrivals[n] - t0)
            c.wait_delta(tag, lambda v: has_kind(v, "seal"), timeout=30)
            time.sleep(0.05)
        c.close()
        return row("send → first streamed token", first, True, "native provider against an instant local SSE endpoint, so this is 0ndb's own cost", dict(send_acked=ack, provider_request=request))
    finally:
        dm.stop()
        srv.shutdown()


def f_cli_first_token():
    d = flow_dir("cli_first_token")
    runs = int(os.environ.get("FLOWS_CLI_RUNS", "3"))
    picks = dict(claude="haiku")
    dm = Daemon(d)
    out = []
    try:
        listed = dm.cli("models").get("providers", [])
        dm.cli("new", "flows-runners")
        signed = set()
        for rn in dm.cli("runners").get("runners", []):
            signed.update(rn.get("signed_in", []))
        print("cli flow: providers %s" % [(p.get("id"), p.get("available")) for p in listed], file=sys.stderr, flush=True)
        wanted = os.environ.get("FLOWS_CLI_PROVIDERS", "claude,codex").split(",")
        for pr in listed:
            if pr.get("id") not in wanted:
                continue
            if not pr.get("available") or pr.get("id") not in signed:
                out.append(dict(flow="%s send → first token" % pr.get("id"), runs=0, notes="skipped: %s" % ("not signed in" if pr.get("available") else pr.get("error") or "not installed")))
                continue
            pid = pr["id"]
            model = picks.get(pid) or next((m["id"] for m in pr.get("models", []) if m.get("default")), "")
            args = ["new", "flows-" + pid, "--provider", pid] + (["--model", model] if model else [])
            obj = dm.cli(*args)["object"]
            print("cli flow: %s ready" % pid, file=sys.stderr, flush=True)
            c = dm.client()
            tag, _ = c.subscribe(op="subscribe", object=obj, kind="conversation")
            first, started = [], []
            note = "real provider CLI; model latency included"
            prompt = "Reply with just the word ok."
            for i in range(runs):
                c.take(tag)
                t0 = now()
                c.call_async("send", object=obj, text=prompt)
                ts, _ = c.wait_delta(tag, lambda v: v and any(dl.get("kind") == "status" and dl.get("status") == "running" for dl in v.get("deltas", [])), timeout=20)
                tf, _ = c.wait_delta(tag, lambda v: v and any(dl.get("kind") in ("block", "chunk") and dl.get("block") == "text" and dl.get("text") and dl.get("text") != prompt for dl in v.get("deltas", [])), timeout=60)
                if ts:
                    started.append(ts - t0)
                if not tf:
                    note = "no reply within 60s" + ("" if ts else ", and the run never started")
                    break
                first.append(tf - t0)
                c.wait_delta(tag, is_idle, timeout=60)
                print("cli flow: %s run %d first token %.2fs" % (pid, i, tf - t0), file=sys.stderr, flush=True)
            c.close()
            out.append(row("%s (%s) send → first token" % (pid, model or "default"), first, False, note, dict(run_started=started)))
        return out
    finally:
        dm.stop()


def f_convo_window():
    d = flow_dir("convo_window")
    dm = Daemon(d)
    try:
        obj = dm.cli("new", "flows-10k")["object"]
        c = dm.client()
        n = int(os.environ.get("FLOWS_MESSAGES", "10000"))
        rng = random.Random(7)
        words = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike".split()
        t0 = now()
        pending = []
        for i in range(n):
            text = " ".join(rng.choice(words) for _ in range(rng.randint(5, 120)))
            pending.append(c.call_async("record", object=obj, source="flows", external_id="m%d" % i, sequence=i + 1, role="user" if i % 2 == 0 else "assistant", blocks=[dict(kind="text", text=text)]))
            if len(pending) >= 64:
                for t in pending:
                    c.wait_result(t)
                pending = []
        for t in pending:
            c.wait_result(t)
        fill = now() - t0
        c.close()
        open_s, page_s, jump_s, sub_s, win_s = [], [], [], [], []
        mid = None
        notes_keys = []
        for i in range(RUNS):
            cc = dm.client()
            t0 = now()
            tag, _ = cc.subscribe(op="subscribe", object=obj, kind="conversation")
            t1 = now()
            cc.call("convo.settings", object=obj)
            t2 = now()
            head = cc.call("convo.status", object=obj).get("head")
            w = cc.call("convo.window", object=obj, anchor=head, before=TAIL)
            t3 = now()
            sub_s.append(t1 - t0)
            win_s.append(t3 - t2)
            open_s.append(t3 - t0)
            cursor = w.get("older_cursor")
            msgs = w.get("messages") or []
            if mid is None and msgs:
                mid = msgs[0].get("rid") or msgs[0].get("msg") or msgs[0].get("id")
                notes_keys.append(sorted(msgs[0].keys()))
            if cursor:
                t4 = now()
                cc.call("convo.page", object=obj, cursor=cursor, limit=TAIL)
                page_s.append(now() - t4)
            if mid:
                t5 = now()
                cc.call("convo.window", object=obj, anchor=mid, before=30, after=30)
                jump_s.append(now() - t5)
            cc.close()
        notes = "%d messages recorded in %.1fs; message keys %s" % (n, fill, notes_keys[:1])
        return [row("conversation open (subscribe, status, settings, window tail %d) on %d messages" % (TAIL, n), open_s, True, notes, dict(subscribe=sub_s, window=win_s)), row("conversation page (%d older) on %d messages" % (TAIL, n), page_s, True), row("conversation jump (window ±30 around a message)", jump_s, True)]
    finally:
        dm.stop()


def make_repo(root, files, rng):
    os.makedirs(root)
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, check=True)
    for i in range(files):
        p = os.path.join(root, "d%02d" % (i % 40), "f%04d.txt" % i)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write("".join("line %d of file %d %s\n" % (j, i, rng.random()) for j in range(rng.randint(5, 40))))
    genv = dict(os.environ, GIT_AUTHOR_NAME="flows", GIT_COMMITTER_NAME="flows", GIT_AUTHOR_EMAIL="f@x", GIT_COMMITTER_EMAIL="f@x")
    subprocess.run(["git", "add", "-A"], cwd=root, check=True, env=genv)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=root, check=True, env=genv)


def mount_tree(dm, c, root):
    tree = c.call("tree.create", space=dm.default_space(), title=os.path.basename(root))["object"]
    c.call("mount.add", object=tree, root=root, timeout_ms=600000)
    return tree


def f_tree_events():
    d = flow_dir("tree_events")
    dm = Daemon(d)
    try:
        root = os.path.join(d, "work")
        make_repo(root, 20, random.Random(3))
        c = dm.client()
        tree = mount_tree(dm, c, root)
        tag, _ = c.subscribe(op="subscribe", object=tree, kind="tree")
        time.sleep(1.0)
        c.take(tag)
        agent, agent_list, person, person_list = [], [], [], []
        w = dm.client()
        for i in range(RUNS):
            base = w.call("tree.list", object=tree, path="").get("base")
            t0 = now()
            w.call_async("tree.write", object=tree, path="agent/a%03d.txt" % i, text="agent write %d\n" % i, base=base)
            t1, _ = c.wait_delta(tag, lambda v: True, timeout=30)
            if t1 is None:
                raise RuntimeError("no tree event for agent write %d" % i)
            c.call("tree.list", object=tree, path="")
            agent.append(t1 - t0)
            agent_list.append(now() - t0)
            time.sleep(0.05)
            c.take(tag)
        for i in range(RUNS):
            p = os.path.join(root, "d00", "f0000.txt")
            t0 = now()
            with open(p, "a") as f:
                f.write("person edit %d\n" % i)
            t1, _ = c.wait_delta(tag, lambda v: True, timeout=30)
            if t1 is None:
                raise RuntimeError("no tree event for person edit %d" % i)
            c.call("tree.list", object=tree, path="d00")
            person.append(t1 - t0)
            person_list.append(now() - t0)
            time.sleep(0.05)
            c.take(tag)
        w.close()
        c.close()
        return [row("agent file write (tree.write) → tree event", agent, True, None, dict(with_tree_list=agent_list)), row("person disk edit → tree event", person, True, None, dict(with_tree_list=person_list))]
    finally:
        dm.stop()


def f_buffer_keystroke():
    d = flow_dir("buffer_keystroke")
    dm = Daemon(d)
    try:
        root = os.path.join(d, "work")
        make_repo(root, 5, random.Random(4))
        c = dm.client()
        tree = mount_tree(dm, c, root)
        a, b = dm.client(), dm.client()
        ta, oa = a.subscribe(op="buffer.open", object=tree, path="d00/f0000.txt")
        tb, ob = b.subscribe(op="buffer.open", object=tree, path="d00/f0000.txt")
        buf = oa.get("buffer")
        rev = oa.get("rev", 0)
        time.sleep(0.5)
        b.take(tb)
        a.take(ta)
        lat = []
        for i in range(RUNS):
            t0 = now()
            r = a.call("buffer.edit", buffer=buf, rev=rev, pos=[0], ins=["k"], **{"del": [0]})
            rev = r.get("rev", rev)
            t1, _ = b.wait_delta(tb, lambda v: True, timeout=10)
            if t1 is None:
                raise RuntimeError("second subscriber never saw keystroke %d" % i)
            lat.append(t1 - t0)
            a.take(ta)
            time.sleep(0.02)
        a.close()
        b.close()
        c.close()
        return row("buffer keystroke → second subscriber", lat, True, "open result keys %s" % sorted(oa.keys()))
    finally:
        dm.stop()


def f_mount_open():
    d = flow_dir("mount_open")
    files = int(os.environ.get("FLOWS_REPO_FILES", "3000"))
    runs = int(os.environ.get("FLOWS_MOUNT_RUNS", "5"))
    dm = Daemon(d)
    try:
        c = dm.client()
        add, listed, warm = [], [], []
        for i in range(runs):
            root = os.path.join(d, "repo%d" % i)
            make_repo(root, files, random.Random(100 + i))
            tree = c.call("tree.create", space=dm.default_space(), title="repo%d" % i)["object"]
            t0 = now()
            c.call("mount.add", object=tree, root=root, timeout_ms=600000)
            t1 = now()
            c.call("tree.list", object=tree, path="d00")
            add.append(t1 - t0)
            listed.append(now() - t0)
            for _ in range(10):
                t2 = now()
                c.call("tree.list", object=tree, path="d%02d" % random.randrange(40))
                warm.append(now() - t2)
        c.close()
        return [row("mount first open of a %d-file repo" % files, add, False, None, dict(until_tree_list=listed)), row("tree.list of one directory in a %d-file tree (after the first)" % files, warm, True)]
    finally:
        dm.stop()


def f_branch_switch():
    return dict(flow="branch switch → files materialized", runs=0, notes="stub until 8770a918's PR 1 lands")


FLOWS = dict(send=f_send_first_token, cli=f_cli_first_token, window=f_convo_window, tree=f_tree_events, buffer=f_buffer_keystroke, mount=f_mount_open, switch=f_branch_switch)


def main():
    names = sys.argv[1:] or [n for n in FLOWS if n != "cli" or os.environ.get("FLOWS_CLI")]
    os.makedirs(OUT, exist_ok=True)
    rows = []
    try:
        for n in names:
            try:
                r = FLOWS[n]()
            except Exception as e:
                r = dict(flow=n, error=str(e)[:500])
            for x in r if isinstance(r, list) else [r]:
                rows.append(x)
                print(json.dumps(x), flush=True)
    finally:
        kill_all()
    path = os.path.join(OUT, "results-%d.json" % int(time.time()))
    json.dump(dict(host=platform.node(), platform=sys.platform, rows=rows), open(path, "w"), indent=1)
    print("\n%-70s %9s %9s  %s" % ("flow", "p50 ms", "p95 ms", ""))
    for r in rows:
        if "p50_ms" in r:
            print("%-70s %9s %9s  %s" % (r["flow"][:70], r["p50_ms"], r["p95_ms"], "SLOW" if r.get("slow") else ""))
            for k, v in (r.get("parts") or {}).items():
                print("    %-66s %9s %9s" % (k, v["p50_ms"], v["p95_ms"]))
        else:
            print("%-70s %s" % (r["flow"][:70], r.get("error") or r.get("notes")))
    print("results: " + path)


if __name__ == "__main__":
    main()
