"""Glass Mail backend: JSON lines on stdin/stdout between the quickshell window and the mail
accounts (engine.Account). Run by the window as `python3 -m glassmail.server`."""
import base64
import hashlib
import json
import mimetypes
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
import traceback

from . import accounts as accmod
from . import ai as aimod
from . import engine
from . import mime
from . import paths
from .store import Store

_out = threading.Lock()


class Hub:
    def __init__(self):
        paths.ensure()
        self._local = threading.local()
        self.accounts = {}
        self.settings = {'markRead': True, 'notify': True, 'imagesFrom': [], 'imagesAlways': False, 'pollMinutes': 3,
                         'autoCopyCodes': True, 'codesTrash': 'now', 'aiOn': True, 'aiAuto': True, 'translateTo': 'ru'}
        self.settings.update(accmod.load_settings())
        self.colors = {}
        self.view = None
        self._ai = None

    @property
    def ai(self):
        if self._ai is None:
            self._ai = aimod.AI(self.emit, self.log)
        return self._ai

    # ---------------------------------------------------------------- plumbing
    @property
    def store(self):
        """This thread's cache connection (sqlite connections can't cross threads)."""
        s = getattr(self._local, 'store', None)
        if s is None:
            s = self._local.store = Store()
        return s

    def emit(self, obj):
        line = json.dumps(obj, ensure_ascii=False, default=str)
        with _out:
            sys.stdout.write(line + '\n')
            sys.stdout.flush()

    def log(self, msg):
        with _out:
            sys.stderr.write(msg.rstrip() + '\n')
            sys.stderr.flush()

    def toast(self, icon, text):
        self.emit({'type': 'toast', 'icon': icon, 'text': text})

    def poll_seconds(self):
        return max(1, int(self.settings.get('pollMinutes') or 3)) * 60

    def save_settings(self):
        accmod.save_settings(self.settings)
        self.emit({'type': 'settings', 'settings': self.settings})

    # ---------------------------------------------------------------- accounts
    def start_accounts(self):
        for conf in accmod.load():
            self.start_account(conf)

    def start_account(self, conf):
        old = self.accounts.pop(conf['id'], None)
        if old:
            old.stop()
        a = engine.Account(conf, self)
        self.accounts[conf['id']] = a
        a.start()
        return a

    def send_accounts(self):
        confs = accmod.load()
        self.emit({'type': 'accounts', 'items': [accmod.public(c) | {'status': self.accounts[c['id']].status if c['id'] in self.accounts else {}}
                                                 for c in confs]})
        for c in confs:
            a = self.accounts.get(c['id'])
            if a:
                a.emit_folders(self.store)

    def account_save(self, d, rid):
        """Add or edit an account: check the login first, then save and start it."""
        def run():
            confs = accmod.load()
            email = d['email'].strip()
            aid = d.get('id') or accmod.account_id(email)
            old = next((c for c in confs if c['id'] == aid), {})
            g = accmod.guess(email)
            conf = {
                'id': aid, 'email': email, 'name': d.get('name', '').strip(),
                'user': (d.get('user') or '').strip() or email,
                'password': d.get('password') or old.get('password', ''),
                'provider': g['provider'],
                'imap': {'host': d.get('imapHost') or g['imap']['host'], 'port': int(d.get('imapPort') or g['imap']['port'])},
                'smtp': {'host': d.get('smtpHost') or g['smtp']['host'], 'port': int(d.get('smtpPort') or g['smtp']['port']),
                         'security': d.get('smtpSecurity') or g['smtp']['security']},
                'signature': d.get('signature', old.get('signature', '')),
                'color': old.get('color') or accmod.COLORS[len(confs) % len(accmod.COLORS)],
            }
            try:
                n = engine.test_account(conf)
            except (engine.AuthError, ConnectionError) as e:
                self.emit({'type': 'account-saved', 'rid': rid, 'ok': False, 'text': str(e)})
                return
            except Exception as e:
                self.emit({'type': 'account-saved', 'rid': rid, 'ok': False, 'text': f'Sign-in failed: {e}'})
                return
            confs = accmod.load()
            pos = next((i for i, c in enumerate(confs) if c['id'] == aid), None)
            if pos is None:
                confs.append(conf)
            else:
                confs[pos] = conf                 # an edit keeps its place in the sidebar
            accmod.save(confs)
            self.start_account(conf)
            self.emit({'type': 'account-saved', 'rid': rid, 'ok': True, 'id': aid, 'folders': n})
            self.send_accounts()
        threading.Thread(target=run, daemon=True).start()

    def account_update(self, aid, fields):
        """Name / signature edits that don't need a new sign-in."""
        confs = accmod.load()
        for c in confs:
            if c['id'] == aid:
                for k in ('name', 'signature', 'color'):
                    if k in fields:
                        c[k] = fields[k]
                accmod.save(confs)
                if aid in self.accounts:
                    self.accounts[aid].conf.update({k: c[k] for k in ('name', 'signature', 'color') if k in c})
        self.send_accounts()

    def account_remove(self, aid):
        a = self.accounts.pop(aid, None)
        if a:
            a.stop()
        accmod.save([c for c in accmod.load() if c['id'] != aid])
        self.store.drop_account(aid)
        self.send_accounts()
        self.write_unread()
        self.toast('logout', 'Account removed from Glass Mail')

    # ---------------------------------------------------------------- lists
    def acc_ids(self):
        return [c['id'] for c in accmod.load()]

    def send_list(self, v, limit=300, rid=0):
        """v: {acc, folder} | {acc: '*', role: 'inbox'} | {kind: 'starred'}"""
        self.view = v
        if v.get('kind') == 'starred':
            items = self.store.flagged(self.acc_ids(), limit)
            complete = True
        elif v.get('acc') == '*':
            items = self.store.list_role(self.acc_ids(), v.get('role', 'inbox'), limit)
            complete = len(items) < limit
        else:
            items = self.store.list(v['acc'], v['folder'], limit)
            f = self.store.folder(v['acc'], v['folder'])
            complete = bool(f and (f['complete'] or (f['total'] and len(items) >= f['total'])))
        mine = self.store.sent_contacts()
        for r in items:
            r['cat'] = category(r, mine)
        self.emit({'type': 'list', 'rid': rid, 'view': v, 'items': items, 'complete': complete})

    def watch(self, v):
        """Keep the folders on screen fresh: sync now if stale, and on every refresh."""
        for a in self.accounts.values():
            a.watch.clear()
        targets = []
        if v.get('kind') == 'starred':
            for aid, a in self.accounts.items():
                f = self.store.folder_by_role(aid, 'flagged')
                if f:
                    targets.append((a, f['path']))
        elif v.get('acc') == '*':
            for aid, a in self.accounts.items():
                f = self.store.folder_by_role(aid, v.get('role', 'inbox'))
                if f:
                    targets.append((a, f['path']))
        elif v.get('acc') in self.accounts:
            targets.append((self.accounts[v['acc']], v['folder']))
        for a, p in targets:
            a.watch.add(p)
            f = self.store.folder(a.id, p)
            if not f or time.time() - (f['synced'] or 0) > 45:
                a.bg('sync', path=p)

    # ---------------------------------------------------------------- images
    def images_allowed(self, addr):
        if self.settings.get('imagesAlways'):
            return True
        addr = (addr or '').lower()
        dom = addr.rsplit('@', 1)[-1]
        allow = [x.lower() for x in self.settings.get('imagesFrom', [])]
        return addr in allow or ('@' + dom) in allow

    def prepare_images(self, acc, path, uid, raw, v):
        """cid: and data: images -> files QML can show; remote ones keep their URL in 'url'."""
        msg = None
        d = os.path.join(paths.IMAGES, acc)
        for b in v['blocks']:
            if b['t'] != 'img':
                continue
            if b.get('cid'):
                if msg is None:
                    msg = mime.parse(raw)
                    _, _, cids, _ = mime.walk_parts(msg)
                part = cids.get(b['cid'])
                if part is None:
                    b['t'] = 'skip'
                    continue
                data = part.get_payload(decode=True) or b''
                ext = mimetypes.guess_extension(part.get_content_type()) or '.img'
                b['src'] = self.write_image(d, data, ext)
            elif b.get('data'):
                m = re.match(r'data:(image/[\w.+-]+)?(;base64)?,(.*)$', b['data'], re.S)
                if not m or not m.group(2):
                    b['t'] = 'skip'
                    continue
                try:
                    data = base64.b64decode(m.group(3))
                except Exception:
                    b['t'] = 'skip'
                    continue
                b['src'] = self.write_image(d, data, mimetypes.guess_extension(m.group(1) or '') or '.img')
                del b['data']
            else:
                b['url'] = b['src']
                b['src'] = ''
        v['blocks'] = [b for b in v['blocks'] if b['t'] != 'skip']

    def write_image(self, d, data, ext):
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, hashlib.sha1(data).hexdigest()[:20] + ext)
        if not os.path.exists(p):
            with open(p, 'wb') as f:
                f.write(data)
        return 'file://' + p

    # ---------------------------------------------------------------- unread / notifications
    def write_unread(self):
        counts = self.store.unread_counts()
        ids = self.acc_ids()
        data = {'unread': sum(counts.get(i, 0) for i in ids), 'accounts': {i: counts.get(i, 0) for i in ids}, 'at': time.time()}
        try:
            tmp = paths.UNREAD + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(data, f)
            os.replace(tmp, paths.UNREAD)
        except OSError:
            pass
        self.emit({'type': 'unread', **data})

    def code_trash_mode(self):
        """What happens to a login-code mail: 'now' (Trash once copied), 'day', 'keep'."""
        m = self.settings.get('codesTrash')
        if m in ('now', 'day', 'keep'):
            return m
        return 'day' if self.settings.get('codesCleanup') else 'now'

    def notify(self, conf, path, rows):
        """-> UIDs whose login code went to the clipboard."""
        if not self.settings.get('notify', True):
            fresh = [r for r in rows if r.get('code') and r.get('date', 0) > time.time() - 15 * 60]
            if self.settings.get('autoCopyCodes', True):
                for r in fresh:                       # notifications off: still copy, just quietly
                    copy(r['code'], clear_after=180)
                return [r['uid'] for r in fresh]
            return []
        rows = [r for r in rows if r.get('date', 0) > time.time() - 2 * 86400]
        fresh_codes = [r for r in rows if r.get('code') and r.get('date', 0) > time.time() - 15 * 60]
        copied = [r['uid'] for r in fresh_codes if self.code_arrived(conf, path, r)]
        rows = [r for r in rows if r not in fresh_codes]
        if rows:
            notify(conf, path, rows)
        return copied

    def code_arrived(self, conf, path, r):
        """A fresh login code: straight to the clipboard (cleared after 3 min), like iOS."""
        who = r.get('from_name') or r.get('from_addr') or 'Login code'
        if self.settings.get('autoCopyCodes', True):
            copy(r['code'], clear_after=180)
            exe = os.path.expanduser('~/.local/bin/glass-mail')
            now = self.code_trash_mode() == 'now'
            _notify(f'{r["code"]} copied', f'{who}{" · mail moved to Trash" if now else ""}\nPaste it — the clipboard clears in 3 min.',
                    [exe] if now else [exe, '--open', conf['id'], path, str(r['uid'])], icon='dialog-password')
            self.emit({'type': 'code', 'code': r['code'], 'from': who, 'acc': conf['id'], 'folder': path, 'uid': r['uid']})
            return True
        else:
            _notify(f'Code {r["code"]} · {who}', r.get('subject') or '',
                    [os.path.expanduser('~/.local/bin/glass-mail'), '--open', conf['id'], path, str(r['uid'])], icon='dialog-password')


def notify(conf, path, rows):
    """A desktop notification with an Open action (glass-mail --open …), detached so it
    outlives the background checker."""
    exe = os.path.expanduser('~/.local/bin/glass-mail')
    if len(rows) <= 3:
        for r in rows:
            who = r.get('from_name') or r.get('from_addr') or 'New mail'
            body = (r.get('subject') or '(no subject)') + ('\n' + r['snippet'][:140] if (r.get('snippet') or '').strip() else '')
            _notify(who, body, [exe, '--open', conf['id'], path, str(r['uid'])])
    else:
        who = ', '.join(dict.fromkeys((r.get('from_name') or r.get('from_addr') or '?') for r in rows[-4:]))
        _notify(f'{len(rows)} new messages · {conf["email"]}', who, [exe])


def _notify(title, body, open_cmd, icon='glass-mail'):
    log = os.environ.get('GLASS_MAIL_NOTIFY_LOG')      # tests: record instead of showing
    if log:
        with open(log, 'a') as f:
            f.write(json.dumps({'title': title, 'body': body, 'open': open_cmd, 'icon': icon}, ensure_ascii=False) + '\n')
        return
    script = ('a=$(notify-send -a "Glass Mail" -i ' + shlex.quote(icon) + ' -c email.arrived -A default=Open -A open=Open '
              + shlex.quote(title) + ' ' + shlex.quote(body) + ' 2>/dev/null); '
              + 'case "$a" in default|open) exec ' + ' '.join(shlex.quote(x) for x in open_cmd) + ';; esac')
    try:
        subprocess.Popen(['sh', '-c', script], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def copy(text, clear_after=0):
    """Wayland clipboard (wl-copy); optionally cleared later if it still holds this text."""
    log = os.environ.get('GLASS_MAIL_NOTIFY_LOG')
    if log:                                                   # tests: never touch the real clipboard
        with open(log, 'a') as f:
            f.write(json.dumps({'copied': text}) + '\n')
        return
    try:
        subprocess.run(['wl-copy', '--', text], timeout=5, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return
    if clear_after:
        q = shlex.quote(text)
        subprocess.Popen(['sh', '-c', f'sleep {int(clear_after)}; [ "$(wl-paste -n 2>/dev/null)" = {q} ] && wl-copy --clear'],
                         start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


BULK = re.compile(r'(no-?reply|do-?not-?reply|notifications?|mailer|news(letter)?|info|support|hello|team|updates?|alerts?|billing|marketing|digest|bounce)@', re.I)


def category(r, mine):
    """people / updates / news — instant, from the headers (no AI)."""
    addr = (r.get('from_addr') or '').lower()
    if r.get('code'):
        return 'updates'
    if addr in mine:
        return 'people'
    if r.get('unsub'):
        return 'news'
    if BULK.search(addr):
        return 'updates'
    return 'people'


def unique_path(d, name):
    name = re.sub(r'[/\x00]', '_', name).strip() or 'attachment'
    base, ext = os.path.splitext(name)
    p = os.path.join(d, name)
    i = 2
    while os.path.exists(p):
        p = os.path.join(d, f'{base} ({i}){ext}')
        i += 1
    return p


def xdg_open(p):
    subprocess.Popen(['xdg-open', p], start_new_session=True, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Server:
    def __init__(self):
        self.hub = Hub()

    def run(self):
        h = self.hub
        with open(os.path.join(paths.STATE, 'app.pid'), 'w') as f:
            f.write(str(os.getpid()))
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                c = json.loads(line)
            except ValueError:
                continue
            if c.get('cmd') == 'quit':
                break
            try:
                self.handle(c)
            except Exception as e:
                h.emit({'type': 'error', 'error': str(e), 'trace': traceback.format_exc()})
        for a in list(h.accounts.values()):
            a.stop()
        try:
            os.unlink(os.path.join(paths.STATE, 'app.pid'))
        except OSError:
            pass

    def acc(self, aid):
        a = self.hub.accounts.get(aid)
        if a is None:
            raise KeyError(f'no account {aid}')
        return a

    def handle(self, c):
        h = self.hub
        cmd = c['cmd']
        if cmd == 'hello':
            h.colors = c.get('colors') or {}
            h.emit({'type': 'hello', 'settings': h.settings, 'downloads': paths.DOWNLOADS,
                    'drafts': load_drafts()})
            h.start_accounts()
            h.send_accounts()
            h.write_unread()
        elif cmd == 'theme':
            h.colors = c.get('colors') or {}
        elif cmd == 'list':
            h.send_list(c['view'], c.get('limit', 300), c.get('rid', 0))
            if c.get('watch', True):
                h.watch(c['view'])
        elif cmd == 'older':
            v = c['view']
            if v.get('acc') and v['acc'] != '*':
                self.acc(v['acc']).fg('older', path=v['folder'])
        elif cmd == 'refresh':
            for a in h.accounts.values():
                a.auth_failed = False if c.get('retry') else a.auth_failed
                a.bg('refresh')
        elif cmd == 'open':
            self.acc(c['acc']).fg('open', path=c['folder'], uid=int(c['uid']), rid=c.get('rid', 0),
                                  mark=h.settings.get('markRead', True))
        elif cmd == 'act':
            groups = {}
            for it in c['items']:
                groups.setdefault((it['acc'], it['folder']), []).append(it)
            for (aid, folder), its in groups.items():
                self.acc(aid).fg('act', op=c['op'], path=folder, uids=[int(i['uid']) for i in its], rid=c.get('rid', 0),
                                 dest=c.get('dest'), msgids=[i.get('msgid', '') for i in its])
        elif cmd == 'undo':
            self.acc(c['acc']).fg('undo', src=c['src'], dest=c['dest'], msgids=c['msgids'], rid=c.get('rid', 0))
        elif cmd == 'search':
            q = c['q'].strip()
            local = h.store.search_local(h.acc_ids(), q)
            h.emit({'type': 'search', 'rid': c['rid'], 'local': True, 'items': local})
            if q and c.get('server', True):
                for a in h.accounts.values():
                    a.fg('search', q=q, rid=c['rid'])
        elif cmd == 'contacts':
            h.emit({'type': 'contacts', 'rid': c.get('rid', 0), 'items': h.store.contacts(c.get('q', ''))})
        elif cmd == 'send':
            self.acc(c['acc']).fg('send', draft=c['draft'], attachments=c.get('attachments', []),
                                  rid=c.get('rid', 0), forward=c.get('forward'))
            drop_draft(c.get('draftId'))
        elif cmd == 'draft-save':
            save_draft(c['id'], c['data'])
        elif cmd == 'draft-drop':
            drop_draft(c['id'])
        elif cmd == 'pick':
            threading.Thread(target=self.pick, args=(c.get('rid', 0),), daemon=True).start()
        elif cmd in ('att-open', 'att-save'):
            a = self.acc(c['acc'])
            a.fg('fetchraw', path=c['folder'], uid=int(c['uid']),
                 then=lambda raw, c=c: self.attachment(raw, c))
        elif cmd == 'web':
            # the web view's renderer (glass-mail-web) is driven by the Rust backend only
            h.emit({'type': 'web', 'rid': c.get('rid'), 'ok': False, 'error': 'unavailable'})
        elif cmd == 'browser':
            a = self.acc(c['acc'])
            a.fg('fetchraw', path=c['folder'], uid=int(c['uid']),
                 then=lambda raw, c=c: self.browser(raw, c))
        elif cmd == 'source':
            a = self.acc(c['acc'])
            a.fg('fetchraw', path=c['folder'], uid=int(c['uid']),
                 then=lambda raw, c=c: self.source(raw, c))
        elif cmd == 'images':
            addr = (c.get('addr') or '').lower()
            if c.get('always') and addr:
                lst = h.settings.setdefault('imagesFrom', [])
                if addr not in lst:
                    lst.append(addr)
                h.save_settings()
        elif cmd == 'settings':
            h.settings.update(c.get('set', {}))
            h.save_settings()
        elif cmd == 'account-guess':
            h.emit({'type': 'account-guess', 'rid': c.get('rid', 0), **accmod.guess(c.get('email', ''))})
        elif cmd == 'account-save':
            h.account_save(c['account'], c.get('rid', 0))
        elif cmd == 'account-update':
            h.account_update(c['id'], c.get('fields', {}))
        elif cmd == 'account-remove':
            h.account_remove(c['id'])
        elif cmd.startswith('ai-') or cmd in ('copy', 'calendar'):
            self.handle_ai(c)
        elif cmd == 'url':
            if re.match(r'^https?://', c.get('url', '')):
                xdg_open(c['url'])
        elif cmd == 'spawn' and c.get('what') == 'mail-dir':
            xdg_open(paths.DOWNLOADS)

    # ---------------------------------------------------------------- AI, codes, calendar
    def mail_payload(self, a, folder, uid, raw):
        h = self.hub
        v = mime.parse(raw)
        frm = mime.addresses(v.get('From'))
        text = mime.text_of(raw)
        row = h.store.message(a.id, folder, uid)
        thread = []
        if row:
            for m in h.store.thread(a.id, row['thrid'], row['msgid'], ''):
                if m['msgid'] == row['msgid']:
                    continue
                other = a.body(h.store, m['folder'], m['uid'])
                thread.append(f'{m["from_name"] or m["from_addr"]}: ' + (mime.text_of(other) if other else m['snippet']))
        return {'subject': mime.dec(v.get('Subject')), 'from': mime.fmt_addr(*frm[0]) if frm else '',
                'date': mime.parse_date(v.get('Date')), 'text': text, 'thread': thread[-3:],
                'me': a.conf.get('name') or a.conf['email']}

    def with_raw(self, c, fn):
        """fn(account, raw) once the message body is cached (on the account's fg thread)."""
        a = self.acc(c['acc'])

        def then(raw):
            if raw is None:
                self.hub.emit({'type': 'ai-error', 'rid': c.get('rid'), 'text': 'Couldn’t get that message from the server.'})
            else:
                fn(a, raw)
        a.fg('fetchraw', path=c['folder'], uid=int(c['uid']), then=then)

    def handle_ai(self, c):
        h = self.hub
        cmd, rid = c['cmd'], c.get('rid', 0)
        if cmd == 'copy':
            copy(c.get('text', ''), clear_after=c.get('clear', 0))
            return
        if cmd == 'calendar':
            threading.Thread(target=self.calendar_add, args=(c.get('title', ''), c.get('when', '')), daemon=True).start()
            return
        if cmd == 'ai-cancel':
            h.ai.cancel(rid)
            return
        if not h.settings.get('aiOn', True):
            h.emit({'type': 'ai-error', 'rid': rid, 'text': 'AI is off (Settings → AI).'})
            return
        ai = h.ai
        if cmd == 'ai-warm':
            ai.warm()
        elif cmd == 'ai-analyze':
            key = f'an:{c["acc"]}:{c["folder"]}:{c["uid"]}'
            got = h.store.ai_get(key)
            if got and not c.get('force'):
                h.emit({'type': 'ai-analysis', 'rid': rid, 'result': got, 'cached': True})
                return
            self.with_raw(c, lambda a, raw: ai.submit(rid, ai.analyze, self.mail_payload(a, c['folder'], int(c['uid']), raw),
                                                      lambda res: h.store.ai_put(key, res), background=bool(c.get('auto'))))
        elif cmd == 'ai-reply':
            self.with_raw(c, lambda a, raw: ai.submit(rid, ai.reply, self.mail_payload(a, c['folder'], int(c['uid']), raw),
                                                      c.get('intent', ''), a.conf.get('name') or ''))
        elif cmd == 'ai-translate':
            self.with_raw(c, lambda a, raw: ai.submit(rid, ai.translate, mime.text_of(raw), c.get('target') or h.settings.get('translateTo', 'ru')))
        elif cmd == 'ai-write':
            a = h.accounts.get(c.get('acc'))
            ai.submit(rid, ai.write, c.get('prompt', ''), c.get('ctx') or {}, (a.conf.get('name') if a else '') or '')
        elif cmd == 'ai-rewrite':
            ai.submit(rid, ai.rewrite, c.get('text', ''), c.get('mode', 'improve'))
        elif cmd == 'ai-ask':
            rows = self.ask_sources(c.get('q', ''))
            h.emit({'type': 'ai-sources', 'rid': rid, 'items': rows})
            ai.submit(rid, ai.ask, c.get('q', ''), self.docs(rows))
        elif cmd == 'ai-brief':
            rows = h.store.unread_inbox(h.acc_ids(), 20)
            h.emit({'type': 'ai-sources', 'rid': rid, 'items': rows})
            if not rows:
                h.emit({'type': 'ai-done', 'rid': rid, 'text': 'No unread mail in your inboxes. Nice.'})
                return
            lang = aimod.lang_of(' '.join(r['subject'] + ' ' + r['snippet'] for r in rows))
            ai.submit(rid, ai.brief, self.docs(rows, full=False), lang)

    STOP = set('the and for that with from what when where which who how did does was were are is about this have has '
               'mail email emails письмо письма почта что где когда кто как это был была были про мне меня мой моя есть '
               'или для from was any all last'.split())

    def ask_sources(self, q):
        h = self.hub
        words = [w for w in re.findall(r'[\w@.-]{3,}', q.lower()) if w not in self.STOP]
        stems = {w[:-2] if len(w) > 5 and not re.search(r'[@.\d]', w) else w for w in words}   # договора → догово
        hits = {}
        for st in stems:
            for r in h.store.search_local(h.acc_ids(), st, 40):
                k = (r['acc'], r['folder'], r['uid'])
                e = hits.setdefault(k, [0, r])
                e[0] += 1
        ranked = sorted(hits.values(), key=lambda e: (-e[0], -e[1]['date']))
        rows = [e[1] for e in ranked[:10]]
        if not rows:
            rows = h.store.list_role(h.acc_ids(), 'inbox', 10)
        return rows

    def docs(self, rows, full=True):
        h = self.hub
        out = []
        for i, r in enumerate(rows, 1):
            text = r['snippet']
            a = h.accounts.get(r['acc'])
            if full and a:
                raw = a.body(h.store, r['folder'], r['uid'])
                if raw:
                    text = mime.text_of(raw)
            out.append({'n': i, 'from': r['from_name'] or r['from_addr'], 'subject': r['subject'], 'text': text or '',
                        'date': time.strftime('%d %b %Y %H:%M', time.localtime(r['date']))})
        return out

    def calendar_add(self, title, when):
        h = self.hub
        exe = shutil.which('gcal-sync') or os.path.expanduser('~/.local/bin/gcal-sync')
        if not os.path.exists(exe):
            h.toast('warn', 'gcal-sync isn’t installed')
            return
        try:
            p = subprocess.run([exe, 'parse', '--engine', 'rules', f'{title} {when}'], capture_output=True, text=True, timeout=30)
            ev = json.loads(p.stdout)
            if not ev.get('date'):
                h.toast('warn', f'Couldn’t read a date from “{when}”')
                return
            ev['title'] = title
            p = subprocess.run([exe, 'add', '--json', json.dumps(ev, ensure_ascii=False)], capture_output=True, text=True, timeout=60)
            if p.returncode != 0:
                raise RuntimeError((p.stderr or p.stdout).strip()[-200:])
        except Exception as e:
            h.toast('warn', f'Calendar: {e}')
            return
        h.toast('calendar', f'Added “{title}” · {ev["date"]}{" " + ev["time"] if ev.get("time") else ""}')

    # ---------------------------------------------------------------- helpers run on account threads
    def attachment(self, raw, c):
        h = self.hub
        if raw is None:
            h.toast('warn', 'Couldn’t get that message from the server')
            return
        name, data = mime.attachment_bytes(mime.parse(raw), int(c['i']))
        if name is None:
            h.toast('warn', 'Attachment not found')
            return
        if c['cmd'] == 'att-save':
            os.makedirs(paths.DOWNLOADS, exist_ok=True)
            p = unique_path(paths.DOWNLOADS, name)
            with open(p, 'wb') as f:
                f.write(data)
            h.emit({'type': 'saved', 'path': p, 'name': os.path.basename(p)})
            h.toast('download', 'Saved to ~/' + os.path.relpath(p, paths.HOME) if p.startswith(paths.HOME) else p)
        else:
            d = os.path.join(paths.OPENED, hashlib.sha1(f"{c['acc']}{c['folder']}{c['uid']}".encode()).hexdigest()[:12])
            os.makedirs(d, exist_ok=True)
            p = os.path.join(d, re.sub(r'[/\x00]', '_', name))
            with open(p, 'wb') as f:
                f.write(data)
            xdg_open(p)

    def browser(self, raw, c):
        if raw is None:
            self.hub.toast('warn', 'Couldn’t get that message from the server')
            return
        page = mime.original_html(raw, allow_remote=bool(c.get('images')))
        p = os.path.join(paths.OPENED, f"msg-{hashlib.sha1(raw).hexdigest()[:12]}.html")
        with open(p, 'w') as f:
            f.write(page)
        xdg_open(p)

    def source(self, raw, c):
        if raw is None:
            return
        p = os.path.join(paths.OPENED, f"source-{hashlib.sha1(raw).hexdigest()[:12]}.txt")
        with open(p, 'wb') as f:
            f.write(raw)
        xdg_open(p)

    def pick(self, rid):
        try:
            r = subprocess.run(['zenity', '--file-selection', '--multiple', '--separator=\n', '--title=Attach files'],
                               capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired):
            self.hub.emit({'type': 'picked', 'rid': rid, 'files': []})
            return
        files = [f for f in r.stdout.split('\n') if f.strip() and os.path.isfile(f)]
        self.hub.emit({'type': 'picked', 'rid': rid,
                       'files': [{'path': f, 'name': os.path.basename(f), 'size': os.path.getsize(f)} for f in files]})


# ---------------------------------------------------------------- local drafts (the open compose, autosaved)
def load_drafts():
    out = []
    try:
        for n in sorted(os.listdir(paths.DRAFTS)):
            if n.endswith('.json'):
                with open(os.path.join(paths.DRAFTS, n)) as f:
                    d = json.load(f)
                d['id'] = n[:-5]
                out.append(d)
    except (OSError, ValueError):
        pass
    return out


def save_draft(did, data):
    if not re.match(r'^[\w-]+$', str(did)):
        return
    p = os.path.join(paths.DRAFTS, f'{did}.json')
    tmp = p + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, p)


def drop_draft(did):
    if did and re.match(r'^[\w-]+$', str(did)):
        try:
            os.unlink(os.path.join(paths.DRAFTS, f'{did}.json'))
        except OSError:
            pass


def main():
    import faulthandler
    import signal
    faulthandler.register(signal.SIGUSR1, all_threads=True)    # kill -USR1 <pid>: dump stacks to stderr
    Server().run()


if __name__ == '__main__':
    main()
