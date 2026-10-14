"""One mail account: IMAP sync into the cache, actions, sending.

Each account runs three threads, each with its own IMAP connection and Store:
  fg   — what you are waiting for: opening a message, actions, search, older pages
  bg   — folder list, counts, syncing folders, snippets, prefetching bodies
  idle — IMAP IDLE on the inbox; wakes bg the moment mail arrives (polls if no IDLE)
"""
import imaplib
import os
import queue
import re
import smtplib
import ssl
import threading
import time
import traceback

from . import accounts as accmod
from . import codes
from . import imapparse as ip
from . import mime
from .store import Store, body_path

INITIAL = 150          # newest messages cached when a folder is first opened
PAGE = 100             # "load older" page
BATCH = 80             # UIDs per FETCH
PREFETCH = 25          # newest inbox bodies kept ready
HEADER_FIELDS = 'FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-UNSUBSCRIBE'

ROLE_NAMES = {
    'inbox': 'Inbox', 'flagged': 'Starred', 'sent': 'Sent', 'drafts': 'Drafts', 'archive': 'Archive',
    'all': 'All mail', 'junk': 'Spam', 'trash': 'Trash', 'important': 'Important',
}
NAME_ROLES = [
    ('sent', r'^(sent|sent items|sent messages|sent mail|отправленные)$'),
    ('drafts', r'^(drafts?|черновики)$'),
    ('trash', r'^(trash|deleted|deleted items|deleted messages|bin|корзина|удаленные|удалённые)$'),
    ('junk', r'^(spam|junk|junk e-?mail|bulk mail|спам)$'),
    ('archive', r'^(archives?|архив)$'),
]


class AuthError(Exception):
    pass


def ssl_ctx():
    ctx = ssl.create_default_context()
    if os.environ.get('GLASS_MAIL_INSECURE') == '1':      # tests against a self-signed server
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def imap_connect(conf, timeout=30):
    im = conf['imap']
    host, port = im['host'], int(im.get('port') or 993)
    try:
        if port == 143 or im.get('security') == 'starttls':
            c = imaplib.IMAP4(host, port, timeout=timeout)
            c.starttls(ssl_context=ssl_ctx())
        else:
            c = imaplib.IMAP4_SSL(host, port, ssl_context=ssl_ctx(), timeout=timeout)
    except (OSError, imaplib.IMAP4.error) as e:
        raise ConnectionError(f"Can't reach {host}:{port} ({e})") from e
    try:
        c.login(conf.get('user') or conf['email'], conf.get('password', ''))
    except imaplib.IMAP4.error as e:
        try:
            c.logout()
        except Exception:
            pass
        raise AuthError(login_hint(conf, str(e))) from e
    if 'ENABLE' in c.capabilities and 'CONDSTORE' in c.capabilities:
        try:
            c.enable('CONDSTORE')
        except Exception:
            pass
    return c


def login_hint(conf, err):
    err = re.sub(r"^b?['\"]|['\"]$", '', err.strip())
    p = conf.get('provider')
    if p == 'gmail':
        return 'Gmail refused the password. Use an app password (Google Account → Security → 2-Step Verification → App passwords), not your normal password.'
    if p == 'yandex':
        return 'Yandex refused the password. Create an app password for Mail (id.yandex.ru → Security → App passwords) and allow IMAP in Yandex Mail settings → Mail clients.'
    if p == 'mailru':
        return 'Mail.ru refused the password. Use a password for external apps (Mail.ru account → Security → Passwords for external applications).'
    return 'The server refused the login: ' + (err or 'wrong user name or password') + '.'


def smtp_connect(conf, timeout=30):
    s = conf['smtp']
    host, port, sec = s['host'], int(s.get('port') or 465), s.get('security') or ('ssl' if int(s.get('port') or 465) == 465 else 'starttls')
    try:
        if sec == 'ssl':
            c = smtplib.SMTP_SSL(host, port, timeout=timeout, context=ssl_ctx())
        else:
            c = smtplib.SMTP(host, port, timeout=timeout)
            c.ehlo()
            if sec == 'starttls':
                c.starttls(context=ssl_ctx())
                c.ehlo()
    except (OSError, smtplib.SMTPException) as e:
        raise ConnectionError(f"Can't reach the outgoing server {host}:{port} ({e})") from e
    if conf.get('password') and c.has_extn('auth'):
        try:
            c.login(s.get('user') or conf.get('user') or conf['email'], conf['password'])
        except smtplib.SMTPAuthenticationError as e:
            c.close()
            raise AuthError(login_hint(conf, e.smtp_error.decode('utf-8', 'replace') if isinstance(e.smtp_error, bytes) else str(e))) from e
    return c


def test_account(conf):
    """Sign-in check for the account page: IMAP login + folder list, SMTP login."""
    c = imap_connect(conf)
    try:
        typ, data = c.list()
        n = len(ip.parse_list(data)) if typ == 'OK' else 0
    finally:
        try:
            c.logout()
        except Exception:
            pass
    s = smtp_connect(conf)
    try:
        s.quit()
    except Exception:
        pass
    return n


def uidset(uids):
    """[1,2,3,7,9,10] -> '1:3,7,9:10'"""
    uids = sorted(set(int(u) for u in uids))
    out = []
    i = 0
    while i < len(uids):
        j = i
        while j + 1 < len(uids) and uids[j + 1] == uids[j] + 1:
            j += 1
        out.append(str(uids[i]) if i == j else f'{uids[i]}:{uids[j]}')
        i = j + 1
    return ','.join(out)


def chunks(seq, n):
    seq = list(seq)
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


class Conn:
    """An IMAP connection that reconnects, remembers the selected folder and retries once."""

    def __init__(self, acct):
        self.acct = acct
        self.c = None
        self.selected = None
        self.sel_info = {}

    @property
    def caps(self):
        return self.c.capabilities if self.c else ()

    def open(self):
        if self.c is None:
            self.c = imap_connect(self.acct.conf)
            self.selected = None
        return self.c

    def close(self):
        if self.c is not None:
            try:
                self.c.logout()
            except Exception:
                pass
        self.c = None
        self.selected = None

    def run(self, fn):
        """fn(conn) with one reconnect on a dropped connection."""
        for attempt in (0, 1):
            try:
                self.open()
                return fn(self)
            except (imaplib.IMAP4.abort, OSError, EOFError, ssl.SSLError) as e:
                self.close()
                if attempt:
                    raise ConnectionError(str(e)) from e

    def select(self, path, force=False):
        if self.selected == path and not force:
            return self.sel_info
        typ, data = self.c.select(ip.quote(path))
        if typ != 'OK':
            self.selected = None
            raise imaplib.IMAP4.error(f'select {path}: {data}')
        info = {'exists': ip.num(data[0] if data else 0)}
        for k in ('UIDVALIDITY', 'UIDNEXT', 'HIGHESTMODSEQ'):
            _, v = self.c.response(k)
            info[k.lower()] = ip.num(v[0]) if v and v[0] else 0
        self.selected = path
        self.sel_info = info
        return info

    def uid(self, *args):
        typ, data = self.c.uid(*args)
        if typ != 'OK':
            raise imaplib.IMAP4.error(f'UID {args[0]} failed: {data}')
        return data

    def search(self, *criteria):
        data = self.uid('SEARCH', *criteria)
        out = []
        for line in data:
            if line:
                out.extend(int(x) for x in line.split() if x.isdigit())
        return out


class Account:
    def __init__(self, conf, hub):
        self.conf = conf
        self.id = conf['id']
        self.hub = hub                         # server.Hub: emit(), colors, settings
        self.gmail = accmod.is_gmail(conf)
        self.fgq = queue.Queue()
        self.bgq = queue.Queue()
        self.stopped = threading.Event()
        self.wake = threading.Event()
        self.watch = set()                     # folders the UI shows: kept fresh by bg
        self.auth_failed = False
        self.status = {'state': 'connecting', 'text': ''}
        self.idle_conn = None
        self.threads = [threading.Thread(target=self.loop, args=(q, name), daemon=True, name=f'{self.id}-{name}')
                        for q, name in ((self.fgq, 'fg'), (self.bgq, 'bg'))]
        self.threads.append(threading.Thread(target=self.idle_loop, daemon=True, name=f'{self.id}-idle'))

    # ---------------------------------------------------------------- plumbing
    def start(self):
        for t in self.threads:
            t.start()
        self.bg('refresh', full=True)

    def stop(self):
        self.stopped.set()
        self.wake.set()
        self.fgq.put(None)
        self.bgq.put(None)
        c = self.idle_conn
        if c is not None:
            try:
                c.shutdown()
            except Exception:
                pass

    def fg(self, op, /, **kw):
        self.fgq.put((op, kw))

    def bg(self, op, /, **kw):
        self.bgq.put((op, kw))

    def emit(self, typ, **kw):
        self.hub.emit(dict(type=typ, acc=self.id, **kw))

    def set_status(self, state, text=''):
        if self.status != {'state': state, 'text': text}:
            self.status = {'state': state, 'text': text}
            self.emit('acc-status', state=state, text=text)

    def loop(self, q, name):
        conn = Conn(self)
        store = Store()
        while not self.stopped.is_set():
            item = q.get()
            if item is None:
                break
            op, kw = item
            if self.auth_failed and op not in ('quit',):
                self.emit('op-failed', op=op, rid=kw.get('rid'), text=self.status['text'])
                continue
            try:
                getattr(self, 'do_' + op)(conn, store, **kw)
                if name == 'bg' and self.status['state'] in ('offline', 'connecting'):
                    self.set_status('online')
            except AuthError as e:
                self.auth_failed = True
                self.set_status('auth', str(e))
                self.emit('op-failed', op=op, rid=kw.get('rid'), text=str(e))
            except ConnectionError as e:
                self.set_status('offline', str(e))
                self.emit('op-failed', op=op, rid=kw.get('rid'), text='Offline: ' + str(e))
                if name == 'bg':
                    self.stopped.wait(20)
            except Exception as e:
                self.hub.log(f'{self.id} {op}: {e}\n{traceback.format_exc()}')
                self.emit('op-failed', op=op, rid=kw.get('rid'), text=str(e))
                conn.close()
        conn.close()
        store.close()

    # ---------------------------------------------------------------- folders
    def do_refresh(self, conn, store, full=False):
        """Folder list + counts, then the inbox and the folders on screen."""
        conn.run(lambda c: self.sync_folder_list(c, store))
        self.set_status('online')
        inbox = store.folder_by_role(self.id, 'inbox')
        todo = [inbox['path']] if inbox else []
        todo += [p for p in self.watch if p not in todo]
        for p in todo:
            if store.folder(self.id, p):
                conn.run(lambda c, p=p: self.sync_folder(c, store, p))
        self.emit_folders(store)
        if inbox:
            conn.run(lambda c: self.prefetch(c, store, inbox['path']))
        if full:
            conn.run(lambda c: self.all_snippets(c, store))
        self.hub.write_unread()

    def do_sync(self, conn, store, path):
        if not store.folder(self.id, path):
            conn.run(lambda c: self.sync_folder_list(c, store))
        if store.folder(self.id, path):
            conn.run(lambda c: self.sync_folder(c, store, path))
            self.emit_folders(store)
            self.hub.write_unread()

    def sync_folder_list(self, conn, store):
        c = conn.c
        typ, data = c.list()
        if typ != 'OK':
            raise imaplib.IMAP4.error(f'LIST failed: {data}')
        items = []
        for flags, delim, name, raw in ip.parse_list(data):
            if '\\noselect' in flags or '\\nonexistent' in flags:
                continue
            role = ''
            if raw.upper() == 'INBOX':
                role = 'inbox'
            else:
                for f, r in (('\\sent', 'sent'), ('\\drafts', 'drafts'), ('\\trash', 'trash'), ('\\junk', 'junk'),
                             ('\\archive', 'archive'), ('\\all', 'all'), ('\\flagged', 'flagged'), ('\\important', 'important')):
                    if f in flags:
                        role = r
                        break
            leaf = name.split(delim)[-1] if delim else name
            if not role:
                for r, rx in NAME_ROLES:
                    if re.match(rx, leaf.strip(), re.I):
                        role = r
                        break
            items.append({'path': raw, 'name': leaf, 'role': role, 'delim': delim or '', 'flags': ' '.join(sorted(flags))})
        # one folder per role (the first wins; the others become ordinary folders)
        seen = set()
        for it in items:
            if it['role'] and it['role'] in seen:
                it['role'] = ''
            elif it['role']:
                seen.add(it['role'])
        store.set_folders(self.id, items)
        # counts for every folder (STATUS is cheap; skip the selected one, it can't be STATUSed reliably)
        for f in store.folders(self.id):
            if f['role'] in ('important',):
                continue
            try:
                typ, data = c.status(ip.quote(f['path']), '(MESSAGES UNSEEN UIDNEXT UIDVALIDITY)')
            except imaplib.IMAP4.error:
                continue
            if typ != 'OK' or not data or not data[0]:
                continue
            raw = data[0] if isinstance(data[0], bytes) else data[0][0]
            m = dict(re.findall(rb'(MESSAGES|UNSEEN|UIDNEXT|UIDVALIDITY) (\d+)', raw))
            store.update_folder(self.id, f['path'], total=int(m.get(b'MESSAGES', 0)), unread=int(m.get(b'UNSEEN', 0)))

    def emit_folders(self, store):
        out = []
        for f in store.folders(self.id):
            if f['role'] == 'important':
                continue
            depth = f['path'].count(f['delim']) if f['delim'] else 0
            name = ROLE_NAMES.get(f['role']) or f['name']
            if self.gmail and f['path'].startswith('[Gmail]') and not f['role']:
                depth = 0
            elif f['role']:
                depth = 0
            out.append({'path': f['path'], 'name': name, 'role': f['role'], 'depth': depth,
                        'unread': f['unread'], 'total': f['total']})
        self.emit('folders', items=out)

    def sync_folder(self, conn, store, path, initial=INITIAL):
        """New messages, flag changes and deletions for one folder."""
        f = store.folder(self.id, path)
        info = conn.select(path, force=True)
        if f['uidvalidity'] and info['uidvalidity'] and f['uidvalidity'] != info['uidvalidity']:
            store.reset_folder(self.id, path)
            f = store.folder(self.id, path)
        cached = store.uids(self.id, path)
        changed = False
        if not cached:
            uids = conn.search('ALL') if info['exists'] else []
            want = uids[-initial:]
            server = set(want)
        else:
            lo = min(cached)
            server = set(conn.search('UID', f'{lo}:*')) if info['exists'] else set()
            hi = max(cached)
            want = sorted(u for u in server if u > hi)
            gone = cached - server
            if gone:
                store.delete(self.id, path, gone)
                changed = True
            # flags of what we already have (CONDSTORE: only what changed)
            keep = cached & server
            if keep:
                if f['highestmodseq'] and info.get('highestmodseq'):
                    if info['highestmodseq'] != f['highestmodseq']:
                        rows = ip.parse_fetch(conn.uid('FETCH', f'{lo}:*', f'(UID FLAGS) (CHANGEDSINCE {f["highestmodseq"]})'))
                        changed |= self.apply_flags(store, path, rows, keep)
                else:
                    for part in chunks(sorted(keep), 2000):
                        rows = ip.parse_fetch(conn.uid('FETCH', uidset(part), '(UID FLAGS)'))
                        changed |= self.apply_flags(store, path, rows, keep)
        if want:
            self.fetch_headers(conn, store, path, want)
            changed = True
        complete = 1 if (not cached and len(want) == len(server) and info['exists'] <= len(want)) or f['complete'] else 0
        kw = dict(uidvalidity=info['uidvalidity'], uidnext=info['uidnext'], synced=time.time(), total=info['exists'])
        if info.get('highestmodseq'):
            kw['highestmodseq'] = info['highestmodseq']
        if not cached:
            kw['complete'] = complete
        # unread: the server's count (the cache may hold only the newest part of the folder)
        try:
            kw['unread'] = len(conn.search('UNSEEN'))
        except imaplib.IMAP4.error:
            kw['unread'] = store.recount(self.id, path)[1]
        store.update_folder(self.id, path, **kw)
        if f['role'] == 'inbox':
            copied = self.notify_new(store, path, first=not cached and not f['notified'])
            mode = self.hub.code_trash_mode()
            if copied and mode == 'now':
                self.trash_codes(conn, store, path, copied)
            elif mode == 'day':
                self.cleanup_codes(conn, store, path)
        if changed:
            self.emit('changed', folder=path)
        return changed

    def trash_codes(self, conn, store, path, uids):
        """The code is on the clipboard: its mail goes to the Trash at once (read, so it doesn't
        count as unread there). Recoverable from the Trash like anything else."""
        trash = store.folder_by_role(self.id, 'trash')
        if not trash:
            return
        conn.select(path)
        conn.uid('STORE', uidset(uids), '+FLAGS.SILENT', '(\\Seen)')
        self.move(conn, store, path, uids, trash['path'])
        store.delete(self.id, path, uids)
        conn.select(path, force=True)
        f = store.folder(self.id, path)
        if f:
            store.update_folder(self.id, path, unread=max(0, f['unread'] - len(uids)))
        self.emit('changed', folder=path)
        self.emit_folders(store)
        self.hub.write_unread()

    def cleanup_codes(self, conn, store, path):
        """Login-code mails older than a day go to the Trash (like iOS "delete after use")."""
        old = [r[0] for r in store.db.execute(
            "SELECT uid FROM messages WHERE acc=? AND folder=? AND code!='' AND flagged=0 AND seen=1 AND date<?",
            (self.id, path, time.time() - 86400))]
        trash = store.folder_by_role(self.id, 'trash')
        if old and trash:
            self.move(conn, store, path, old, trash['path'])
            store.delete(self.id, path, old)
            conn.select(path, force=True)
            self.emit('changed', folder=path)

    def apply_flags(self, store, path, rows, keep):
        upd = {}
        for r in rows:
            uid = ip.num(r.get(b'UID'))
            if uid not in keep or b'FLAGS' not in r:
                continue
            fl = {ip.text(x).lower() for x in (r[b'FLAGS'] or [])}
            upd[uid] = {'seen': '\\seen' in fl, 'flagged': '\\flagged' in fl,
                        'answered': '\\answered' in fl, 'draft': '\\draft' in fl}
        if not upd:
            return False
        before = {u: store.message(self.id, path, u) for u in upd}
        store.set_flags(self.id, path, upd)
        return any(b and (b['seen'] != upd[u]['seen'] or b['flagged'] != upd[u]['flagged'] or b['answered'] != upd[u]['answered'])
                   for u, b in before.items())

    def fetch_headers(self, conn, store, path, uids, snippets=True):
        items = f'(UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS ({HEADER_FIELDS})]'
        if self.gmail:
            items += ' X-GM-THRID'
        items += ')'
        parts = {}
        rows_all = []
        for part in chunks(sorted(uids, reverse=True), BATCH):
            rows = []
            for r in ip.parse_fetch(conn.uid('FETCH', uidset(part), items)):
                uid = ip.num(r.get(b'UID'))
                if not uid:
                    continue
                hdr = None
                for k, v in r.items():
                    if k.startswith(b'BODY[HEADER'):
                        hdr = v
                bs = r.get(b'BODYSTRUCTURE')
                pnum, pinfo, att = ip.summarize_structure(bs) if isinstance(bs, list) else (None, None, False)
                idate = 0
                if r.get(b'INTERNALDATE'):
                    try:
                        idate = time.mktime(imaplib.Internaldate2tuple(b'INTERNALDATE "' + bytes(r[b'INTERNALDATE']) + b'"'))
                    except Exception:
                        idate = 0
                flags = [ip.text(x) for x in (r.get(b'FLAGS') or [])]
                row = mime.header_row(bytes(hdr or b''), uid, flags, idate, ip.num(r.get(b'RFC822.SIZE')),
                                      pnum or '', att, ip.text(r.get(b'X-GM-THRID')))
                rows.append(row)
                if pnum:
                    parts.setdefault(pnum, []).append((uid, pinfo))
            store.put_messages(self.id, path, rows)
            rows_all += rows
            if len(uids) > BATCH:
                self.emit('changed', folder=path)       # show the first batch while the rest loads
        people = []
        for r in rows_all:
            people.append((r['from_name'], r['from_addr']))
        f = store.folder(self.id, path)
        if f and f['role'] == 'sent':
            store.add_contacts([tuple(x) for r in rows_all for x in r['rcpt'] + r['cc']], sent=True)
        else:
            store.add_contacts(people)
        if snippets and parts:
            self.fetch_snippets(conn, store, path, parts)

    def fetch_snippets(self, conn, store, path, parts):
        """Previews from the first 3 KB of each text part — and login codes found there."""
        for pnum, items in parts.items():
            infos = {u: i for u, i in items}
            for part in chunks(sorted(infos, reverse=True), BATCH):
                subjects = dict(store.db.execute(
                    f"SELECT uid, subject FROM messages WHERE acc=? AND folder=? AND uid IN ({','.join('?' * len(part))})",
                    (self.id, path, *part)).fetchall())
                rows = ip.parse_fetch(conn.uid('FETCH', uidset(part), f'(UID BODY.PEEK[{pnum}]<0.3072>)'))
                out, found = {}, {}
                for r in rows:
                    uid = ip.num(r.get(b'UID'))
                    data = None
                    for k, v in r.items():
                        if k.startswith(b'BODY['):
                            data = v
                    if uid in infos:
                        txt = mime.part_text(bytes(data or b''), infos[uid])
                        out[uid] = mime.snippet_of_text(txt) or ' '
                        c = codes.find(subjects.get(uid, ''), txt)
                        if c:
                            found[uid] = c['code']
                store.set_snippets(self.id, path, out)
                if found:
                    store.set_codes(self.id, path, found)

    def all_snippets(self, conn, store):
        """Snippets missing after a restart (e.g. a sync cut short)."""
        for f in store.folders(self.id):
            missing = store.missing_snippets(self.id, f['path'])
            if not missing:
                continue
            conn.select(f['path'])
            # parts need structure info again: refetch it for these UIDs
            uids = [m['uid'] for m in missing]
            parts = {}
            for part in chunks(uids, BATCH):
                for r in ip.parse_fetch(conn.uid('FETCH', uidset(part), '(UID BODYSTRUCTURE)')):
                    bs = r.get(b'BODYSTRUCTURE')
                    pnum, pinfo, _ = ip.summarize_structure(bs) if isinstance(bs, list) else (None, None, False)
                    if pnum:
                        parts.setdefault(pnum, []).append((ip.num(r.get(b'UID')), pinfo))
            self.fetch_snippets(conn, store, f['path'], parts)
            self.emit('changed', folder=f['path'])

    def prefetch(self, conn, store, path):
        """Keep the newest inbox messages' bodies on disk so they open instantly."""
        rows = store.list(self.id, path, limit=PREFETCH)
        todo = [r['uid'] for r in rows if not os.path.exists(body_path(self.id, path, r['uid']))]
        if not todo:
            return
        conn.select(path)
        for part in chunks(todo, 10):
            rows = ip.parse_fetch(conn.uid('FETCH', uidset(part), '(UID RFC822.SIZE)'))
            small = [ip.num(r.get(b'UID')) for r in rows if ip.num(r.get(b'RFC822.SIZE')) < 2_000_000]
            if small:
                self.fetch_bodies(conn, path, small)

    def fetch_bodies(self, conn, path, uids):
        got = {}
        for r in ip.parse_fetch(conn.uid('FETCH', uidset(uids), '(UID BODY.PEEK[])')):
            uid = ip.num(r.get(b'UID'))
            raw = r.get(b'BODY[]')
            if uid and raw is not None:
                p = body_path(self.id, path, uid)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                tmp = p + '.tmp'
                with open(tmp, 'wb') as fh:
                    fh.write(bytes(raw))
                os.replace(tmp, p)
                got[uid] = p
        return got

    def do_older(self, conn, store, path):
        def run(c):
            c.select(path)
            lo = store.min_uid(self.id, path)
            if not lo:
                return self.sync_folder(c, store, path)
            uids = c.search('UID', f'1:{lo - 1}') if lo > 1 else []
            uids = [u for u in uids if u < lo]
            want = uids[-PAGE:]
            if want:
                self.fetch_headers(c, store, path, want)
            if len(uids) <= PAGE:
                store.update_folder(self.id, path, complete=1)
            self.emit('changed', folder=path, older=True, complete=len(uids) <= PAGE)
        conn.run(run)

    # ---------------------------------------------------------------- new mail
    def notify_new(self, store, path, first=False):
        f = store.folder(self.id, path)
        top = store.max_uid(self.id, path)
        if first or not f['notified']:
            store.update_folder(self.id, path, notified=top)
            return []
        if top <= f['notified']:
            return []
        # claim the range atomically, so the app and the background checker never both notify
        with store.db:
            cur = store.db.execute('UPDATE folders SET notified=? WHERE acc=? AND path=? AND notified=?',
                                   (top, self.id, path, f['notified']))
        if cur.rowcount != 1:
            return []
        rows = store.db.execute('SELECT * FROM messages WHERE acc=? AND folder=? AND uid>? AND seen=0 ORDER BY uid',
                                (self.id, path, f['notified'])).fetchall()
        if rows:
            return self.hub.notify(self.conf, path, [dict(r) for r in rows]) or []
        return []

    def idle_loop(self):
        """Wake the bg sync whenever the inbox changes (IDLE), or every few minutes."""
        backoff = 15
        while not self.stopped.is_set():
            if self.auth_failed:
                self.stopped.wait(30)
                continue
            try:
                c = imap_connect(self.conf, timeout=60)
                self.idle_conn = c
                if 'IDLE' not in c.capabilities:
                    c.logout()
                    self.idle_conn = None
                    self.wake.wait(self.hub.poll_seconds())
                    self.wake.clear()
                    if not self.stopped.is_set():
                        self.bg('refresh')
                    continue
                c.select('INBOX', readonly=True)
                backoff = 15
                while not self.stopped.is_set():
                    hit = False
                    with c.idle(duration=9 * 60) as idler:
                        for typ, _ in idler:
                            if typ in ('EXISTS', 'EXPUNGE', 'FETCH', 'RECENT'):
                                hit = True
                                break
                    if self.stopped.is_set():
                        break
                    self.bg('sync', path='INBOX') if hit else self.bg('refresh')
                    c.noop()
            except AuthError:
                self.stopped.wait(60)
            except Exception as e:
                if self.stopped.is_set():
                    break
                self.hub.log(f'{self.id} idle: {e}')
                self.stopped.wait(backoff)
                backoff = min(backoff * 2, 300)
            finally:
                c, self.idle_conn = self.idle_conn, None
                if c is not None:
                    try:
                        c.logout()
                    except Exception:
                        pass

    # ---------------------------------------------------------------- opening a message
    def do_open(self, conn, store, path, uid, rid=0, mark=True):
        p = body_path(self.id, path, uid)
        if not os.path.exists(p):
            def get(c):
                c.select(path)
                return self.fetch_bodies(c, path, [uid])
            if not conn.run(get).get(uid):
                self.emit('msg', rid=rid, folder=path, uid=uid, error='This message is no longer on the server.')
                return
        with open(p, 'rb') as fh:
            raw = fh.read()
        v = mime.view(raw, self.hub.colors)
        self.hub.prepare_images(self.id, path, uid, raw, v)
        row = store.message(self.id, path, uid)
        v['thread'] = []
        if row:
            others = [m for m in store.thread(self.id, row['thrid'], row['msgid'], v['refs']) if m['msgid'] != row['msgid']]
            v['thread'] = others[-20:]
        v['showImages'] = self.hub.images_allowed(v['from'][0][1] if v['from'] else '')
        c = codes.find(v['subject'], mime.text_of(raw))
        v['code'] = c['code'] if c else ''
        self.emit('msg', rid=rid, folder=path, uid=uid, view=v, row=row)
        if mark and row and not row['seen']:
            self.do_flag(conn, store, [uid], path, 'seen', True)

    def body(self, store, path, uid):
        """The cached .eml (fetched by fg if needed). Returns bytes or None."""
        p = body_path(self.id, path, uid)
        if os.path.exists(p):
            with open(p, 'rb') as fh:
                return fh.read()
        return None

    def do_fetchraw(self, conn, store, path, uid, then):
        """Make sure a body is cached, then call then(raw) on this thread (attachments, forward)."""
        raw = self.body(store, path, uid)
        if raw is None:
            def get(c):
                c.select(path)
                return self.fetch_bodies(c, path, [uid])
            conn.run(get)
            raw = self.body(store, path, uid)
        then(raw)

    # ---------------------------------------------------------------- actions
    def do_flag(self, conn, store, uids, path, what, on, quiet=False):
        flag = {'seen': '\\Seen', 'flagged': '\\Flagged', 'answered': '\\Answered'}[what]

        def run(c):
            c.select(path)
            c.uid('STORE', uidset(uids), '+FLAGS.SILENT' if on else '-FLAGS.SILENT', f'({flag})')
        conn.run(run)
        store.set_flag(self.id, path, uids, what, on)
        if what == 'seen':
            f = store.folder(self.id, path)
            if f:
                store.update_folder(self.id, path, unread=max(0, f['unread'] + (-len(uids) if on else len(uids))))
            self.emit_folders(store)
            self.hub.write_unread()
        if not quiet:
            self.emit('changed', folder=path)

    def target(self, conn, store, role):
        f = store.folder_by_role(self.id, role)
        if f:
            return f['path']
        if role == 'archive' and self.gmail:
            f = store.folder_by_role(self.id, 'all')
            if f:
                return f['path']
        # no such folder yet: make one (Archive / Trash / Spam)
        name = {'archive': 'Archive', 'trash': 'Trash', 'junk': 'Spam'}.get(role)
        if not name:
            return None

        def mk(c):
            typ, data = c.c.create(ip.quote(name))
            c.c.subscribe(ip.quote(name))
        try:
            conn.run(mk)
        except imaplib.IMAP4.error:
            pass
        conn.run(lambda c: self.sync_folder_list(c, store))
        f = store.folder(self.id, name)
        if f and not f['role']:
            store.update_folder(self.id, name, role=role)
        self.emit_folders(store)
        return name

    def move(self, conn, store, path, uids, dest):
        def run(c):
            c.select(path)
            s = uidset(uids)
            if 'MOVE' in c.caps:
                c.uid('MOVE', s, ip.quote(dest))
            else:
                c.uid('COPY', s, ip.quote(dest))
                c.uid('STORE', s, '+FLAGS.SILENT', '(\\Deleted)')
                if 'UIDPLUS' in c.caps:
                    c.uid('EXPUNGE', s)
                else:
                    c.c.expunge()
        conn.run(run)

    def do_act(self, conn, store, op, path, uids, rid=0, dest=None, msgids=None):
        """archive / trash / spam / notspam / move / delete (forever) / seen / unseen / flag / unflag."""
        if op in ('seen', 'unseen', 'flag', 'unflag'):
            self.do_flag(conn, store, uids, path, 'seen' if op in ('seen', 'unseen') else 'flagged', op in ('seen', 'flag'))
            self.emit('acted', rid=rid, op=op, folder=path, uids=uids)
            return
        f = store.folder(self.id, path) or {'role': ''}
        if op == 'delete' or (op == 'trash' and f['role'] == 'trash'):
            def run(c):
                c.select(path)
                s = uidset(uids)
                c.uid('STORE', s, '+FLAGS.SILENT', '(\\Deleted)')
                if 'UIDPLUS' in c.caps:
                    c.uid('EXPUNGE', s)
                else:
                    c.c.expunge()
            conn.run(run)
            store.delete(self.id, path, uids)
            dest = None
        else:
            if op == 'notspam':
                dest = (store.folder_by_role(self.id, 'inbox') or {}).get('path', 'INBOX')
            elif op != 'move':
                dest = self.target(conn, store, {'archive': 'archive', 'trash': 'trash', 'spam': 'junk'}[op])
            if not dest or dest == path:
                self.emit('acted', rid=rid, op=op, folder=path, uids=[], text='Nothing to do here')
                return
            self.move(conn, store, path, uids, dest)
            store.delete(self.id, path, uids)
        self.emit('acted', rid=rid, op=op, folder=path, uids=uids, dest=dest or '', msgids=msgids or [])
        self.emit('changed', folder=path)
        # the destination's counts / list catch up in the background
        if dest:
            self.bg('sync', path=dest) if dest in self.watch else self.bg('counts')
        else:
            self.bg('counts')

    def do_counts(self, conn, store):
        conn.run(lambda c: self.sync_folder_list(c, store))
        self.emit_folders(store)
        self.hub.write_unread()

    def do_undo(self, conn, store, src, dest, msgids, rid=0):
        """Move messages back from dest to src, found by Message-ID (works without UIDPLUS)."""
        def run(c):
            c.select(dest, force=True)
            uids = []
            for mid in msgids:
                if mid:
                    uids += c.search('HEADER', 'Message-ID', ip.quote(mid))
            return uids
        uids = conn.run(run)
        if uids:
            self.move(conn, store, dest, uids, src)
            store.delete(self.id, dest, uids)
            conn.run(lambda c: self.sync_folder(c, store, src))
            self.emit('changed', folder=dest)
        self.emit('undone', rid=rid, n=len(uids), folder=src)
        self.bg('counts')

    # ---------------------------------------------------------------- search
    def do_search(self, conn, store, q, rid, path=None):
        """Server search. Gmail: Gmail's own syntax over All mail. Others: inbox, sent and
        archive (or the given folder), newest first."""
        results = []
        if self.gmail:
            allf = store.folder_by_role(self.id, 'all')
            folders = [allf['path']] if allf else ['INBOX']
        elif path:
            folders = [path]
        else:
            folders = [f['path'] for f in (store.folder_by_role(self.id, r) for r in ('inbox', 'sent', 'archive')) if f]

        def run(c):
            out = []
            for p in folders:
                c.select(p)
                if self.gmail:
                    c.c.literal = q.encode()
                    uids = c.search('CHARSET', 'UTF-8', 'X-GM-RAW')
                else:
                    try:
                        c.c.literal = q.encode()
                        uids = c.search('CHARSET', 'UTF-8', 'TEXT')
                    except imaplib.IMAP4.error:
                        uids = c.search('TEXT', ip.quote(q.encode('ascii', 'ignore').decode()))
                uids = sorted(uids)[-60:]
                if not uids:
                    continue
                items = f'(UID FLAGS INTERNALDATE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS ({HEADER_FIELDS})]' + (' X-GM-THRID)' if self.gmail else ')')
                for r in ip.parse_fetch(c.uid('FETCH', uidset(uids), items)):
                    uid = ip.num(r.get(b'UID'))
                    hdr = next((v for k, v in r.items() if k.startswith(b'BODY[HEADER')), b'')
                    bs = r.get(b'BODYSTRUCTURE')
                    pnum, pinfo, att = ip.summarize_structure(bs) if isinstance(bs, list) else (None, None, False)
                    row = mime.header_row(bytes(hdr or b''), uid, [ip.text(x) for x in (r.get(b'FLAGS') or [])],
                                          0, 0, pnum or '', att, ip.text(r.get(b'X-GM-THRID')))
                    cached = store.message(self.id, p, uid)
                    row['snippet'] = cached['snippet'] if cached else ''
                    row['acc'], row['folder'] = self.id, p
                    out.append(row)
            return out
        results = conn.run(run)
        results.sort(key=lambda r: -r['date'])
        for r in results:
            r.pop('cc', None)
            r.pop('refs', None)
            r.pop('part', None)
            r.pop('size', None)
            r.pop('draft', None)
        self.emit('search', rid=rid, items=results[:100])

    # ---------------------------------------------------------------- sending
    def do_send(self, conn, store, draft, attachments, rid, forward=None):
        fwd = []
        if forward:
            raw = self.body(store, forward['folder'], forward['uid'])
            if raw is None:
                def get(c):
                    c.select(forward['folder'])
                    return self.fetch_bodies(c, forward['folder'], [forward['uid']])
                conn.run(get)
                raw = self.body(store, forward['folder'], forward['uid'])
            if raw is not None:
                msg = mime.parse(raw)
                for i in forward.get('keep', []):
                    name, data = mime.attachment_bytes(msg, i)
                    if name is not None:
                        _, _, _, atts = mime.walk_parts(msg)
                        fwd.append((name, atts[i].get_content_type(), data))
        msg, rcpts = mime.build(self.conf, draft, attachments, fwd)
        if not rcpts:
            self.emit('sent', rid=rid, ok=False, text='Add at least one recipient.')
            return
        s = smtp_connect(self.conf)
        try:
            s.send_message(msg, from_addr=self.conf['email'], to_addrs=rcpts)
        finally:
            try:
                s.quit()
            except Exception:
                pass
        store.add_contacts(mime.parse_rcpt(draft.get('to', '') + ',' + draft.get('cc', '') + ',' + draft.get('bcc', '')), sent=True)
        self.emit('sent', rid=rid, ok=True)
        # a copy in Sent (Gmail files it by itself), and \Answered on the original
        try:
            if not self.gmail:
                sent = store.folder_by_role(self.id, 'sent')
                if sent:
                    def app(c):
                        c.c.append(ip.quote(sent['path']), '(\\Seen)', imaplib.Time2Internaldate(time.time()), bytes(msg))
                    conn.run(app)
            if draft.get('replyTo'):
                rt = draft['replyTo']
                self.do_flag(conn, store, [rt['uid']], rt['folder'], 'answered', True, quiet=True)
        except Exception as e:
            self.hub.log(f'{self.id} after-send: {e}')
        self.bg('counts')
        sent = store.folder_by_role(self.id, 'sent')
        if sent and sent['path'] in self.watch:
            self.bg('sync', path=sent['path'])
