import json, os, sys, time, shutil, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakes
H = fakes.H
FAILS = []

def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)

def git(work, *a):
    return subprocess.run(["git", "-C", work] + list(a), capture_output=True, text=True, check=True).stdout.strip()

def main():
    d = os.path.join(os.environ["E2E_OUT"], "gitguard")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    fakes.FakeAnthropic.contents = {1: "one\n", 2: "one\ntwo\n"}
    srv, url = fakes.serve()
    relay = H.Relay(d)
    dev = H.Device(d, "a", relay, env_extra={"ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": "x"})
    try:
        conv = dev.cli("new", "g", "--provider", "native", "--model", "claude-opus-5-5").strip().split()[-1]
        work = os.path.join(d, "work")
        os.makedirs(work)
        subprocess.run(["git", "init", "-q", "-b", "main", work], check=True)
        open(os.path.join(work, "README"), "w").write("r\n")
        git(work, "add", ".")
        git(work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init")
        dev.cli("mount", work, "--convo", conv, "--name", "work")
        H.settle(1)
        for i in (1, 2):
            dev.cli("send", "turn%d" % i, "--wait", timeout=120)
        H.settle(2)
        git(work, "checkout", "-q", "-b", "other")
        H.settle(3)
        msgs = [json.loads(l) for l in dev.cli("log", "--json").splitlines() if l.startswith("{")]
        t2 = [m["id"] for m in msgs if m.get("role") == "user"][1]
        out = dev.cli("undo", t2, timeout=120).strip()
        print(out)
        H.settle(3)
        check("the undo finishes with the folder on another branch", "done" in out)
        check("the undo never moves the checkout", git(work, "rev-parse", "--abbrev-ref", "HEAD") == "other")
        st = json.loads(dev.cli("status", "--json"))
        print("mount lines:", [(m["root"][-20:], m["line"]) for m in st.get("mounts", [])])
    finally:
        dev.stop()
        relay.stop()
        srv.shutdown()

main()
print("gitguard: %d checks failed" % len(FAILS))
sys.exit(1 if FAILS else 0)
