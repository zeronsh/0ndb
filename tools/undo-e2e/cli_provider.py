import json, os, sys, time, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakes
H = fakes.H
FAILS = []

def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)

def launches(state):
    p = os.path.join(state, "launches.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []

def main(provider):
    d = os.path.join(os.environ["E2E_OUT"], provider)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    state = os.path.join(d, "fake")
    os.makedirs(state)
    contents = {"1": "one\n", "2": "one\ntwo\n", "3": "one\nthree\n"}
    here = os.path.dirname(os.path.abspath(__file__))
    env = {"PATH": os.path.join(here, "bin") + ":" + os.environ["PATH"], "FAKE_STATE": state, "FAKE_CONTENTS": json.dumps(contents), "PYTHONDONTWRITEBYTECODE": "1"}
    relay = H.Relay(d)
    dev = H.Device(d, "a", relay, env_extra=env)
    try:
        out = dev.cli("new", "u", "--provider", provider).strip()
        print(out)
        conv = out.split()[-1]
        work = os.path.join(d, "work")
        os.makedirs(work)
        print(dev.cli("mount", work, "--convo", conv, "--name", "work").strip())
        H.settle(1)
        for i in (1, 2):
            print(dev.cli("send", "turn%d" % i, "--wait", timeout=120).strip())
        H.settle(2)
        notes = os.path.join(work, "notes.txt")
        read = lambda: open(notes).read() if os.path.exists(notes) else None
        check("turn 2 wrote", read() == "one\ntwo\n")
        print("BLAME", dev.cli("blame", notes, check=False))
        msgs = [json.loads(l) for l in dev.cli("log", "--json").splitlines() if l.startswith("{")]
        t2 = [m["id"] for m in msgs if m.get("role") == "user"][1]
        out = dev.cli("undo", t2, timeout=120).strip()
        print(out)
        undo = out.split()[1]
        H.settle(2)
        print("after undo:", repr(read()))
        for m in msgs:
            print("MSG", m.get("role"), m["id"], "files", m.get("files"))
        check("undo restores turn 1's file", read() == "one\n")
        print(dev.cli("redo", undo, timeout=120).strip())
        H.settle(2)
        check("redo restores turn 2's file", read() == "one\ntwo\n")
        n = len(launches(state))
        print(dev.cli("send", "turn9", "--wait", timeout=120).strip())
        L = launches(state)[n:]
        print("after redo launches:", [(x["argv"][-6:], x["history"]) for x in L])
        hist = L[-1]["history"] if L else (launches(state)[-1]["history"] if launches(state) else [])
        check("after a redo the session still holds turn 2", any("turn2" in h for h in hist) or not L)
        msgs = [json.loads(l) for l in dev.cli("log", "--json").splitlines() if l.startswith("{")]
        users = [m for m in msgs if m.get("role") == "user"]
        t9 = users[-1]["id"]
        print(dev.cli("undo", t9, timeout=120).strip())
        H.settle(1)
        print(dev.cli("undo", t2, timeout=120).strip())
        H.settle(2)
        check("undo of turn 2 again restores turn 1's file", read() == "one\n")
        n = len(launches(state))
        print(dev.cli("send", "turn3", "--wait", timeout=120).strip())
        H.settle(2)
        L = launches(state)[n:]
        print("turn 3 launches:", [(x["argv"], x["history"]) for x in L])
        check("turn 3 starts a new process", len(L) >= 1)
        if L:
            hist = L[-1]["history"]
            check("turn 3's session keeps turn 1", any("turn1" in h for h in hist) or os.environ.get("FAKE_NO_FORK"))
            check("turn 3's session drops turn 2", not any("turn2" in h or "turn9" in h for h in hist))
        check("turn 3 writes on top of turn 1", read() == "one\nthree\n")
        if os.environ.get("FAKE_NO_FORK"):
            tp = os.path.join(state, "turns.jsonl")
            turns = [json.loads(l) for l in open(tp)] if os.path.exists(tp) else []
            last = turns[-1]["text"] if turns else ""
            print("seeded turn 3 input:", repr(last[:600]))
            check("without fork, turn 3 starts a fresh session", L and (L[-1]["argv"][0] == "thread/start" or "--resume" not in L[-1]["argv"]))
            check("the fresh thread is seeded with turn 1", "turn1" in last)
            check("the seed leaves turn 2 out", "turn2" not in last and "turn9" not in last)
    finally:
        dev.stop()
        relay.stop()

main(sys.argv[1])
print("%s: %d checks failed" % (sys.argv[1], len(FAILS)))
sys.exit(1 if FAILS else 0)
