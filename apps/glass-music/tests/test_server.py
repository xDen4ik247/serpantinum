"""Server.call() retry safety and on_event() burst handling against a scripted fake MPD.

Run: python -m unittest discover -s tests -t .   (no real MPD needed)
"""
import os
import shutil
import socket
import tempfile
import threading
import unittest

from glassmusic import server as srv
from glassmusic.server import Server


class FakeMPD:
    """Unix-socket MPD stand-in. `script` holds one behaviour per accepted connection:
    'ok'         answer every command with OK
    'drop'       execute (record) the first command / command list, then hang up without replying
    'idle-close' hang up right after the greeting (MPD's connection_timeout on an idle client)
    Connections beyond the script behave like 'ok'."""

    def __init__(self, script):
        self.script = list(script)
        self.executed = []
        self.dir = tempfile.mkdtemp(prefix="gm-fake-mpd-")
        self.path = os.path.join(self.dir, "socket")
        self.lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.lsock.bind(self.path)
        self.lsock.listen(8)
        self.closed_idle = threading.Event()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                c, _ = self.lsock.accept()
            except OSError:
                return
            mode = self.script.pop(0) if self.script else "ok"
            threading.Thread(target=self.client, args=(c, mode), daemon=True).start()

    def client(self, c, mode):
        f = c.makefile("rwb")
        f.write(b"OK MPD 0.24.0\n")
        f.flush()
        if mode == "idle-close":
            c.close()
            self.closed_idle.set()
            return
        cmdlist = None
        for raw in f:
            line = raw.decode().rstrip("\n")
            if line in ("command_list_ok_begin", "command_list_begin"):
                cmdlist = []
                continue
            if cmdlist is not None and line != "command_list_end":
                cmdlist.append(line)
                continue
            cmds = cmdlist if cmdlist is not None else [line]
            self.executed.extend(cmds)
            if mode == "drop":
                c.shutdown(socket.SHUT_RDWR)
                c.close()
                return
            for cmd in cmds:
                if cmd == "status":
                    f.write(b"state: play\n")
                if cmdlist is not None:
                    f.write(b"list_OK\n")
            f.write(b"OK\n")
            f.flush()
            cmdlist = None

    def stop(self):
        self.lsock.close()
        shutil.rmtree(self.dir, ignore_errors=True)


def make_server(address):
    s = Server.__new__(Server)
    s.address = address
    s.mpd = None
    return s


class CallRetryTest(unittest.TestCase):
    def tearDown(self):
        if self.s.mpd:
            self.s.drop()
        self.fake.stop()

    def test_command_list_not_resent_after_drop(self):
        # MPD executes clear+add, then the connection dies before the reply: never send it twice.
        self.fake = FakeMPD(["drop"])
        s = self.s = make_server(self.fake.path)
        cmds = [("clear",), ("add", "a.m4a"), ("add", "b.m4a")]
        with self.assertRaises(ConnectionError):
            s.call(lambda m: m.batch(cmds))
        self.assertEqual(self.fake.executed, ['clear', 'add "a.m4a"', 'add "b.m4a"'])
        self.assertIsNone(s.mpd)
        s.call(lambda m: m.cmd("ping"))          # next call reconnects cleanly
        self.assertEqual(self.fake.executed[-1], "ping")

    def test_idempotent_read_is_retried(self):
        self.fake = FakeMPD(["drop"])
        s = self.s = make_server(self.fake.path)
        st = s.call(lambda m: m.dict("status"), idempotent=True)
        self.assertEqual(st, {"state": "play"})
        self.assertEqual(self.fake.executed, ["status", "status"])

    def test_timed_out_idle_connection_reconnects_before_sending(self):
        # The common case: MPD closed the idle command connection; a write must still go out once.
        self.fake = FakeMPD(["idle-close"])
        s = self.s = make_server(self.fake.path)
        s.conn()
        self.assertTrue(self.fake.closed_idle.wait(2))
        for _ in range(100):                     # let the FIN arrive
            if s.mpd.stale():
                break
            threading.Event().wait(0.01)
        s.call(lambda m: m.batch([("clear",), ("add", "a.m4a")]))
        self.assertEqual(self.fake.executed, ["clear", 'add "a.m4a"'])

    def test_connect_failure_is_retried(self):
        self.fake = FakeMPD([])
        s = self.s = make_server(self.fake.path + ".missing")
        with self.assertRaises(OSError):
            s.call(lambda m: m.cmd("clear"))     # nothing was ever sent: two connect attempts, then raise


class OnEventTest(unittest.TestCase):
    def setUp(self):
        self.fake = None
        s = Server.__new__(Server)
        self.calls = []
        for name in ("send_library", "send_queue", "send_home", "send_status", "send_likes", "send_playlists"):
            setattr(s, name, (lambda n: lambda *a, **k: self.calls.append(n))(name))
        self.s = s

    def test_reconnect_burst_keeps_other_changes(self):
        self.s.on_event(["reconnect", "sticker", "stored_playlist", "database"])
        self.assertEqual(sorted(self.calls), sorted(["send_library", "send_queue", "send_home",
                                                     "send_status", "send_likes", "send_playlists"]))

    def test_reconnect_alone(self):
        self.s.on_event(["reconnect"])
        self.assertEqual(self.calls, ["send_queue", "send_status"])

    def test_no_duplicate_sends(self):
        self.s.on_event(["reconnect", "playlist", "player"])
        self.assertEqual(self.calls, ["send_queue", "send_status"])


if __name__ == "__main__":
    unittest.main()
