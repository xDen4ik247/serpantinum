"""Background new-mail check (glass-mail-check.timer): syncs each inbox into the cache and
notifies about new unread mail. Does nothing while the app is open (it has IMAP IDLE)."""
import os

from . import accounts as accmod
from . import engine
from . import paths
from .server import Hub


class QuietHub(Hub):
    def emit(self, obj):
        pass


def app_running():
    try:
        with open(os.path.join(paths.STATE, 'app.pid')) as f:
            pid = int(f.read().strip())
        with open(f'/proc/{pid}/cmdline', 'rb') as f:
            return b'glassmail.server' in f.read()
    except (OSError, ValueError):
        return False


def main():
    paths.ensure()
    if app_running():
        return
    hub = QuietHub()
    for conf in accmod.load():
        a = engine.Account(conf, hub)
        conn = engine.Conn(a)
        store = hub.store
        try:
            conn.run(lambda c: a.sync_folder_list(c, store))
            inbox = store.folder_by_role(a.id, 'inbox')
            if inbox:
                conn.run(lambda c: a.sync_folder(c, store, inbox['path']))
        except Exception as e:
            hub.log(f'{conf["email"]}: {e}')
        finally:
            conn.close()
    hub.write_unread()


if __name__ == '__main__':
    main()
