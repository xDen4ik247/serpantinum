"""glass-mail-watch: the always-on new-mail watcher (user service). One IMAP IDLE connection per
account on the inbox; the server pushes new mail, so login codes reach the clipboard within
seconds even when the app is closed. Idle cost: a sleeping socket per account.

- IDLE is re-issued every few minutes (servers drop idle connections at ~30 min), with a cheap
  inbox sync each time to catch anything a dropped connection missed.
- Suspend / resume: a light clock check notices the jump and reconnects at once (sockets from
  before sleep are usually dead). TCP keepalive notices dead networks (Wi-Fi switches).
- The app and this watcher both sync, but each new message is claimed once in the cache
  (folders.notified), so there is only ever one notification / one copy.
"""
import os
import socket
import sys
import threading
import time

from . import accounts as accmod
from . import engine
from . import paths
from .check import QuietHub

IDLE_SECONDS = 270          # re-issue IDLE (and resync) this often


def keepalive(sock):
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 60)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
    except (OSError, AttributeError):
        pass


class Watcher:
    def __init__(self, hub, conf):
        self.hub = hub
        self.conf = conf
        self.acc = engine.Account(conf, hub)       # used for its sync / notify logic, threads not started
        self.stop = threading.Event()
        self.kick = threading.Event()               # "reconnect now" (resume from suspend)
        self.conn = None
        self.thread = threading.Thread(target=self.loop, daemon=True, name=conf['id'])

    def start(self):
        self.thread.start()

    def close(self):
        self.stop.set()
        self.reconnect()

    def reconnect(self):
        c = self.conn
        if c is not None and c.c is not None:
            try:
                c.c.shutdown()                      # breaks a blocking IDLE read
            except Exception:
                pass

    def loop(self):
        backoff = 5
        while not self.stop.is_set():
            conn = self.conn = engine.Conn(self.acc)
            store = self.hub.store
            try:
                conn.open()
                keepalive(conn.c.sock)
                if not store.folder_by_role(self.acc.id, 'inbox'):
                    self.acc.sync_folder_list(conn, store)
                inbox = (store.folder_by_role(self.acc.id, 'inbox') or {}).get('path', 'INBOX')
                self.acc.sync_folder(conn, store, inbox)
                backoff = 5
                if 'IDLE' not in conn.c.capabilities:
                    # no push on this server: poll quietly
                    while not self.stop.is_set() and not self.kick.wait(20):
                        self.acc.sync_folder(conn, store, inbox)
                    self.kick.clear()
                    continue
                while not self.stop.is_set():
                    hit = False
                    with conn.c.idle(duration=IDLE_SECONDS) as idler:
                        for typ, _ in idler:
                            if typ in ('EXISTS', 'RECENT', 'FETCH', 'EXPUNGE'):
                                hit = True
                                break
                    if self.stop.is_set():
                        break
                    self.acc.sync_folder(conn, store, inbox)
                    if hit:
                        self.hub.write_unread()
            except engine.AuthError as e:
                self.hub.log(f'{self.conf["email"]}: {e}')
                self.stop.wait(600)                  # wrong password: don't hammer the server
            except Exception as e:
                if not self.stop.is_set():
                    self.hub.log(f'{self.conf["email"]}: {type(e).__name__}: {e} (retry in {backoff}s)')
                    self.kick.wait(backoff)
                    self.kick.clear()
                    backoff = min(backoff * 2, 300)
            finally:
                conn.close()


def main():
    paths.ensure()
    hub = QuietHub()
    watchers = {}
    seen = None

    def mtime(p):
        try:
            return os.stat(p).st_mtime
        except OSError:
            return 0

    # suspend shows up as BOOTTIME (counts sleep) running ahead of MONOTONIC (doesn't)
    drift = time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()
    settings_m = mtime(paths.SETTINGS)
    while True:
        m = mtime(paths.ACCOUNTS)
        if m != seen:                                # accounts added / removed / edited
            seen = m
            confs = {c['id']: c for c in accmod.load()}
            for aid in list(watchers):
                if aid not in confs or confs[aid] != watchers[aid].conf:
                    watchers.pop(aid).close()
            for aid, conf in confs.items():
                if aid not in watchers:
                    watchers[aid] = Watcher(hub, conf)
                    watchers[aid].start()
        sm = mtime(paths.SETTINGS)
        if sm != settings_m:
            settings_m = sm
            hub.settings.update(accmod.load_settings())
        now = time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()
        if now - drift > 5:                          # we were asleep
            hub.log(f'resumed after {now - drift:.0f}s asleep: reconnecting')
            for w in watchers.values():
                w.kick.set()
                w.reconnect()
        drift = now
        time.sleep(3)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
