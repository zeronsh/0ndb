import base64, json, os, shutil, sys


def big(n):
    out = bytearray()
    i = 0
    while len(out) < n:
        out += b"%07d\n" % i
        i += 1
    return bytes(out[:n])


def binary(n):
    return bytes(i % 256 for i in range(n))


def run(op):
    k = op["op"]
    p = op.get("path")
    if k == "write":
        d = os.path.dirname(p)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(p, "wb") as f:
            f.write(base64.b64decode(op.get("data", "")))
    elif k == "write_bin":
        with open(p, "wb") as f:
            f.write(binary(op["n"]))
    elif k == "write_big":
        with open(p, "wb") as f:
            f.write(big(op["n"]))
    elif k == "mkdir":
        os.mkdir(p)
    elif k == "rm":
        os.remove(p)
    elif k == "rmdir":
        os.rmdir(p)
    elif k == "rmtree":
        shutil.rmtree(p)
    elif k == "mv":
        os.rename(p, op["to"])
    elif k == "chmod_x":
        os.chmod(p, os.stat(p).st_mode | 0o111)
    elif k == "chmod_nx":
        os.chmod(p, os.stat(p).st_mode & ~0o111)
    elif k == "ln_s":
        os.symlink(op["target"], p)
    else:
        raise SystemExit("unknown op " + k)


if __name__ == "__main__":
    ops = json.loads(base64.b64decode(sys.argv[1]))
    os.chdir(sys.argv[2])
    for op in ops:
        run(op)
    print("ok %d" % len(ops))
