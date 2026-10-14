"""The local cache: folders and message headers in SQLite (~/.cache/glass-mail/mail.db), full
messages as .eml files under bodies/. Everything here can be rebuilt from the servers.
One Store per thread (sqlite connections are not shared); WAL lets the app and the
background checker use it at the same time."""
import hashlib
import json
import os
import shutil
import sqlite3
import time

from . import paths

SCHEMA = """
CREATE TABLE IF NOT EXISTS folders (
    acc TEXT, path TEXT, name TEXT, role TEXT, delim TEXT, flags TEXT,
    uidvalidity INTEGER DEFAULT 0, uidnext INTEGER DEFAULT 0, highestmodseq INTEGER DEFAULT 0,
    total INTEGER DEFAULT 0, unread INTEGER DEFAULT 0, oldest INTEGER DEFAULT 0,
    complete INTEGER DEFAULT 0, synced REAL DEFAULT 0, notified INTEGER DEFAULT 0,
    PRIMARY KEY (acc, path)
);
CREATE TABLE IF NOT EXISTS messages (
    acc TEXT, folder TEXT, uid INTEGER,
    msgid TEXT, thrid TEXT, date REAL, from_name TEXT, from_addr TEXT,
    rcpt TEXT, cc TEXT, subject TEXT, snippet TEXT,
    seen INTEGER, flagged INTEGER, answered INTEGER, draft INTEGER,
    att INTEGER, size INTEGER, refs TEXT, unsub TEXT, part TEXT,
    PRIMARY KEY (acc, folder, uid)
);
CREATE INDEX IF NOT EXISTS messages_date ON messages (acc, folder, date DESC);
CREATE INDEX IF NOT EXISTS messages_msgid ON messages (msgid);
CREATE TABLE IF NOT EXISTS ai (k TEXT PRIMARY KEY, data TEXT, at REAL);
CREATE TABLE IF NOT EXISTS contacts (
    addr TEXT PRIMARY KEY, name TEXT, n INTEGER DEFAULT 0, sent INTEGER DEFAULT 0, last REAL DEFAULT 0
);
"""

ROLE_ORDER = ['inbox', 'flagged', 'sent', 'drafts', 'archive', 'all', 'junk', 'trash']
LIST_COLS = ('uid', 'msgid', 'thrid', 'date', 'from_name', 'from_addr', 'rcpt', 'subject', 'snippet',
             'seen', 'flagged', 'answered', 'att', 'unsub', 'acc', 'folder', 'code')


class Store:
    def __init__(self, path=None):
        paths.ensure()
        self.db = sqlite3.connect(path or paths.DB, timeout=15)
        self.db.row_factory = sqlite3.Row
        # SQLite's LIKE / lower() only fold ASCII: «Лена» wouldn't match «лена» without this
        self.db.create_function('ulower', 1, lambda v: v.lower() if isinstance(v, str) else v, deterministic=True)
        # several threads open a brand-new cache at once: switching to WAL / creating the
        # tables needs the lock briefly, and the busy timeout doesn't cover journal_mode
        for attempt in range(50):
            try:
                self.db.execute('PRAGMA journal_mode=WAL')
                self.db.execute('PRAGMA synchronous=NORMAL')
                self.db.executescript(SCHEMA)
                cols = {r[1] for r in self.db.execute('PRAGMA table_info(messages)')}
                if 'code' not in cols:                         # added with login codes
                    self.db.execute("ALTER TABLE messages ADD COLUMN code TEXT DEFAULT ''")
                break
            except sqlite3.OperationalError as e:
                if 'locked' not in str(e) or attempt == 49:
                    raise
                time.sleep(0.1)

    def close(self):
        self.db.close()

    # ---------------------------------------------------------------- folders
    def folders(self, acc):
        rows = [dict(r) for r in self.db.execute('SELECT * FROM folders WHERE acc=?', (acc,))]

        def key(r):
            role = r['role'] or ''
            return (ROLE_ORDER.index(role) if role in ROLE_ORDER else len(ROLE_ORDER), r['path'].lower())
        rows.sort(key=key)
        return rows

    def folder(self, acc, path):
        r = self.db.execute('SELECT * FROM folders WHERE acc=? AND path=?', (acc, path)).fetchone()
        return dict(r) if r else None

    def folder_by_role(self, acc, role):
        r = self.db.execute('SELECT * FROM folders WHERE acc=? AND role=? ORDER BY path LIMIT 1', (acc, role)).fetchone()
        return dict(r) if r else None

    def set_folders(self, acc, items):
        """items: [{path, name, role, delim, flags}] from LIST; drops folders that are gone."""
        with self.db:
            have = {r['path'] for r in self.db.execute('SELECT path FROM folders WHERE acc=?', (acc,))}
            new = set()
            for f in items:
                new.add(f['path'])
                if f['path'] in have:
                    self.db.execute('UPDATE folders SET name=?, role=?, delim=?, flags=? WHERE acc=? AND path=?',
                                    (f['name'], f['role'], f['delim'], f['flags'], acc, f['path']))
                else:
                    self.db.execute('INSERT INTO folders (acc, path, name, role, delim, flags) VALUES (?,?,?,?,?,?)',
                                    (acc, f['path'], f['name'], f['role'], f['delim'], f['flags']))
            for gone in have - new:
                self.drop_folder(acc, gone)

    def update_folder(self, acc, path, **kw):
        if not kw:
            return
        cols = ', '.join(k + '=?' for k in kw)
        with self.db:
            self.db.execute(f'UPDATE folders SET {cols} WHERE acc=? AND path=?', (*kw.values(), acc, path))

    def drop_folder(self, acc, path):
        with self.db:
            self.db.execute('DELETE FROM messages WHERE acc=? AND folder=?', (acc, path))
            self.db.execute('DELETE FROM folders WHERE acc=? AND path=?', (acc, path))
        shutil.rmtree(body_dir(acc, path), ignore_errors=True)

    def reset_folder(self, acc, path):
        """UIDVALIDITY changed: every cached UID is meaningless now."""
        with self.db:
            self.db.execute('DELETE FROM messages WHERE acc=? AND folder=?', (acc, path))
            self.db.execute('UPDATE folders SET oldest=0, complete=0, notified=0, highestmodseq=0 WHERE acc=? AND path=?', (acc, path))
        shutil.rmtree(body_dir(acc, path), ignore_errors=True)

    def drop_account(self, acc):
        with self.db:
            self.db.execute('DELETE FROM messages WHERE acc=?', (acc,))
            self.db.execute('DELETE FROM folders WHERE acc=?', (acc,))
        shutil.rmtree(os.path.join(paths.BODIES, acc), ignore_errors=True)

    def recount(self, acc, path):
        r = self.db.execute('SELECT COUNT(*) AS n, SUM(seen=0) AS u FROM messages WHERE acc=? AND folder=?', (acc, path)).fetchone()
        return r['n'] or 0, r['u'] or 0

    # ---------------------------------------------------------------- messages
    def uids(self, acc, folder):
        return {r[0] for r in self.db.execute('SELECT uid FROM messages WHERE acc=? AND folder=?', (acc, folder))}

    def max_uid(self, acc, folder):
        r = self.db.execute('SELECT MAX(uid) FROM messages WHERE acc=? AND folder=?', (acc, folder)).fetchone()
        return r[0] or 0

    def min_uid(self, acc, folder):
        r = self.db.execute('SELECT MIN(uid) FROM messages WHERE acc=? AND folder=?', (acc, folder)).fetchone()
        return r[0] or 0

    def put_messages(self, acc, folder, msgs):
        with self.db:
            for m in msgs:
                self.db.execute(
                    'INSERT OR REPLACE INTO messages (acc, folder, uid, msgid, thrid, date, from_name, from_addr, rcpt, cc,'
                    ' subject, snippet, seen, flagged, answered, draft, att, size, refs, unsub, part, code)'
                    ' VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                    (acc, folder, m['uid'], m.get('msgid', ''), m.get('thrid', ''), m.get('date', 0),
                     m.get('from_name', ''), m.get('from_addr', ''), json.dumps(m.get('rcpt', [])),
                     json.dumps(m.get('cc', [])), m.get('subject', ''), m.get('snippet', ''),
                     int(m.get('seen', 0)), int(m.get('flagged', 0)), int(m.get('answered', 0)),
                     int(m.get('draft', 0)), int(m.get('att', 0)), m.get('size', 0), m.get('refs', ''),
                     m.get('unsub', ''), m.get('part', ''), m.get('code', '')))

    def set_snippets(self, acc, folder, snippets):
        with self.db:
            for uid, s in snippets.items():
                self.db.execute('UPDATE messages SET snippet=? WHERE acc=? AND folder=? AND uid=?', (s, acc, folder, uid))

    def set_codes(self, acc, folder, codes):
        with self.db:
            for uid, c in codes.items():
                self.db.execute('UPDATE messages SET code=? WHERE acc=? AND folder=? AND uid=?', (c, acc, folder, uid))

    def ai_get(self, k):
        r = self.db.execute('SELECT data FROM ai WHERE k=?', (k,)).fetchone()
        return json.loads(r[0]) if r else None

    def ai_put(self, k, data):
        with self.db:
            self.db.execute('INSERT OR REPLACE INTO ai (k, data, at) VALUES (?,?,?)', (k, json.dumps(data, ensure_ascii=False), time.time()))

    def sent_contacts(self):
        return {r[0] for r in self.db.execute('SELECT addr FROM contacts WHERE sent>0')}

    def unread_inbox(self, accs, limit=25):
        if not accs:
            return []
        q = (f'SELECT m.* FROM messages m JOIN folders f ON f.acc=m.acc AND f.path=m.folder'
             f" WHERE f.role='inbox' AND m.seen=0 AND m.acc IN ({','.join('?' * len(accs))}) ORDER BY m.date DESC LIMIT ?")
        return [row_out(r) for r in self.db.execute(q, (*accs, limit))]

    def missing_snippets(self, acc, folder, limit=200):
        return [dict(r) for r in self.db.execute(
            "SELECT uid, part FROM messages WHERE acc=? AND folder=? AND snippet='' AND part!=''"
            ' ORDER BY uid DESC LIMIT ?', (acc, folder, limit))]

    def set_flags(self, acc, folder, flags_by_uid):
        """flags_by_uid: {uid: {seen, flagged, answered, draft}}"""
        with self.db:
            for uid, f in flags_by_uid.items():
                self.db.execute('UPDATE messages SET seen=?, flagged=?, answered=?, draft=? WHERE acc=? AND folder=? AND uid=?',
                                (int(f['seen']), int(f['flagged']), int(f['answered']), int(f['draft']), acc, folder, uid))

    def set_flag(self, acc, folder, uids, col, val):
        assert col in ('seen', 'flagged', 'answered')
        with self.db:
            self.db.executemany(f'UPDATE messages SET {col}=? WHERE acc=? AND folder=? AND uid=?',
                                [(int(val), acc, folder, u) for u in uids])

    def delete(self, acc, folder, uids):
        uids = list(uids)
        if not uids:
            return
        with self.db:
            self.db.executemany('DELETE FROM messages WHERE acc=? AND folder=? AND uid=?', [(acc, folder, u) for u in uids])
        d = body_dir(acc, folder)
        for u in uids:
            for name in (f'{u}.eml',):
                try:
                    os.unlink(os.path.join(d, name))
                except OSError:
                    pass

    def message(self, acc, folder, uid):
        r = self.db.execute('SELECT * FROM messages WHERE acc=? AND folder=? AND uid=?', (acc, folder, uid)).fetchone()
        return row_out(r) if r else None

    def list(self, acc, folder, limit=200, before=None):
        q = 'SELECT * FROM messages WHERE acc=? AND folder=?'
        args = [acc, folder]
        if before is not None:
            q += ' AND date < ?'
            args.append(before)
        q += ' ORDER BY date DESC, uid DESC LIMIT ?'
        args.append(limit)
        return [row_out(r) for r in self.db.execute(q, args)]

    def list_role(self, accs, role, limit=200, before=None):
        """A merged view over several accounts (All inboxes)."""
        if not accs:
            return []
        q = ('SELECT m.* FROM messages m JOIN folders f ON f.acc=m.acc AND f.path=m.folder'
             f' WHERE f.role=? AND m.acc IN ({",".join("?" * len(accs))})')
        args = [role, *accs]
        if before is not None:
            q += ' AND m.date < ?'
            args.append(before)
        q += ' ORDER BY m.date DESC LIMIT ?'
        args.append(limit)
        return [row_out(r) for r in self.db.execute(q, args)]

    def flagged(self, accs, limit=300):
        if not accs:
            return []
        q = (f'SELECT m.* FROM messages m JOIN folders f ON f.acc=m.acc AND f.path=m.folder'
             f" WHERE m.flagged=1 AND m.acc IN ({','.join('?' * len(accs))}) AND COALESCE(f.role,'') NOT IN ('all','trash','junk')"
             ' ORDER BY m.date DESC LIMIT ?')
        return [row_out(r) for r in self.db.execute(q, (*accs, limit))]

    def search_local(self, accs, q, limit=100):
        if not accs or not q.strip():
            return []
        like = '%' + q.strip().lower().replace('%', '').replace('_', '') + '%'
        rows = self.db.execute(
            f'SELECT m.* FROM messages m JOIN folders f ON f.acc=m.acc AND f.path=m.folder'
            f" WHERE m.acc IN ({','.join('?' * len(accs))}) AND COALESCE(f.role,'') NOT IN ('trash','junk')"
            ' AND (ulower(m.subject) LIKE ? OR ulower(m.from_name) LIKE ? OR ulower(m.from_addr) LIKE ?'
            ' OR ulower(m.snippet) LIKE ? OR ulower(m.rcpt) LIKE ?)'
            ' ORDER BY m.date DESC LIMIT ?', (*accs, like, like, like, like, like, limit * 3))
        out, seen = [], set()
        for r in rows:            # Gmail keeps one message in several folders (labels): show it once
            k = r['msgid'] or (r['acc'], r['folder'], r['uid'])
            if k in seen:
                continue
            seen.add(k)
            out.append(row_out(r))
            if len(out) >= limit:
                break
        return out

    def by_msgid(self, msgid):
        return [row_out(r) for r in self.db.execute('SELECT * FROM messages WHERE msgid=?', (msgid,))]

    def thread(self, acc, thrid, msgid, refs):
        """Other cached messages of the same conversation (Gmail thread id, else References)."""
        if thrid:
            rows = self.db.execute('SELECT * FROM messages WHERE acc=? AND thrid=? ORDER BY date', (acc, thrid))
        else:
            ids = [i for i in (refs or '').split() if i] + ([msgid] if msgid else [])
            if not ids:
                return []
            ph = ','.join('?' * len(ids))
            rows = self.db.execute(f"SELECT * FROM messages WHERE acc=? AND (msgid IN ({ph}) OR refs LIKE ?) ORDER BY date",
                                   (acc, *ids, '%' + (msgid or '\x00') + '%'))
        out, seen = [], set()
        for r in rows:
            k = r['msgid'] or r['uid']
            if k in seen:
                continue
            seen.add(k)
            out.append(row_out(r))
        return out

    # ---------------------------------------------------------------- contacts
    def add_contacts(self, people, sent=False, when=None):
        """people: [(name, addr)]"""
        when = when or time.time()
        with self.db:
            for name, addr in people:
                addr = (addr or '').strip().lower()
                if not addr or '@' not in addr or 'noreply' in addr or 'no-reply' in addr:
                    continue
                self.db.execute(
                    'INSERT INTO contacts (addr, name, n, sent, last) VALUES (?,?,1,?,?)'
                    ' ON CONFLICT(addr) DO UPDATE SET n=n+1, sent=sent+excluded.sent,'
                    " name=CASE WHEN excluded.name!='' THEN excluded.name ELSE name END, last=MAX(last, excluded.last)",
                    (addr, name or '', int(sent), when))

    def contacts(self, q, limit=8):
        like = '%' + q.strip().lower().replace('%', '') + '%'
        rows = self.db.execute('SELECT * FROM contacts WHERE addr LIKE ? OR ulower(name) LIKE ?'
                               ' ORDER BY sent*5 + n DESC, last DESC LIMIT ?', (like, like, limit))
        return [{'name': r['name'], 'addr': r['addr']} for r in rows]

    def unread_counts(self):
        rows = self.db.execute("SELECT acc, unread FROM folders WHERE role='inbox'")
        return {r['acc']: r['unread'] for r in rows}


def row_out(r):
    d = {k: r[k] for k in LIST_COLS}
    d['rcpt'] = json.loads(d['rcpt'] or '[]')
    d['seen'] = bool(d['seen'])
    d['flagged'] = bool(d['flagged'])
    d['answered'] = bool(d['answered'])
    d['att'] = bool(d['att'])
    d['code'] = d['code'] or ''
    return d


def body_dir(acc, folder):
    return os.path.join(paths.BODIES, acc, hashlib.sha1(folder.encode()).hexdigest()[:16])


def body_path(acc, folder, uid):
    return os.path.join(body_dir(acc, folder), f'{uid}.eml')
