#!/usr/bin/env python3
import argparse
import base64
import gzip
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

REPO_URL = "https://github.com/zeronsh/0ndb"
POSIX_REPO = "~/dev/0ndb-odin"
POSIX_SCRATCH = "~/dev/0ndb-scratch"
WIN_REPO = "C:\\Users\\wing_\\dev\\0ndb-odin"
WIN_SCRATCH = "C:\\Users\\wing_\\dev\\0ndb-scratch"


class Mcp:
    def __init__(self, exe):
        self.p = subprocess.Popen([exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.lock = threading.Lock()
        self.n = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "xplat", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def request(self, method, params):
        with self.lock:
            self.n += 1
            i = self.n
            self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n")
            self.p.stdin.flush()
            while True:
                line = self.p.stdout.readline()
                if not line:
                    raise RuntimeError("zeron mcp closed")
                m = json.loads(line)
                if m.get("id") == i:
                    if "error" in m:
                        raise RuntimeError(str(m["error"]))
                    return m["result"]

    def tool(self, name, args):
        r = self.request("tools/call", {"name": name, "arguments": args})
        if r.get("isError"):
            raise RuntimeError(json.dumps(r.get("content")))
        if "structuredContent" in r:
            return r["structuredContent"]
        return json.loads(r["content"][0]["text"])

    def close(self):
        self.p.terminate()


def resolve(ref):
    if re.fullmatch(r"[0-9a-f]{40}", ref):
        return ref
    try:
        return subprocess.check_output(["git", "rev-parse", "--verify", ref + "^{commit}"], stderr=subprocess.DEVNULL, text=True).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    out = subprocess.check_output(["git", "ls-remote", REPO_URL, ref, "refs/heads/" + ref], text=True).split()
    if not out:
        sys.exit("xplat: cannot resolve " + ref)
    return out[0]


def parse(text):
    rows, meta = {}, {}
    for line in text.splitlines():
        f = line.strip().split()
        if not f:
            continue
        if f[0] == "XPLAT" and len(f) == 6:
            rows[(f[1], int(f[2]))] = (f[3], f[4], f[5])
        elif f[0] in ("XPLAT-BUILD", "XPLAT-WALL") and len(f) == 2:
            meta[f[0]] = f[1]
        elif f[0] in ("XPLAT-ERROR", "XPLAT-BUSY"):
            meta["error"] = line.strip()
    return rows, meta


def packed(name):
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), name), "rb") as f:
        return base64.b64encode(gzip.compress(f.read())).decode()


def run_local(sha, args):
    top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    subprocess.run(["git", "-C", top, "fetch", "-q", "origin", sha], check=False)
    wt = os.path.join(tempfile.gettempdir(), "xplat-" + sha[:8])
    if not os.path.isdir(wt):
        subprocess.run(["git", "-C", top, "worktree", "add", "-q", "--detach", wt, sha], check=True)
    try:
        env = dict(os.environ, XPLAT_ROOT=wt)
        runner = os.path.join(os.path.dirname(os.path.abspath(__file__)), "xplat-run.sh")
        p = subprocess.run(["sh", runner, args.seeds, args.lanes, str(args.jobs)], capture_output=True, text=True, timeout=3600, env=env)
        return p.stdout + p.stderr
    finally:
        subprocess.run(["git", "-C", top, "worktree", "remove", "--force", wt], check=False)


def run_remote(mcp, device, windows, sha, args, keep, repo=POSIX_REPO, scratch=POSIX_SCRATCH):
    wt_name = "xplat-" + sha[:8]
    if windows:
        wt = WIN_SCRATCH + "\\" + wt_name
        runner = WIN_SCRATCH + "\\xplat-run.ps1"
        put = "$ms = New-Object IO.MemoryStream(,[Convert]::FromBase64String('%s')); $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress); $o = New-Object IO.MemoryStream; $gz.CopyTo($o); [IO.File]::WriteAllBytes('%s', $o.ToArray())" % (packed("xplat-run.ps1"), runner)
        prep = "git -C %s fetch -q origin %s; if (-not (Test-Path %s)) { git -C %s worktree add -q --detach %s %s }; git -C %s checkout -q --detach %s; %s; git -C %s log --oneline -1" % (WIN_REPO, sha, wt, WIN_REPO, wt, sha, wt, sha, put, wt)
        cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File %s -Root %s -Seeds %s -Lanes %s -Jobs %d" % (runner, wt, args.seeds, args.lanes, args.jobs)
        clean = None if keep else "git -C %s worktree remove --force %s; git -C %s worktree prune; Remove-Item -Force %s" % (WIN_REPO, wt, WIN_REPO, runner)
    else:
        wt = scratch + "/" + wt_name
        runner = scratch + "/xplat-run.sh"
        put = "echo %s | (base64 -d 2>/dev/null || base64 -D) | gunzip > %s" % (packed("xplat-run.sh"), runner)
        prep = "set -e; mkdir -p %s; git -C %s fetch -q origin %s; [ -d %s ] || git -C %s worktree add -q --detach %s %s; git -C %s checkout -q --detach %s; %s; git -C %s log --oneline -1" % (scratch, repo, sha, wt, repo, wt, sha, wt, sha, put, wt)
        cmd = "XPLAT_ROOT=%s sh %s %s %s %d" % (wt, runner, args.seeds, args.lanes, args.jobs)
        clean = None if keep else "git -C %s worktree remove --force %s; git -C %s worktree prune; rm -f %s" % (repo, wt, repo, runner)
    r = mcp.tool("run_command", {"device": device, "command": prep, "timeout_secs": 300})
    if r.get("exitCode") != 0:
        return "XPLAT-ERROR prepare: " + r.get("output", "")[-400:]
    bg = mcp.tool("run_command", {"device": device, "command": cmd, "background": True})
    out = []
    deadline = time.time() + 3600
    while time.time() < deadline:
        time.sleep(10)
        o = mcp.tool("command_output", {"id": bg["id"]})
        out.append(o.get("output", ""))
        if o.get("status") != "running":
            break
    else:
        mcp.tool("stop_command", {"id": bg["id"]})
        out.append("\nXPLAT-ERROR timed out after 3600 s")
    if clean:
        mcp.tool("run_command", {"device": device, "command": clean, "timeout_secs": 120})
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description="Run sim seeds on Linux, macOS and Windows and require identical events and disk_ops.")
    ap.add_argument("--commit", default="odin-rewrite")
    ap.add_argument("--seeds", default="1-20")
    ap.add_argument("--lanes", default="default,until-run")
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--linux", default="local" if platform.system() == "Linux" else "")
    ap.add_argument("--linux-repo", default=POSIX_REPO)
    ap.add_argument("--linux-scratch", default=POSIX_SCRATCH)
    ap.add_argument("--mac", default="home-laptop")
    ap.add_argument("--win", default="WING-PC")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--zeron", default=os.environ.get("ZERON", "zeron"))
    args = ap.parse_args()
    if not args.linux:
        sys.exit("xplat: a Linux baseline is needed: run on Linux or pass --linux <device>")
    sha = resolve(args.commit)
    exe = shutil.which(args.zeron) or args.zeron
    mcp = Mcp(exe)
    targets = [("linux", args.linux, False), ("macos", args.mac, False), ("windows", args.win, True)]
    results = {}

    def one(name, device, windows):
        try:
            if device == "local":
                results[name] = run_local(sha, args)
            elif name == "linux":
                results[name] = run_remote(mcp, device, False, sha, args, args.keep, args.linux_repo, args.linux_scratch)
            else:
                results[name] = run_remote(mcp, device, windows, sha, args, args.keep)
        except Exception as e:
            results[name] = "XPLAT-ERROR " + str(e)

    threads = [threading.Thread(target=one, args=t) for t in targets if t[1]]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    mcp.close()
    parsed = {n: parse(results.get(n, "")) for n, _, _ in targets}
    base, bmeta = parsed["linux"]
    status = 0
    print("xplat %s seeds %s lanes %s" % (sha[:10], args.seeds, args.lanes))
    if "error" in bmeta or not base:
        print("linux: %s" % bmeta.get("error", "no results"))
        sys.exit(2)
    print("linux (%s): %d runs, build %s s, seeds %s s" % (args.linux, len(base), bmeta.get("XPLAT-BUILD", "?"), bmeta.get("XPLAT-WALL", "?")))
    for name, device, _ in targets[1:]:
        if not device:
            continue
        rows, meta = parsed[name]
        if "error" in meta or not rows:
            print("%s (%s): %s" % (name, device, meta.get("error", "no results")))
            status = max(status, 2)
            continue
        diff = []
        for k in sorted(base):
            if k not in rows:
                diff.append("%s %d missing" % k)
            elif rows[k][:2] != base[k][:2]:
                diff.append("%s %d linux events=%s disk_ops=%s, %s events=%s disk_ops=%s" % (k[0], k[1], base[k][0], base[k][1], name, rows[k][0], rows[k][1]))
        same = len(base) - len(diff)
        print("%s (%s): %d/%d identical to linux, build %s s, seeds %s s" % (name, device, same, len(base), meta.get("XPLAT-BUILD", "?"), meta.get("XPLAT-WALL", "?")))
        for d in diff:
            print("  differs: " + d)
        if diff:
            status = max(status, 1)
    ran = [n for n, d, _ in targets if d and parsed[n][0]]
    everywhere, some = [], []
    for k in sorted(base):
        codes = {n: parsed[n][0].get(k, (None, None, None))[2] for n in ran}
        bad = [n for n, c in codes.items() if c != "0"]
        if not bad:
            continue
        if len(bad) == len(ran):
            everywhere.append("%s %d" % k)
        else:
            some.append("%s %d (fails on %s)" % (k[0], k[1], ", ".join(bad)))
    if everywhere:
        print("seeds failing on every platform (not a platform difference): " + ", ".join(everywhere))
    if some:
        print("seeds failing on some platforms only: " + "; ".join(some))
        status = max(status, 1)
    print("result: " + ("PASS" if status == 0 else "FAIL"))
    sys.exit(status)


if __name__ == "__main__":
    main()
