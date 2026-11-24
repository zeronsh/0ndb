#!/usr/bin/env python3
import argparse, json, os, platform, random, re, shutil, signal, socket, struct, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
WINDOWS = os.name == "nt"
LIMIT = [] if WINDOWS else ["bash", "-c", 'ulimit -v 4000000; exec "$@"', "x"]
MODEL = "claude-opus-5-5"
AGENT_PATHS = 24
PERSON_PATHS = 12


def now():
    return time.perf_counter()


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
        self.closed = False
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        buf = b""
        while True:
            try:
                d = self.s.recv(1 << 20)
            except OSError:
                d = b""
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
                        self.results[tag] = (body[8], body[9:])
                    self.lock.notify_all()

    def call(self, op, timeout_ms=120000, **args):
        with self.lock:
            self.tag += 1
            tag = self.tag
        payload = struct.pack("<QBQ", tag, 1, timeout_ms) + json.dumps(dict(op=op, **args)).encode()
        self.s.sendall(struct.pack("<IB", len(payload), 1) + payload)
        end = now() + timeout_ms / 1000 + 10
        with self.lock:
            while tag not in self.results:
                if self.closed:
                    raise RuntimeError("%s: the daemon closed the connection" % op)
                left = end - now()
                if left <= 0:
                    raise RuntimeError("%s: no answer in %d ms" % (op, timeout_ms))
                self.lock.wait(left)
            st, body = self.results.pop(tag)
        res = json.loads(body or b"{}")
        if st != 0:
            raise Status(op, st, res)
        return res

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


class Status(Exception):
    def __init__(self, op, st, res):
        Exception.__init__(self, "%s -> status %d %s" % (op, st, json.dumps(res)[:300]))
        self.st = st


class Plan:
    lock = threading.Lock()
    writes = []
    requests = 0


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", "0"))) or b"{}")
        msgs = body.get("messages", [])
        last_user = 0
        for i, m in enumerate(msgs):
            c = m.get("content")
            if m.get("role") == "user" and (isinstance(c, str) or any(isinstance(b, dict) and b.get("type") == "text" for b in (c or []))):
                last_user = i
        done = sum(1 for m in msgs[last_user + 1 :] if m.get("role") == "assistant" and any(isinstance(b, dict) and b.get("type") == "tool_use" for b in (m.get("content") or [])))
        with Plan.lock:
            Plan.requests += 1
            writes = list(Plan.writes)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()

        def ev(name, obj):
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(obj))).encode())
            self.wfile.flush()

        ev("message_start", {"type": "message_start", "message": {"id": "msg_soak", "type": "message", "role": "assistant", "model": MODEL, "content": [], "stop_reason": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})
        if done < len(writes):
            path, content = writes[done]
            ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_s%d_%d" % (len(msgs), done), "name": "write_file", "input": {}}})
            ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps({"path": path, "content": content})}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 1}})
        else:
            ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "done %d" % len(writes)}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 1}})
        ev("message_stop", {"type": "message_stop"})


class Daemon:
    def __init__(self, d, port, bin_path):
        self.dir = d
        self.bin = bin_path
        base = tempfile.gettempdir()
        self.rt = tempfile.mkdtemp(prefix="0s", dir=base if len(base) < 40 else "/tmp")
        self.env = dict(os.environ, ONDB_HOME=os.path.join(d, "home"), ONDB_RUNTIME_DIR=self.rt, ANTHROPIC_BASE_URL="http://127.0.0.1:%d" % port, ANTHROPIC_API_KEY="x")
        self.proc = None
        self.start()

    def start(self):
        group = dict(creationflags=subprocess.CREATE_NEW_PROCESS_GROUP) if WINDOWS else dict(start_new_session=True)
        self.log = open(os.path.join(self.dir, "daemon.log"), "a")
        self.proc = subprocess.Popen(LIMIT + [self.bin, "daemon"], cwd=self.dir, env=self.env, stdout=self.log, stderr=subprocess.STDOUT, **group)
        self.sock = os.path.join(self.rt, "daemon.sock")
        for _ in range(800):
            if os.path.exists(self.sock):
                try:
                    Client(self.sock).close()
                    return
                except OSError:
                    pass
            if self.proc.poll() is not None:
                raise RuntimeError("the daemon exited at start with %s" % self.proc.returncode)
            time.sleep(0.025)
        raise RuntimeError("the daemon socket never appeared")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                if WINDOWS:
                    self.proc.terminate()
                else:
                    os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=60)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        try:
            os.remove(self.sock)
        except OSError:
            pass
        self.log.close()

    def cli(self, *args):
        p = subprocess.run(LIMIT + [self.bin] + list(args) + ["--json"], cwd=self.dir, env=self.env, capture_output=True, text=True, timeout=120)
        if p.returncode != 0:
            raise RuntimeError("0ndb %s -> %d %s%s" % (" ".join(args), p.returncode, p.stdout, p.stderr))
        return json.loads(p.stdout or "{}")


def sample_proc(pid):
    out = dict(rss_kb=None, fds=None, cpu_s=None, ctx=None)
    try:
        if sys.platform.startswith("linux"):
            for line in open("/proc/%d/status" % pid):
                if line.startswith("VmRSS:"):
                    out["rss_kb"] = int(line.split()[1])
            out["fds"] = len(os.listdir("/proc/%d/fd" % pid))
            st = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
            out["cpu_s"] = (int(st[11]) + int(st[12])) / os.sysconf("SC_CLK_TCK")
            ctx = 0
            for t in os.listdir("/proc/%d/task" % pid):
                for line in open("/proc/%d/task/%s/status" % (pid, t)):
                    if "ctxt_switches" in line:
                        ctx += int(line.split()[1])
            out["ctx"] = ctx
        elif sys.platform == "darwin":
            r = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
            out["rss_kb"] = int(r[0])
            m, s = r[1].split(":")
            out["cpu_s"] = int(m) * 60 + float(s)
            out["fds"] = max(0, len(subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True).stdout.splitlines()) - 1)
        elif WINDOWS:
            r = subprocess.run(["powershell", "-NoProfile", "-Command", "$p = Get-Process -Id %d; \"$($p.WorkingSet64) $($p.HandleCount) $($p.TotalProcessorTime.TotalSeconds)\"" % pid], capture_output=True, text=True).stdout.split()
            out["rss_kb"] = int(r[0]) // 1024
            out["fds"] = int(r[1])
            out["cpu_s"] = float(r[2])
    except Exception:
        pass
    return out


def du(path):
    n = 0
    for d, _, fs in os.walk(path):
        for f in fs:
            try:
                n += os.path.getsize(os.path.join(d, f))
            except OSError:
                pass
    return n


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def git(root, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="soak", GIT_COMMITTER_NAME="soak", GIT_AUTHOR_EMAIL="s@x", GIT_COMMITTER_EMAIL="s@x")
    p = subprocess.run(["git"] + list(args), cwd=root, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("git %s -> %s" % (" ".join(args), p.stderr.strip()[:300]))
    return p.stdout


class Node:
    def __init__(self, rid, role, parent, state, order):
        self.rid, self.role, self.parent, self.state, self.order = rid, role, parent, state, order
        self.children = []


class Soak:
    def __init__(self, args):
        self.args = args
        self.rng = random.Random(args.seed)
        self.dir = args.dir or tempfile.mkdtemp(prefix="soak-")
        os.makedirs(self.dir, exist_ok=True)
        self.root = os.path.join(self.dir, "work")
        self.lat = {}
        self.minute = []
        self.findings = []
        self.steps = 0
        self.nodes = {}
        self.order = 0
        self.position = None
        self.person = {}
        self.base = {}
        self.undos = []
        self.lastline = ""
        self.log = open(os.path.join(self.dir, "steps.jsonl"), "w")

    def note(self, **kv):
        kv["step"] = self.steps
        kv["t"] = round(time.time() - self.t0, 1)
        self.log.write(json.dumps(kv) + "\n")
        self.log.flush()

    def timed(self, op, fn, *a, **kw):
        t = now()
        r = fn(*a, **kw)
        self.lat.setdefault(op, []).append(now() - t)
        return r

    def setup(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        os.makedirs(self.root)
        git(self.root, "init", "-q", "-b", "main")
        for i in range(40):
            p = "src/m%02d.txt" % i
            os.makedirs(os.path.dirname(os.path.join(self.root, p)), exist_ok=True)
            data = "".join("line %d of %s\n" % (j, p) for j in range(10 + i))
            open(os.path.join(self.root, p), "w", newline="").write(data)
            self.base[p] = data.encode()
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "base")
        self.dm = Daemon(self.dir, self.srv.server_address[1], self.args.bin)
        self.c = Client(self.dm.sock)
        self.obj = self.dm.cli("new", "soak", "--provider", "native", "--model", MODEL)["object"]
        space = self.obj.split("/")[0]
        self.tree = self.c.call("tree.create", space=space, title="soak")["object"]
        self.c.call("mount.add", object=self.tree, root=self.root, timeout_ms=600000)
        self.c.call("mount", object=self.obj, name="work", tree=self.tree.split("/")[1], path="work")
        self.check("setup")

    def expected(self):
        e = dict(self.base)
        st = self.nodes[self.position].state if self.position else {}
        e.update({p: v.encode() for p, v in st.items()})
        e.update({p: v.encode() for p, v in self.person.items()})
        return e

    def disk(self):
        out = {}
        for d, dirs, fs in os.walk(self.root):
            if ".git" in dirs:
                dirs.remove(".git")
            for f in fs:
                full = os.path.join(d, f)
                rel = os.path.relpath(full, self.root).replace(os.sep, "/")
                try:
                    out[rel] = open(full, "rb").read()
                except OSError:
                    pass
        return out

    def settle(self):
        end = now() + 30
        last = None
        while now() < end:
            try:
                v = self.timed("verify", self.c.call, "verify", root=self.root, timeout_ms=60000)
                last = v
                if not v.get("mismatches"):
                    return None
            except Status as e:
                last = str(e)
            time.sleep(0.2)
        return last

    def check(self, what):
        bad = self.settle()
        want, got = self.expected(), self.disk()
        diffs = []
        for p in sorted(set(want) | set(got)):
            if want.get(p) != got.get(p):
                diffs.append("%s: want %s got %s" % (p, (want.get(p) or b"<absent>")[:60], (got.get(p) or b"<absent>")[:60]))
        if bad:
            diffs.append("verify still reports %s" % json.dumps(bad)[:300])
        if diffs:
            self.fail("bytes", "after %s: %d differences: %s" % (what, len(diffs), "; ".join(diffs[:6])))
            return False
        return True

    def fail(self, kind, msg, cls=None):
        for f in self.findings:
            if cls and f.get("cls") == cls:
                f["count"] += 1
                self.note(finding=kind, cls=cls, msg=msg)
                return
        self.findings.append(dict(kind=kind, step=self.steps, t=round(time.time() - self.t0, 1), msg=msg, cls=cls, count=1))
        self.note(finding=kind, msg=msg)
        print("FINDING step %d %s: %s" % (self.steps, kind, msg), flush=True)

    def plan(self, tag):
        k = self.rng.randint(1, 3)
        writes = []
        for j in range(k):
            p = "soak/a%02d.txt" % self.rng.randrange(AGENT_PATHS)
            writes.append((p, "%s write %d at step %d\n" % (tag, j, self.steps)))
        with Plan.lock:
            Plan.writes = writes
        return writes

    def apply(self, parent_state, writes):
        st = dict(parent_state)
        for p, v in writes:
            st[p] = v
        return st

    def wait_reply(self, user, known):
        end = now() + 120
        while now() < end:
            st = self.c.call("convo.status", object=self.obj)
            head = st.get("head")
            if head and not st.get("running") and st.get("status") in ("idle", None):
                w = self.c.call("convo.window", object=self.obj, anchor=head, before=4)
                for m in w.get("messages") or []:
                    if m.get("role") == "assistant" and m.get("parent") == user and m.get("id") not in known and m.get("seal"):
                        return m["id"], st
            time.sleep(0.05)
        raise RuntimeError("no sealed reply to %s within 120 s (status %s)" % (user, json.dumps(st)[:300]))

    def add(self, rid, role, parent, state):
        self.order += 1
        n = Node(rid, role, parent, state, self.order)
        self.nodes[rid] = n
        if parent:
            self.nodes[parent].children.append(rid)
        return n

    def wait_position(self, what, want):
        t = now()
        st = {}
        while now() - t < 30:
            st = self.c.call("convo.status", object=self.obj)
            if st.get("position") == want:
                self.lat.setdefault(what + " position lag", []).append(now() - t)
                return True
            time.sleep(0.01)
        got = st.get("position")
        self.fail("position", "%s: the position is %s 30 s later, the model expected %s" % (what, got, want))
        if got in self.nodes or got is None:
            self.position = got
        return False

    def path(self):
        out, r = [], self.position
        while r:
            out.append(r)
            r = self.nodes[r].parent
        return list(reversed(out))

    def turn(self, parent=None, root=False, op="turn"):
        writes = self.plan(op)
        args = dict(object=self.obj, text="soak %s %d" % (op, self.steps))
        if parent:
            args["parent"] = parent
        elif root:
            args["root"] = True
        else:
            parent = self.position
        base = self.nodes[parent].state if parent else {}
        t = now()
        r = self.timed(op + " send", self.c.call, "send", **args)
        user = r["item"]
        self.add(user, "user", parent, base)
        reply, _ = self.wait_reply(user, set())
        self.lat.setdefault(op + " to seal", []).append(now() - t)
        self.add(reply, "assistant", user, self.apply(base, writes))
        self.position = reply
        self.wait_position(op, reply)
        self.check(op)

    def regenerate(self):
        users = [r for r in self.path() if self.nodes[r].role == "user"]
        if not users:
            return self.turn()
        u = self.rng.choice(users)
        writes = self.plan("regen")
        known = set(self.nodes[u].children)
        t = now()
        self.c.call("regenerate", object=self.obj, msg=u)
        reply, _ = self.wait_reply(u, known)
        self.lat.setdefault("regenerate", []).append(now() - t)
        self.add(reply, "assistant", u, self.apply(self.nodes[u].state, writes))
        self.position = reply
        self.wait_position("regenerate", reply)
        self.check("regenerate of %s" % u)

    def edit(self):
        users = [r for r in self.path() if self.nodes[r].role == "user"]
        if not users:
            return self.turn()
        u = self.rng.choice(users)
        p = self.nodes[u].parent
        self.turn(parent=p, root=p is None, op="edit")

    def newest_leaf(self, rid):
        best, stack = None, [rid]
        while stack:
            r = stack.pop()
            n = self.nodes[r]
            if not n.children:
                if best is None or n.order > self.nodes[best].order:
                    best = r
            stack.extend(n.children)
        return best

    def switch(self):
        cands = []
        for r in self.path():
            n = self.nodes[r]
            sibs = [s for s in (self.nodes[n.parent].children if n.parent else [x for x in self.nodes if self.nodes[x].parent is None]) if s != r]
            for s in sibs:
                cands.append(s)
        if not cands:
            return self.edit()
        s = self.rng.choice(cands)
        want = self.newest_leaf(s)
        res = self.timed("switch", self.c.call, "switch", object=self.obj, sibling=s, timeout_ms=120000)
        st = self.c.call("convo.status", object=self.obj)
        got = st.get("position") or res.get("leaf")
        if got != want:
            if got in self.nodes:
                self.fail("position", "switch to %s went to %s, the model expected its newest leaf %s" % (s, got, want))
                self.position = got
            else:
                self.fail("position", "switch to %s went to %s, which the model does not know" % (s, got))
                return
        else:
            self.position = want
        self.check("switch to %s" % s)

    def undo(self):
        users = [r for r in self.path() if self.nodes[r].role == "user"]
        if not users:
            return self.turn()
        u = self.rng.choice(users[-3:])
        before = self.position
        res = self.timed("undo", self.c.call, "undo", object=self.obj, msg=u)
        self.undos.append((res.get("undo"), before, u))
        self.position = self.nodes[u].parent
        self.wait_position("undo", self.position)
        self.check("undo of %s" % u)

    def redo(self):
        if not self.undos:
            return self.undo()
        uid, back, u = self.undos.pop()
        self.timed("redo", self.c.call, "redo", object=self.obj, undo=uid)
        st, t = {}, now()
        while now() - t < 5 and st.get("position") != back:
            st = self.c.call("convo.status", object=self.obj)
            time.sleep(0.01)
        if st.get("position") != back:
            tip = st.get("position")
            self.settle()
            self.position = back
            held = self.disk() == self.expected()
            self.fail("position", "redo of %s left the position at %s after 5 s, the model expected %s; the disk %s the redone files" % (uid, tip, back, "holds" if held else "does not hold"), "redo-position")
            self.position = self.newest_leaf(u)
            self.c.call("switch", object=self.obj, sibling=u)
            self.wait_position("resync", self.position)
            self.check("resync after redo")
            return
        self.position = back
        self.check("redo")

    def person_edit(self):
        p = "person/p%02d.txt" % self.rng.randrange(PERSON_PATHS)
        if p in self.person and self.rng.random() < 0.3:
            del self.person[p]
            os.remove(os.path.join(self.root, *p.split("/")))
        else:
            v = self.person.get(p, "") + "person line at step %d\n" % self.steps
            os.makedirs(os.path.dirname(os.path.join(self.root, *p.split("/"))), exist_ok=True)
            open(os.path.join(self.root, *p.split("/")), "w", newline="").write(v)
            self.person[p] = v
        self.timed("tree.sync", self.sync)
        self.check("person edit of %s" % p)

    def sync(self):
        for _ in range(20):
            try:
                return self.c.call("tree.sync", object=self.tree, root=self.root, timeout_ms=60000)
            except Status:
                time.sleep(0.2)

    def git_step(self):
        if self.rng.random() < 0.5 and self.person:
            git(self.root, "add", "-A", "person")
            git(self.root, "commit", "-q", "-m", "person at step %d" % self.steps)
            what = "git commit"
        else:
            b = "soak-%d" % self.steps
            git(self.root, "checkout", "-q", "-b", b)
            self.timed("tree.sync", self.sync)
            git(self.root, "checkout", "-q", "main")
            what = "git checkout -b %s and back" % b
        self.timed("tree.sync", self.sync)
        self.check(what)

    def restart(self):
        self.c.close()
        t = now()
        self.dm.stop()
        self.dm.start()
        self.c = Client(self.dm.sock)
        self.lat.setdefault("restart", []).append(now() - t)
        self.check("restart")

    def sample(self, minute):
        time.sleep(1.0)
        a = sample_proc(self.dm.proc.pid)
        time.sleep(3.0)
        b = sample_proc(self.dm.proc.pid)
        row = dict(minute=minute, steps=self.steps, nodes=len(self.nodes), rss_mb=round((b["rss_kb"] or 0) / 1024, 1), fds=b["fds"], home_mb=round(du(os.path.join(self.dir, "home")) / 1e6, 2))
        if a["cpu_s"] is not None and b["cpu_s"] is not None:
            row["idle_cpu_ms"] = round((b["cpu_s"] - a["cpu_s"]) * 1000, 1)
        if a["ctx"] is not None and b["ctx"] is not None:
            row["idle_ctx"] = b["ctx"] - a["ctx"]
        row["lat"] = {k: dict(n=len(v), p50=round(pct(v, 50) * 1000, 1), p95=round(pct(v, 95) * 1000, 1)) for k, v in self.lat.items() if v}
        self.lat = {}
        self.minute.append(row)
        print(json.dumps(row), flush=True)

    def growth(self):
        rows = self.minute[2:]
        if len(rows) < 6:
            return
        third = max(2, len(rows) // 3)
        early, late = rows[:third], rows[-third:]

        def med(xs):
            xs = [x for x in xs if x is not None]
            return pct(xs, 50) if xs else None

        for key, slack, scale in (("rss_mb", 30.0, 1.25), ("fds", 16, 1.25)):
            e, l = med([r.get(key) for r in early]), med([r.get(key) for r in late])
            if e is not None and l is not None and l > e * scale and l > e + slack:
                self.fail("growth", "%s rose from %.1f to %.1f over the session" % (key, e, l))
        ops = set()
        for r in rows:
            ops.update(r["lat"])
        for op in sorted(ops):
            e = med([r["lat"][op]["p95"] for r in early if op in r["lat"]])
            l = med([r["lat"][op]["p95"] for r in late if op in r["lat"]])
            if e is not None and l is not None and l > e * 1.5 and l > e + 20:
                self.fail("growth", "%s p95 rose from %.1f ms to %.1f ms over the session" % (op, e, l))
        e, l = med([r.get("idle_cpu_ms") for r in early]), med([r.get("idle_cpu_ms") for r in late])
        if e is not None and l is not None and l > e + 50:
            self.fail("growth", "idle CPU per 3 s rose from %.1f ms to %.1f ms" % (e, l))

    def run(self):
        self.t0 = time.time()
        self.setup()
        end = time.time() + self.args.minutes * 60
        next_sample = time.time() + 60
        next_restart = time.time() + self.args.restart * 60
        minute = 0
        steps = [(self.turn, 30), (self.edit, 10), (self.regenerate, 10), (self.switch, 15), (self.undo, 8), (self.redo, 7), (self.person_edit, 13), (self.git_step, 7)]
        total = sum(w for _, w in steps)
        while time.time() < end:
            self.steps += 1
            x = self.rng.randrange(total)
            for fn, w in steps:
                if x < w:
                    break
                x -= w
            try:
                self.note(op=fn.__name__)
                fn()
            except Exception as e:
                self.fail("error", "%s: %s" % (fn.__name__, e))
                if len([f for f in self.findings if f["kind"] == "error"]) > 5:
                    break
            if len(self.findings) > 20 or (self.findings and self.args.stop):
                break
            if time.time() >= next_restart:
                self.steps += 1
                self.note(op="restart")
                try:
                    self.restart()
                except Exception as e:
                    self.fail("error", "restart: %s" % e)
                    break
                next_restart = time.time() + self.args.restart * 60
            if time.time() >= next_sample:
                minute += 1
                self.sample(minute)
                next_sample = time.time() + 60
        self.growth()

    def close(self):
        try:
            self.c.close()
            self.dm.stop()
        except Exception:
            pass
        self.srv.shutdown()


def main():
    for f in (sys.stdout, sys.stderr):
        try:
            f.reconfigure(encoding="utf-8", line_buffering=True)
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="Soak a real daemon with a user-shaped session against a byte-exact model of the mounted repo.")
    ap.add_argument("--minutes", type=float, default=10)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--restart", type=float, default=10, help="minutes between daemon restarts")
    ap.add_argument("--dir", default="")
    ap.add_argument("--bin", default=os.environ.get("ONDB_BIN", os.path.join(REPO, "bin", "0ndb.exe" if WINDOWS else "0ndb")))
    ap.add_argument("--stop", action="store_true", help="stop at the first finding")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    s = Soak(args)
    try:
        s.run()
    except Exception as e:
        s.fail("error", "setup: %s" % e)
    finally:
        s.close()
    summary = dict(host=platform.node(), platform=sys.platform, minutes=args.minutes, seed=args.seed, steps=s.steps, nodes=len(s.nodes), findings=s.findings, dir=s.dir)
    json.dump(dict(summary=summary, minutes=s.minute), open(os.path.join(s.dir, "soak.json"), "w"), indent=1)
    print("soak %s seed %d: %d steps over %.0f min, %d messages, %d findings" % (sys.platform, args.seed, s.steps, args.minutes, len(s.nodes), len(s.findings)))
    for f in s.findings:
        print("  %s at step %d (%.0f s)%s: %s" % (f["kind"], f["step"], f["t"], " x%d" % f["count"] if f["count"] > 1 else "", f["msg"]))
    print("result: %s (log %s)" % ("PASS" if not s.findings else "FAIL", os.path.join(s.dir, "steps.jsonl")))
    if not args.keep and not s.findings:
        shutil.rmtree(s.dir, ignore_errors=True)
    sys.exit(0 if not s.findings else 1)


if __name__ == "__main__":
    main()
