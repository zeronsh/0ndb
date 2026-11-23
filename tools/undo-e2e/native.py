import json, os, sys, time, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakes
H = fakes.H

FAILS = []

def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)

def main():
    d = os.path.join(os.environ["E2E_OUT"], "native")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    fakes.FakeAnthropic.contents = {1: "one\n", 2: "one\ntwo\n", 3: "one\nthree\n"}
    srv, url = fakes.serve()
    relay = H.Relay(d)
    dev = H.Device(d, "a", relay, env_extra={"ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": "x"})
    try:
        out = dev.cli("new", "u", "--provider", "native", "--model", "claude-opus-5-5").strip()
        print(out)
        conv = out.split()[-1]
        work = os.path.join(d, "work")
        os.makedirs(work)
        if os.environ.get("GITINIT"):
            import subprocess
            subprocess.run(["git", "init", "-q", "-b", "main", work], check=True)
            open(os.path.join(work, "README"), "w").write("r\n")
            subprocess.run(["git", "-C", work, "add", "."], check=True)
            subprocess.run(["git", "-C", work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], check=True)
        print(dev.cli("mount", work, "--convo", conv, "--name", "work").strip())
        H.settle(1)
        for i in (1, 2):
            print(dev.cli("send", "turn%d" % i, "--wait", timeout=120).strip())
            H.settle(1)
            print("STATUS", dev.cli("status", "--json")[:1500])
        H.settle(2)
        notes = os.path.join(work, "notes.txt")
        print("after turn2:", repr(open(notes).read()))
        msgs = [json.loads(l) for l in dev.cli("log", "--json").splitlines() if l.startswith("{")]
        users = [m["id"] for m in msgs if m.get("role") == "user"]
        t2 = users[1]
        for m in msgs:
            print("MSG", m.get("role"), m["id"], "files", m.get("files"), "parent", m.get("parent"))
        out = dev.cli("undo", t2, timeout=120).strip()
        print(out)
        undo = out.split()[1]
        H.settle(2)
        got = open(notes).read() if os.path.exists(notes) else None
        print("after undo:", repr(got))
        check("undo restores turn 1's file", got == "one\n")
        st = dev.cli("status", "--json") if False else ""
        out = dev.cli("redo", undo, timeout=120).strip()
        print(out)
        H.settle(2)
        got = open(notes).read() if os.path.exists(notes) else None
        print("after redo:", repr(got))
        check("redo restores turn 2's file", got == "one\ntwo\n")
        redo = out.split()[1]
        out = dev.cli("undo", t2, timeout=120).strip()
        print(out)
        H.settle(2)
        got = open(notes).read() if os.path.exists(notes) else None
        print("after second undo:", repr(got))
        check("a second undo of turn 2 restores turn 1's file", got == "one\n")
        before = len(fakes.FakeAnthropic.requests)
        print(dev.cli("send", "turn3", "--wait", timeout=120).strip())
        H.settle(2)
        reqs = fakes.FakeAnthropic.requests[before:]
        first = reqs[0] if reqs else []
        print("turn 3 first request:", first)
        check("turn 3's request keeps turn 1", any("turn1" in x for x in first))
        check("turn 3's request drops turn 2", not any("turn2" in x or "two" in x for x in first))
        got = open(notes).read() if os.path.exists(notes) else None
        print("after turn3:", repr(got))
        check("turn 3 writes on top of turn 1", got == "one\nthree\n")
        fakes.FakeAnthropic.contents[4] = "one\nthree\nfour\n"
        fakes.FakeAnthropic.slow.add(4)
        print(dev.cli("send", "turn4", timeout=60).strip())
        t4 = None
        for _ in range(100):
            time.sleep(0.1)
            if os.path.exists(notes) and "four" in open(notes).read():
                break
        msgs = [json.loads(l) for l in dev.cli("log", "--json").splitlines() if l.startswith("{")]
        t4 = [m["id"] for m in msgs if m.get("role") == "user"][-1]
        check("turn 4 wrote before the undo", "four" in open(notes).read())
        out = dev.cli("undo", t4, timeout=60).strip()
        print(out)
        check("an undo of a running turn waits for the hold", "started" in out)
        for _ in range(150):
            time.sleep(0.1)
            if open(notes).read() == "one\nthree\n":
                break
        got = open(notes).read()
        print("after undoing running turn 4:", repr(got))
        check("undoing a running turn holds it and restores the file", got == "one\nthree\n")
        H.settle(8)
        got = open(notes).read()
        check("the held turn does not write after the undo", got == "one\nthree\n")
        print(dev.cli("send", "turn5", "--wait", timeout=120).strip())
        reqs = fakes.FakeAnthropic.requests
        last = reqs[-1] if reqs else []
        print("turn 5 request:", last)
        check("turn 5's request drops turn 4", not any("turn4" in x for x in last))
    finally:
        dev.stop()
        relay.stop()
        srv.shutdown()

main()
print("native: %d checks failed" % len(FAILS))
sys.exit(1 if FAILS else 0)
