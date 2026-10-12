#!/usr/bin/env python3
"""Drive the original focus_daemon.py for differential tests (never touches real data: run it with
HOME, QS_RUN_FOCUSTIME and QS_STATE_FOCUSTIME pointing at a sandbox).

  wellbeing_ref.py DAEMON_PY dump DATE      -> state JSON of full_sync(DATE)
  wellbeing_ref.py DAEMON_PY replay FILE    -> drive fast_tick with recorded times, flush, print state
  wellbeing_ref.py DAEMON_PY resolve        -> stdin: window JSON lines; stdout: ["class","name"]
"""
import datetime as _dt, importlib.util, json, sys, types

src, mode = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("focus_daemon", src)
fd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fd)   # module level: lock, DB init, tracker = DaemonTracker()

if mode == "dump":
    fd.tracker.full_sync(_dt.date.fromisoformat(sys.argv[3]))
    print(json.dumps(fd.tracker.cached_json))
elif mode == "replay":
    clock = [0.0]
    class FakeDT(_dt.datetime):
        @classmethod
        def now(cls, tz=None):
            return _dt.datetime.fromtimestamp(clock[0])
    fd.datetime = FakeDT
    fd.time = types.SimpleNamespace(time=lambda: clock[0], monotonic=lambda: clock[0], sleep=lambda s: None)
    for line in open(sys.argv[3]):
        line = line.rstrip("\n")
        if not line:
            continue
        t, cls, title, secs, write = line.split("\t")
        clock[0] = float(t)
        fd.current_app_title = title
        fd.tracker.fast_tick(cls, title, secs=int(secs), write_to_disk=write == "1")
    fd.tracker.flush()
    print(json.dumps(fd.tracker.cached_json))
elif mode == "resolve":
    import subprocess
    for line in sys.stdin:
        w = json.loads(line)
        # get_active_window_niri() with `niri msg -j focused-window` answering w
        out = json.dumps(w)
        fd.subprocess = types.SimpleNamespace(check_output=lambda *a, **k: out)
        print(json.dumps(list(fd.get_active_window_niri()), ensure_ascii=False))
