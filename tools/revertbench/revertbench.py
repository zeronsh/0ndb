import base64, hashlib, json, os, shlex, signal, stat, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.environ["RB_COSTBENCH"])
import harness as H
sys.path.insert(0, HERE)
import rbop

OP = os.path.join(HERE, "rbop.py")
PY = os.environ.get("RB_PYTHON", sys.executable)
WIN = os.name == "nt"
NOOP = os.environ.get("RB_NOOP", "0") != "0"
BROKEN = os.environ.get("RB_BROKEN", "")
PERSON = os.environ.get("RB_PERSON", "api")
PERSON_SETTLE = float(os.environ.get("RB_PERSON_SETTLE", "1.5"))
HOLD = float(os.environ.get("RB_HOLD", "4"))
CRASH_DELAYS = [float(x) for x in os.environ.get("RB_CRASH_DELAYS", "0,0.001,0.002,0.003,0.004,0.005,0.006,0.007,0.008,0.01,0.013").split(",") if x]


def parse_value(v):
    ex = False
    if v.endswith("+x"):
        v, ex = v[:-2], True
    if v == '""':
        return b"", ex
    if "\\n" in v:
        return v.replace("\\n", "\n").encode(), ex
    if v.isdigit() and len(v) >= 4:
        return rbop.big(int(v)), ex
    return (v + "\n").encode(), ex


def parse_setup(s):
    tree = {}
    for tok in s.split():
        if "->" in tok:
            p, t = tok.split("->", 1)
            tree[p] = ("link", t)
        elif tok.endswith("/="):
            tree[tok[:-2]] = ("dir",)
        else:
            p, v = tok.split("=", 1)
            data, ex = parse_value(v)
            tree[p] = ("file", data, ex)
    return with_parents(tree)


def with_parents(tree):
    out = dict(tree)
    for p in list(tree):
        parts = p.split("/")
        for i in range(1, len(parts)):
            out.setdefault("/".join(parts[:i]), ("dir",))
    return out


def parse_ops(s):
    ops = []
    for part in s.split(";"):
        w = shlex.split(part.strip(), posix=True) if part.strip() else []
        if not w:
            continue
        k = w[0]
        if k in ("write", "person"):
            text = w[2] if len(w) > 2 else ""
            text = text.replace("\\n", "\n") if "\\n" in text else (text + "\n" if text else "")
            ops.append({"op": k, "path": w[1], "data": base64.b64encode(text.encode()).decode()})
        elif k in ("write_bin", "write_big"):
            ops.append({"op": k, "path": w[1], "n": int(w[2])})
        elif k == "mv":
            ops.append({"op": "mv", "path": w[1], "to": w[2]})
        elif k == "ln_s":
            ops.append({"op": "ln_s", "target": w[1], "path": w[2]})
        else:
            ops.append({"op": k, "path": w[1]})
    return ops


def model_apply(tree, op):
    t = dict(tree)
    k, p = op["op"], op.get("path")
    if k in ("write", "person"):
        old = t.get(p)
        ex = old[2] if old and old[0] == "file" else False
        t[p] = ("file", base64.b64decode(op["data"]), ex)
    elif k == "write_bin":
        t[p] = ("file", rbop.binary(op["n"]), False)
    elif k == "write_big":
        t[p] = ("file", rbop.big(op["n"]), False)
    elif k == "mkdir":
        t[p] = ("dir",)
    elif k in ("rm", "rmdir"):
        t.pop(p, None)
    elif k == "rmtree":
        for q in list(t):
            if q == p or q.startswith(p + "/"):
                t.pop(q)
    elif k == "mv":
        to = op["to"]
        for q in sorted(list(t)):
            if q == p or q.startswith(p + "/"):
                t[to + q[len(p):]] = t.pop(q)
    elif k in ("chmod_x", "chmod_nx"):
        f = t[p]
        t[p] = ("file", f[1], k == "chmod_x")
    elif k == "ln_s":
        t[p] = ("link", op["target"])
    return with_parents(t)


def key(entry):
    if entry[0] == "file":
        return ("file", hashlib.sha256(entry[1]).hexdigest()[:16], len(entry[1]), entry[2] and not WIN)
    return entry


def snapshot(root):
    out = {}
    for dp, dirs, files in os.walk(root, followlinks=False):
        rel = os.path.relpath(dp, root)
        for d in sorted(dirs):
            p = os.path.join(dp, d)
            k = os.path.normpath(os.path.join(rel, d)).replace(os.sep, "/")
            out[k] = ("link", os.readlink(p)) if os.path.islink(p) else ("dir",)
        dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(dp, d)))
        for f in sorted(files):
            p = os.path.join(dp, f)
            k = os.path.normpath(os.path.join(rel, f)).replace(os.sep, "/")
            if os.path.islink(p):
                out[k] = ("link", os.readlink(p))
                continue
            with open(p, "rb") as fh:
                data = fh.read()
            out[k] = ("file", data, (not WIN) and bool(os.stat(p).st_mode & stat.S_IXUSR))
    return out


def diff(want, got):
    lines = []
    for k in sorted(set(want) | set(got)):
        a = key(want[k]) if k in want else None
        b = key(got[k]) if k in got else None
        if a != b:
            lines.append("%s: want %s got %s" % (k, a, b))
    return lines


class Turns:
    dev = None
    ops = {}
    seen = {}
    workdir = ""
    calls = 0
    lock = threading.Lock()


def shell_command(ops):
    blob = base64.b64encode(json.dumps(ops).encode()).decode()
    cmd = '"%s" "%s" "%s" "%s"' % (PY, OP, blob, Turns.workdir)
    cmd = "& " + cmd if WIN else cmd
    linger = os.environ.get("RB_LINGER", "0")
    return cmd + ("; Start-Sleep " if WIN else " ; sleep ") + linger if linger != "0" else cmd


class FakeProvider(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        msgs = body.get("messages", [])
        done = 0
        prompt = ""
        for m in reversed(msgs):
            c = m.get("content")
            texts = [x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text"] if isinstance(c, list) else []
            results = [x for x in c if isinstance(x, dict) and x.get("type") == "tool_result"] if isinstance(c, list) else []
            if m.get("role") == "user" and (isinstance(c, str) or (texts and not results)):
                prompt = c if isinstance(c, str) else " ".join(texts)
                break
            if m.get("role") == "user":
                done += 1
        prompt = prompt.strip()
        with Turns.lock:
            Turns.calls += 1
            calls = Turns.calls
            if done == 0:
                Turns.seen[prompt] = Turns.seen.get(prompt, 0) + 1
            first = Turns.seen.get(prompt, 0) <= 1
            plan = Turns.ops.get(prompt, []) if first else []
            steps = []
            for op in plan:
                if op["op"] == "person":
                    if steps and steps[-1][0] == "person":
                        steps[-1][1].append(op)
                    else:
                        steps.append(["person", [op]])
                else:
                    steps.append(["agent", [op]])
            agent_steps = [i for i, s in enumerate(steps) if s[0] == "agent"]
            if done < len(agent_steps):
                i = agent_steps[done]
                j = agent_steps[done - 1] if done > 0 else -1
                for s in steps[j + 1:i]:
                    if s[0] == "person":
                        for op in s[1]:
                            person_write(Turns.dev, Turns.workdir, op)
                call = steps[i][1]
            else:
                call = None
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()

        def ev(name, obj):
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(obj))).encode())

        ev("message_start", {"type": "message_start", "message": {"id": "msg_%d" % calls, "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [], "stop_reason": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})
        if call is not None:
            inp = json.dumps({"command": shell_command(call)})
            ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_%d" % calls, "name": "shell", "input": {}}})
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


def trailing_person(ops):
    tail = []
    for op in reversed(ops):
        if op["op"] != "person":
            break
        tail.insert(0, op)
    return tail


def make_tree(root, tree):
    for p in sorted(tree):
        e = tree[p]
        full = os.path.join(root, *p.split("/"))
        if e[0] == "dir":
            os.makedirs(full, exist_ok=True)
    for p in sorted(tree):
        e = tree[p]
        full = os.path.join(root, *p.split("/"))
        if e[0] == "file":
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(e[1])
            if e[2] and not WIN:
                os.chmod(full, os.stat(full).st_mode | 0o111)
        elif e[0] == "link":
            os.symlink(e[1], full)


def message_ids(dev):
    ids = {}
    for line in dev.cli("log", "--json", check=False).splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        for b in m.get("blocks", []):
            if b.get("kind") == "text" and b.get("text") in Turns.ops:
                ids.setdefault(b["text"], m["id"])
    return ids


def broken(want):
    w = dict(want)
    if BROKEN == "add":
        w["zz_broken"] = ("dir",)
        return w
    if BROKEN == "missing":
        if not w:
            return None
        w.pop(sorted(w)[-1])
        return w
    for k in sorted(w):
        if w[k][0] == "file" and BROKEN == "bytes":
            w[k] = ("file", w[k][1] + b"!", w[k][2])
            return w
        if w[k][0] == "file" and BROKEN == "exec" and not WIN:
            w[k] = ("file", w[k][1], not w[k][2])
            return w
    return None


def match_and_hold(root, want, seconds=20):
    if NOOP:
        seconds = 3
    if BROKEN:
        want, seconds = broken(want), 3
        if want is None:
            return ["n/a"]
    t0 = time.time()
    dl = diff(want, snapshot(root))
    while dl and time.time() - t0 < seconds:
        time.sleep(0.25)
        dl = diff(want, snapshot(root))
    if dl:
        return dl
    t1 = time.time()
    while time.time() - t1 < HOLD:
        time.sleep(0.25)
        dl = diff(want, snapshot(root))
        if dl:
            return ["matched, then diverged after %.1f s: " % (time.time() - t1) + "; ".join(dl)]
    return []


def cli_raw(dev, *args, timeout=120):
    p = subprocess.run(H.LIMIT + [H.BIN] + list(args) + ["--home", dev.home], cwd=dev.dir, env=dev.env, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def status(dev, obj):
    c = dev.client()
    try:
        return c.call("convo.status", object=obj)
    finally:
        c.close()


def operate(dev, obj, work, want, *args):
    errs = []
    before = status(dev, obj)["position"]
    calls0 = Turns.calls
    if NOOP:
        rc, out, err = 0, '{"done":true,"undo":"%s"}' % ("0" * 32), ""
    else:
        rc, out, err = cli_raw(dev, *args, "--json")
    if rc != 0:
        errs.append("exit %d: %s" % (rc, (err or out)[-160:]))
    v = {}
    try:
        v = json.loads(out) if out else {}
    except ValueError:
        pass
    if args[0] in ("undo", "redo", "regenerate") and rc == 0 and not v.get("undo"):
        errs.append("no undo id in the answer")
    t0 = time.time()
    st = status(dev, obj)
    while time.time() - t0 < 20:
        ran = args[0] != "regenerate" or Turns.calls > calls0
        if st["position"] != before and ran and not st["running"] and st["status"] == "idle":
            break
        if NOOP and time.time() - t0 > 2:
            break
        time.sleep(0.2)
        st = status(dev, obj)
    if st["position"] == before:
        errs.append("position did not move (%s)" % before)
    if args[0] == "regenerate" and Turns.calls == calls0:
        errs.append("the regenerated turn never ran")
    dl = match_and_hold(work, want)
    return errs, dl, v, "%s -> %s" % (before, st["position"])


class Case:
    def __init__(self, line):
        f = [x.strip() for x in line.split("|")]
        self.name, self.setup_s, self.ops_s = f[0], f[1], f[2]
        self.note = f[3] if len(f) > 3 else ""
        self.pre = parse_setup(self.setup_s)
        self.ops = parse_ops(self.ops_s)
        post = self.pre
        for op in self.ops:
            post = model_apply(post, op)
        self.post = post
        undo = self.pre
        for op in self.ops:
            if op["op"] == "person":
                undo = model_apply(undo, op)
        if len(f) > 4 and f[4]:
            toks = f[4].split()
            undo = dict(undo, **parse_setup(" ".join(t for t in toks if not t.startswith("!"))))
            for t in toks:
                if t.startswith("!"):
                    undo.pop(t[1:], None)
        self.undone = undo
        self.uses_links = any(e[0] == "link" for e in list(self.pre.values()) + list(self.post.values()))


def start(d, url):
    relay = H.Relay(d)
    dev = H.Device(d, "a", relay, env_extra={"ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": "x"})
    return relay, dev


def restart(dev):
    H.term(dev.daemon, 5)
    H.term(dev.host, 5)
    nd = H.Device.__new__(H.Device)
    nd.dir, nd.home, nd.env = dev.dir, dev.home, dev.env
    nd.daemon = H.spawn([H.BIN, "daemon", "--home", nd.home, "--host-plugs", "sealed_store,unlock"], nd.dir, nd.home + ".daemon.log", nd.env, mode="a")
    sock = os.path.join(nd.dir, nd.home, "run", "daemon.sock")
    for _ in range(200):
        time.sleep(0.05)
        if os.path.exists(sock):
            break
    time.sleep(0.2)
    nd.host = H.spawn([H.BIN, "host", "--home", nd.home, "--plugs", "sealed_store,unlock", "--store", nd.home + ".store", "--passkey", nd.home + ".pk"], nd.dir, nd.home + ".host.log", nd.env, mode="a")
    time.sleep(0.5)
    return nd


def kill9(dev):
    for p in (dev.daemon, dev.host):
        try:
            if WIN:
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True)
            else:
                os.killpg(p.pid, signal.SIGKILL)
            p.wait(timeout=10)
        except Exception:
            pass


def run_case(case, out_root, url, crash, run="undo"):
    res = {"case": case.name, "steps": [], "ok": True, "run": run}
    if WIN and case.uses_links:
        res["skipped"] = "symlinks need admin or Developer Mode on Windows"
        return res
    d = os.path.join(out_root, case.name + ("_crash%g" % crash if crash is not None else "_" + run))
    import shutil
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    relay, dev = start(d, url)
    work = os.path.join(d, "work")
    os.makedirs(work)
    make_tree(work, case.pre)
    prompt = "case %s %d" % (case.name, int(time.time() * 1000) % 100000)
    Turns.ops[prompt] = case.ops
    Turns.workdir = work
    Turns.dev = dev

    def record(name, errs, dl, note):
        na = dl == ["n/a"]
        res["steps"].append({"step": name, "errs": errs, "diff": dl, "note": note, "na": na})
        if errs or (dl and not na):
            res["ok"] = False

    def op(name, want, *args):
        errs, dl, v, note = operate(dev, obj, work, want, *args)
        record(name, errs, dl, note)
        return v

    try:
        conv = dev.cli("new", case.name, "--provider", "native", "--model", "claude-opus-5-5").strip().split()[-1]
        obj = [x["object"] for x in json.loads(dev.cli("ls", "--json")) if x["object"].endswith(conv)][0]
        dev.cli("mount", work, "--convo", conv, "--name", "work")
        time.sleep(1)
        record("mount", [], match_and_hold(work, case.pre), "")
        rc, out, err = cli_raw(dev, "send", prompt, "--wait", timeout=300)
        if trailing_person(case.ops):
            time.sleep(PERSON_SETTLE)
        _trailing(case, work)
        time.sleep(PERSON_SETTLE)
        record("turn", ["exit %d: %s" % (rc, err[-160:])] if rc else [], match_and_hold(work, case.post), "")
        msg = message_ids(dev).get(prompt)
        if not msg:
            raise RuntimeError("no message id for the turn")
        if not BROKEN and not NOOP and not res["ok"]:
            raise RuntimeError("setup or turn not as modelled; the operations were not run")
        if crash is not None:
            p = subprocess.Popen(H.LIMIT + [H.BIN, "undo", msg, "--home", dev.home], cwd=dev.dir, env=dev.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(crash)
            inside = p.poll() is None
            kill9(dev)
            try:
                p.kill()
            except OSError:
                pass
            at_kill = snapshot(work)
            same = not diff(case.undone, case.post)
            phase = "same-tree" if same else ("before" if not diff(case.post, at_kill) else ("after" if not diff(case.undone, at_kill) else "during"))
            try:
                p.wait(timeout=10)
            except Exception:
                p.kill()
            dev = restart(dev)
            Turns.dev = dev
            time.sleep(4)
            got = snapshot(work)
            a, b = diff(case.undone, got), diff(case.post, got)
            st0 = status(dev, obj)
            res["phase"] = phase
            res["undo_recorded"] = st0["position"] is None
            res["after_restart"] = "same-tree" if same else ("pre" if not a else ("post" if not b else "mix"))
            res["cli_still_running"] = inside
            record("crash undo", [], [] if (not a or not b) else ["mix: vs pre-turn " + "; ".join(a[:4]) + " || vs post-turn " + "; ".join(b[:4])], "killed %s the tree changed; undo recorded after restart: %s; state after restart %s" % (phase, res["undo_recorded"], res["after_restart"]))
            if not res["undo_recorded"]:
                cli_raw(dev, "continue")
                cli_raw(dev, "undo", msg)
            t0 = time.time()
            while status(dev, obj)["position"] is not None and time.time() - t0 < 20:
                time.sleep(0.3)
            record("retried undo", [] if status(dev, obj)["position"] is None else ["position is not before the turn"], match_and_hold(work, case.undone), "")
            return res
        if res["run"] == "undo":
            v = op("undo", case.undone, "undo", msg)
            op("redo", case.post, "redo", v.get("undo", "0" * 32))
            op("undo again", case.undone, "undo", msg)
        elif res["run"] == "redo-regenerate":
            v = op("undo", case.undone, "undo", msg)
            op("redo", case.post, "redo", v.get("undo", "0" * 32))
            op("regenerate after redo", case.undone, "regenerate", msg)
        else:
            op("regenerate", case.undone, "regenerate", msg)
            op("switch back", case.post, "switch", "prev")
            op("switch forward", case.undone, "switch", "next")
    except Exception as ex:
        res["ok"] = False
        res["error"] = repr(ex)
    finally:
        try:
            dev.stop()
            relay.stop()
        except Exception:
            pass
        if not res["ok"]:
            with open(os.path.join(d, "repro.json"), "w") as f:
                json.dump({"case": case.name, "setup": case.setup_s, "ops": case.ops_s, "crash": crash, "result": res}, f, indent=1)
    return res


def _cap(out, s):
    out.append(s.strip())
    return s


def _trailing(case, work):
    for op in trailing_person(case.ops):
        person_write(Turns.dev, work, op)
    return ""


def person_write(dev, work, op):
    if PERSON == "disk":
        p = os.path.join(work, *op["path"].split("/"))
        with open(p, "wb") as f:
            f.write(base64.b64decode(op["data"]))
        return
    c = dev.client()
    try:
        f = c.call("tree.find", path=work)
        obj = f["object"]
        rel = f.get("rel", "")
        path = (rel + "/" if rel else "") + op["path"]
        base = c.call("tree.list", object=obj, path="")["base"]
        c.call("tree.write", object=obj, path=path, text=base64.b64decode(op["data"]).decode(), base=base)
    finally:
        c.close()


def _wait_idle(dev):
    time.sleep(3)
    return ""


def load_cases(path):
    cases = []
    for line in open(path, encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            cases.append(Case(line.rstrip("\n")))
    return cases


def main():
    cases = load_cases(os.environ["RB_CASES"])
    pick = sys.argv[1:]
    if pick:
        cases = [c for c in cases if c.name in pick]
    out_root = os.environ.get("RB_OUT", os.path.join(HERE, "out"))
    os.makedirs(out_root, exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeProvider)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d" % srv.server_address[1]
    results = []
    runs = [] if os.environ.get("RB_CRASH_ONLY", "0") != "0" else [("undo", None), ("switch", None), ("redo-regenerate", None)]
    runs += ([("undo", x) for x in CRASH_DELAYS] if os.environ.get("RB_CRASH", "1") != "0" else [])
    for c in cases:
        for run, crash in runs:
            r = run_case(c, out_root, url, crash, run)
            results.append(r)
            bad = ["%s: %s" % (x["step"], "; ".join(x["errs"] + ([] if x["na"] else x["diff"][:3]))) for x in r["steps"] if x["errs"] or (x["diff"] and not x["na"])]
            inside = " kill=%s recorded=%s restart=%s" % (r["phase"], r["undo_recorded"], r["after_restart"]) if "phase" in r else ""
            print("%-18s %-16s %s%s %s" % (c.name, "crash%g" % crash if crash is not None else run, "SKIP " + r["skipped"] if r.get("skipped") else ("ok" if r["ok"] else "FAIL"), inside, (r.get("error", "") + " " + " | ".join(bad))[:700]), flush=True)
            if r.get("skipped"):
                break
    phases = {}
    for r in results:
        if "phase" in r:
            k = (r["phase"], r["undo_recorded"], r["after_restart"])
            phases[k] = phases.get(k, 0) + 1
    for k, n in sorted(phases.items()):
        print("KILL %d runs: killed %s the tree changed, undo recorded=%s, after restart=%s" % ((n,) + k), flush=True)
    if NOOP or BROKEN:
        names = {"undo", "redo", "undo again", "regenerate", "regenerate after redo", "switch back", "switch forward"}
        checked = [(r["case"], r["run"], x) for r in results for x in r["steps"] if not x["na"] and (BROKEN or x["step"] in names)]
        passed = [(c, r, x["step"]) for c, r, x in checked if not x["errs"] and not x["diff"]]
        print("NEGATIVE CONTROL %s: %d steps checked, %d n/a, %d wrongly passed %s" % ("noop" if NOOP else "broken=" + BROKEN, len(checked), sum(x["na"] for r in results for x in r["steps"]), len(passed), passed[:10]), flush=True)
    with open(os.path.join(out_root, "results.json"), "w") as f:
        json.dump(results, f, indent=1, default=str)
    srv.shutdown()


if __name__ == "__main__":
    main()
