import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, os.path.join(os.environ["REPO"], "tools", "costbench"))
import harness as H

def flat(msgs):
    out = []
    for m in msgs:
        c = m.get("content")
        if isinstance(c, str):
            out.append("%s:%s" % (m["role"], c))
            continue
        for b in c or []:
            t = b.get("type")
            if t == "text":
                out.append("%s:%s" % (m["role"], b.get("text", "")))
            elif t == "tool_use":
                out.append("%s:tool_use:%s" % (m["role"], json.dumps(b.get("input"), sort_keys=True)))
            elif t == "tool_result":
                cc = b.get("content")
                out.append("%s:tool_result:%s" % (m["role"], cc if isinstance(cc, str) else json.dumps(cc)))
    return out

class FakeAnthropic(BaseHTTPRequestHandler):
    requests = []
    contents = {}
    slow = set()
    count = 0

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        msgs = body.get("messages", [])
        FakeAnthropic.requests.append(flat(msgs))
        FakeAnthropic.count += 1
        last = msgs[-1] if msgs else {"content": ""}
        c = last.get("content")
        blocks = c if isinstance(c, list) else [{"type": "text", "text": c or ""}]
        tool_result = any(b.get("type") == "tool_result" for b in blocks)
        text = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        def ev(name, obj):
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(obj))).encode())
        ev("message_start", {"type": "message_start", "message": {"id": "msg_%d" % self.count, "type": "message", "role": "assistant", "model": "claude-opus-5-5", "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
        turn = None
        for w in text.split():
            if w.startswith("turn") and w[4:].isdigit():
                turn = int(w[4:])
        if tool_result or turn is None or turn not in FakeAnthropic.contents:
            if tool_result:
                time.sleep(float(os.environ.get("FAKE_SETTLE_S", "0")))
                if any("turn%d" % k in json.dumps(msgs) for k in FakeAnthropic.slow):
                    time.sleep(6)
            ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "done"}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 1}})
        else:
            inp = json.dumps({"path": "notes.txt", "content": FakeAnthropic.contents[turn]})
            ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_%d" % self.count, "name": "write_file", "input": {}}})
            ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": inp}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 1}})
        ev("message_stop", {"type": "message_stop"})
        self.wfile.flush()

def serve():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeAnthropic)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]
