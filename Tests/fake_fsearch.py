#!/usr/bin/env python3
"""Stands in for the fsearch daemon in tests: `fake_fsearch.py serve` listens on
$FAKE_SOCK and answers JSON lines the way fsearch's server.rs does."""
import json, os, socket, sys, threading, time

path = os.environ["FAKE_SOCK"]
if os.path.exists(path):
    os.unlink(path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(8)

def answer(req):
    op = req.get("op", "search")
    if op == "ping":
        return {"ok": True}
    if op == "open":
        with open(path + ".opened", "a") as f:
            f.write(req["path"] + "\n")
        return {"ok": True, "scores": [1.0]}
    if op == "die":
        os._exit(0)
    q = req["q"]
    if q.startswith("slow"):
        time.sleep(0.3)
    if "grep:" in q:
        return {"ok": True, "files": [{"path": "/Users/me/src/main.rs", "matches": [{"line": 12, "text": "    let x = 1;", "col": 4}]}]}
    if q == "boom":
        return {"ok": False, "error": "indexing: 40%", "id": None}
    if q.startswith("type:app"):
        return {"ok": True, "hits": [
            {"kind": "dir", "mtime": 1, "path": "/Users/me/Downloads/Foo.app", "score": 9, "size": 0},
            {"kind": "dir", "mtime": 1, "path": "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app", "score": 8, "size": 0}],
            "id": None, "ok": True, "took_us": 50}
    return {"hits": [{"kind": "file", "mtime": 1, "path": f"/Users/me/{q}.txt", "score": 10, "size": 3}], "id": None, "ok": True, "took_us": 42}

def handle(conn):
    buf = b""
    while True:
        data = conn.recv(4096)
        if not data:
            return
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            conn.sendall((json.dumps(answer(json.loads(line))) + "\n").encode())

while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
