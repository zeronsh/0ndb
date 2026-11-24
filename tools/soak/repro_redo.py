import sys, os, shutil, tempfile, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import soak
from http.server import ThreadingHTTPServer
def scenario(name, new_turn, finish):
    d = tempfile.mkdtemp(prefix="redo-"); root = os.path.join(d, "work")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), soak.Provider); threading.Thread(target=srv.serve_forever, daemon=True).start()
    os.makedirs(root); soak.git(root, "init", "-q", "-b", "main"); open(os.path.join(root, "base.txt"), "w").write("base\n"); soak.git(root, "add", "-A"); soak.git(root, "commit", "-q", "-m", "b")
    dm = soak.Daemon(d, srv.server_address[1], sys.argv[1]); c = soak.Client(dm.sock)
    try:
        obj = dm.cli("new", "r", "--provider", "native", "--model", soak.MODEL)["object"]
        tree = c.call("tree.create", space=obj.split("/")[0], title="r")["object"]
        c.call("mount.add", object=tree, root=root); c.call("mount", object=obj, name="work", tree=tree.split("/")[1], path="work")
        def turn(tag):
            with soak.Plan.lock: soak.Plan.writes = [("%s.txt" % tag, tag + "\n")]
            u = c.call("send", object=obj, text="turn " + tag)["item"]
            end = time.time() + 60
            while time.time() < end:
                st = c.call("convo.status", object=obj)
                if st.get("head") and not st.get("running"):
                    for m in c.call("convo.window", object=obj, anchor=st["head"], before=4)["messages"]:
                        if m["role"] == "assistant" and m.get("parent") == u and m.get("seal"): return u, m["id"]
                time.sleep(0.02)
            raise RuntimeError("no reply")
        u1, r1 = turn("one"); u2, r2 = turn("two")
        un = c.call("undo", object=obj, msg=u2)["undo"]
        time.sleep(1)
        names = {r1: "r1", r2: "r2", u1: "u1", u2: "u2"}
        if new_turn:
            u3, r3 = turn("three"); names.update({u3: "u3", r3: "r3"})
        res = c.call("redo", object=obj, undo=un) if finish == "redo" else c.call("switch", object=obj, sibling=u2)
        for k in range(50):
            time.sleep(0.2)
            st = c.call("convo.status", object=obj)
            if st.get("position") == r2: break
        files = sorted(f for f in os.listdir(root) if f.endswith(".txt"))
        print("%-34s result=%s position=%s head=%s browsing=%s files=%s" % (name, {k: res.get(k) for k in ("done", "leaf")} if res else None, names.get(st.get("position"), st.get("position")), names.get(st.get("head")), st.get("browsing"), files), flush=True)
    finally:
        c.close(); dm.stop(); srv.shutdown(); shutil.rmtree(d, ignore_errors=True)
scenario("undo, redo", False, "redo")
scenario("undo, new turn, redo", True, "redo")
scenario("undo, new turn, switch back", True, "switch")
