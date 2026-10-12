#!/usr/bin/env python3
"""A fake niri IPC socket for tests.

  fake_niri.py SOCKET LOG [SCRIPT]

Every request line is appended to LOG (one JSON per line). Replies:
  "EventStream"          {"Ok":"Handled"}, then the events from SCRIPT
  "Workspaces"/"Windows"/"FocusedWindow"/"Outputs"  answered from the replayed state
  everything else        {"Ok":"Handled"} (with FAKE_NIRI_EXEC=1, Spawn actions really run)
SCRIPT is a JSON-lines file of events; a line {"sleep": 0.3} pauses the replay, {"wait_requests": N}
waits until N action requests were logged. When the script ends the stream stays open until
{"close": true} or the server is killed.
"""
import json, os, socket, sys, threading, time

sock_path, log_path = sys.argv[1], sys.argv[2]
script = sys.argv[3] if len(sys.argv) > 3 else None
lock = threading.Lock()
state = {"workspaces": {}, "windows": {}, "outputs": {}}
n_actions = [0]

def apply(ev):
    ws, win = state["workspaces"], state["windows"]
    if "WorkspacesChanged" in ev:
        ws.clear(); ws.update({w["id"]: w for w in ev["WorkspacesChanged"]["workspaces"]})
    elif "WorkspaceActivated" in ev:
        e = ev["WorkspaceActivated"]; out = ws.get(e["id"], {}).get("output")
        for w in ws.values():
            if w.get("output") == out: w["is_active"] = w["id"] == e["id"]
            if e["focused"]: w["is_focused"] = w["id"] == e["id"]
    elif "WindowsChanged" in ev:
        win.clear(); win.update({w["id"]: w for w in ev["WindowsChanged"]["windows"]})
    elif "WindowOpenedOrChanged" in ev:
        w = ev["WindowOpenedOrChanged"]["window"]
        if w.get("is_focused"):
            for o in win.values(): o["is_focused"] = False
        win[w["id"]] = w
    elif "WindowClosed" in ev:
        win.pop(ev["WindowClosed"]["id"], None)
    elif "WindowFocusChanged" in ev:
        for o in win.values(): o["is_focused"] = o["id"] == ev["WindowFocusChanged"]["id"]


if script:
    for ln in open(script):
        ln = ln.strip()
        if ln.startswith('{"outputs"'):
            state["outputs"] = json.loads(ln)["outputs"]
    # like a real compositor, the state before the first pause already exists when clients connect
    for ln in open(script):
        ln = ln.strip()
        if not ln or ln.startswith('{"outputs"'):
            continue
        ev = json.loads(ln)
        if "sleep" in ev or "wait_requests" in ev or "close" in ev:
            break
        apply(ev)


def log(req):
    with lock:
        with open(log_path, "a") as f:
            f.write(json.dumps(req) + "\n")
        if isinstance(req, dict) and ("Action" in req or "Output" in req):
            n_actions[0] += 1


def stream(conn):
    conn.sendall(b'{"Ok":"Handled"}\n')
    if not script:
        return
    for ln in open(script):
        ln = ln.strip()
        if not ln or ln.startswith('{"outputs"'):
            continue
        ev = json.loads(ln)
        if "sleep" in ev:
            time.sleep(ev["sleep"]); continue
        if "wait_requests" in ev:
            t0 = time.time()
            while n_actions[0] < ev["wait_requests"] and time.time() - t0 < 5:
                time.sleep(0.01)
            continue
        if "close" in ev:
            conn.close(); return
        with lock:
            apply(ev)
        conn.sendall((json.dumps(ev) + "\n").encode())
    while True:
        time.sleep(3600)


def handle(conn):
    f = conn.makefile("rb")
    line = f.readline()
    if not line:
        return
    req = json.loads(line)
    log(req)
    if req == "EventStream":
        return stream(conn)
    with lock:
        if req == "Workspaces":
            rep = {"Ok": {"Workspaces": list(state["workspaces"].values())}}
        elif req == "Windows":
            rep = {"Ok": {"Windows": list(state["windows"].values())}}
        elif req == "FocusedWindow":
            fw = next((w for w in state["windows"].values() if w.get("is_focused")), None)
            rep = {"Ok": {"FocusedWindow": fw}}
        elif req == "Outputs":
            rep = {"Ok": {"Outputs": state["outputs"]}}
        elif req == "Version":
            rep = {"Ok": {"Version": "26.04 (8ed0da4)"}}
        else:
            if os.environ.get("FAKE_NIRI_EXEC") and isinstance(req, dict) and "Spawn" in req.get("Action", {}):
                import subprocess
                subprocess.Popen(req["Action"]["Spawn"]["command"], start_new_session=True,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            rep = {"Ok": {"OutputConfigChanged": "Applied"}} if isinstance(req, dict) and "Output" in req else {"Ok": "Handled"}
    conn.sendall((json.dumps(rep) + "\n").encode())
    conn.close()


try:
    os.unlink(sock_path)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX)
srv.bind(sock_path)
srv.listen(64)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
