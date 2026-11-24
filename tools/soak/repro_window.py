import sys, os, shutil, tempfile, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import soak
from http.server import ThreadingHTTPServer
soak.isolate.__globals__["__file__"] = os.path.abspath(__file__)
soak.isolate()
d = tempfile.mkdtemp(prefix="window-"); root = os.path.join(d, "work")
srv = ThreadingHTTPServer(("127.0.0.1", 0), soak.Provider); threading.Thread(target=srv.serve_forever, daemon=True).start()
os.makedirs(root); soak.git(root, "init", "-q", "-b", "main"); open(os.path.join(root, "base.txt"), "w").write("base\n"); soak.git(root, "add", "-A"); soak.git(root, "commit", "-q", "-m", "b")
dm = soak.Daemon(d, srv.server_address[1], sys.argv[1]); c = soak.Client(dm.sock)
def idle(u, known):
    end = time.time() + 60
    while time.time() < end:
        st = c.call("convo.status", object=obj)
        if st.get("head") and not st.get("running"):
            for m in c.call("convo.window", object=obj, anchor=st["head"], leaf=st["head"], before=4)["messages"]:
                if m["role"] == "assistant" and m.get("parent") == u and m["id"] not in known and m.get("seal"): return m["id"]
        time.sleep(0.02)
    raise RuntimeError("no reply")
def turn(tag):
    with soak.Plan.lock: soak.Plan.writes = []
    u = c.call("send", object=obj, text="turn " + tag)["item"]
    return u, idle(u, ())
def show(what, anchor, **kw):
    try: c.call("convo.window", object=obj, anchor=anchor, before=1, **kw); r = "ok"
    except soak.Status as e: r = str(e)
    print("%-58s %s" % (what, r), flush=True)
try:
    obj = dm.cli("new", "r", "--provider", "native", "--model", soak.MODEL)["object"]
    u1, r1 = turn("one"); u2, r2 = turn("two")
    c.call("regenerate", object=obj, msg=u1); r1b = idle(u1, {r1})
    show("position r1b (depth 2), anchor r2 (depth 4, other branch)", r2)
    c.call("switch", object=obj, sibling=r1); time.sleep(1)
    print("position is r2:", c.call("convo.status", object=obj).get("position") == r2, flush=True)
    show("position r2 (depth 4), anchor r1b (depth 2, other branch)", r1b)
    show("same, with leaf=r1b", r1b, leaf=r1b)
finally:
    c.close(); dm.stop(); srv.shutdown(); shutil.rmtree(d, ignore_errors=True)
