"""Differential test: the Python and the Rust backend run the same scripted session against the same
freshly seeded Dovecot (Docker), a fake SMTP server and a fake local-AI server. Everything they emit,
send, store and leave behind is normalized and compared. Never touches real accounts or ~/.config.

    python -m tests.parity.live_diff [--only python|rust] [--keep]
"""
import email
import email.utils
import hashlib
import http.server
import imaplib
import json
import os
import queue
import random
import re
import shutil
import socketserver
import sqlite3
import subprocess
import sys
import threading
import time

from tests import seed
from tests.fakesmtp import FakeSMTP
from tests.test_live import NAME, PORT, USER, PASS, imap

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUST = os.path.join(ROOT, 'backend/target/release/glass-mail-backend')
SMTP_PORT, AI_PORT = 31925, 31926
NOW = time.time()
SEED_AT = int(NOW - 10 * 86400)          # the seeded mailbox lives in the past, "now" is normalized
OUT = os.environ.get('GLASS_MAIL_DIFF_OUT', os.path.join(ROOT, 'tests/parity/out'))
TMP = os.path.join(OUT, 'home')


# ---------------------------------------------------------------- fake local AI (OpenAI-compatible)
class AI(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


AI_REQS = []
ANALYSIS = {'summary': 'Лена просит подписать договор.', 'actions': ['Подписать договор'],
            'events': [{'title': 'Встреча', 'when': 'вторник 15:00'}], 'replies': ['Ок', 'Спасибо!', 'Позже'], 'needsReply': True}
CHUNKS = ['<think>hmm</think>', 'Answer ', 'with [1] ', 'ünicode ✓', '\n\nDone.']


class AIHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = json.dumps({'data': [{'id': 'fake-model'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        req = json.loads(raw)
        AI_REQS.append(req)
        if not req.get('stream'):
            content = json.dumps(ANALYSIS, ensure_ascii=False) if req.get('response_format') else 'plain'
            body = json.dumps({'choices': [{'message': {'content': content}}]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for c in CHUNKS:
            self.wfile.write(b'data: ' + json.dumps({'choices': [{'delta': {'content': c}}]}).encode() + b'\n\n')
            self.wfile.flush()
            time.sleep(0.01)
        self.wfile.write(b': keepalive\n\ndata: not json\n\ndata: [DONE]\n\n')


# ---------------------------------------------------------------- normalization
MSGID = re.compile(r'<\d+\.\d+\.\d+@[^>\s]+>')
BOUND = re.compile(r'boundary="?([^";\s]+)"?')


def norm(o, key=None):
    if isinstance(o, dict):
        # a Python traceback has no Rust counterpart
        return {k: norm(v, k) for k, v in o.items() if not (k == 'trace' and o.get('type') == 'error')}
    if isinstance(o, list):
        return [norm(v) for v in o]
    if isinstance(o, str):
        return MSGID.sub('<MSGID>', o.replace(TMP, '$TMP'))
    if isinstance(o, (int, float)) and not isinstance(o, bool):
        if key in ('uidvalidity', 'highestmodseq', 'modseq'):
            return '*'
        if abs(o - time.time()) < 86400:
            return 'NOW'
    return o


def norm_mail(data):
    """A sent / stored message without what is random or time-dependent."""
    t = data.decode('utf-8', 'surrogateescape')
    for i, b in enumerate(dict.fromkeys(BOUND.findall(t))):
        t = t.replace(b, f'BOUNDARY{i}')
    t = MSGID.sub('<MSGID>', t)
    t = re.sub(r'(?m)^Date: .*$', 'Date: NOW', t)
    return t


# ---------------------------------------------------------------- one run
class Run:
    def __init__(self, name, cmd):
        self.name = name
        self.cmd = cmd
        self.steps = []           # (label, [normalized messages])
        self.err = []

    def start(self):
        subprocess.run(['docker', 'rm', '-f', NAME], capture_output=True)
        subprocess.run(['docker', 'run', '-d', '--name', NAME, '-e', f'USER_PASSWORD={PASS}',
                        '-p', f'127.0.0.1:{PORT}:31993', 'dovecot/dovecot:latest'], check=True, capture_output=True)
        for _ in range(100):
            try:
                imap().logout()
                break
            except Exception:
                time.sleep(0.2)
        # a byte-identical mailbox for both runs: fixed clock, Message-IDs and MIME boundaries
        n = iter(range(10 ** 6))
        email.utils.make_msgid = lambda idstring=None, domain=None: f'<seed{next(n)}@{domain or "x"}>'
        seed.time = type('T', (), {'time': staticmethod(lambda: SEED_AT)})
        random.seed(7)
        seed.seed('127.0.0.1', PORT, USER, PASS, many=220)
        shutil.rmtree(TMP, ignore_errors=True)
        os.makedirs(TMP + '/config')
        with open(TMP + '/config/settings.json', 'w') as f:
            json.dump({'pollMinutes': 60}, f)      # no timed refresh in the middle of a step
        self.notes = TMP + '/notify.log'
        open(self.notes, 'w').close()
        self.smtp = FakeSMTP(SMTP_PORT)
        AI_REQS.clear()
        env = dict(os.environ, PYTHONPATH=ROOT, GLASS_MAIL_INSECURE='1', GLASS_MAIL_NOTIFY_LOG=self.notes,
                   GLASS_MAIL_CONFIG=TMP + '/config', GLASS_MAIL_CACHE=TMP + '/cache', GLASS_MAIL_STATE=TMP + '/state',
                   GLASS_MAIL_DOWNLOADS=TMP + '/downloads', GLASS_MAIL_AI_URL=f'http://127.0.0.1:{AI_PORT}/v1',
                   TZ='Asia/Tokyo', LANG='C.UTF-8', LC_ALL='C.UTF-8')
        self.t0 = time.time()
        self.p = subprocess.Popen(self.cmd, cwd=ROOT, env=env, text=True, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.q = queue.Queue()
        threading.Thread(target=lambda: [self.q.put(json.loads(ln)) for ln in self.p.stdout], daemon=True).start()
        threading.Thread(target=lambda: [self.err.append(ln) for ln in self.p.stderr], daemon=True).start()
        self.seen_smtp = self.seen_ai = self.seen_notes = 0

    def send(self, o):
        self.p.stdin.write(json.dumps(o, ensure_ascii=False) + '\n')
        self.p.stdin.flush()

    def collect(self, label, until=None, quiet=1.0, t=60):
        """Messages until `until` matched (if given) and then `quiet` seconds of silence."""
        out = []
        end = time.time() + t
        done = until is None
        last = time.time()
        while time.time() < end:
            try:
                m = self.q.get(timeout=0.05)
                out.append(m)
                last = time.time()
                if not done and until(m):
                    done = True
            except queue.Empty:
                if done and time.time() - last >= quiet:
                    break
        else:
            out.append({'type': '_TIMEOUT'})
        # what left the process besides stdout, in this step
        for s in self.smtp.messages[self.seen_smtp:]:
            out.append({'type': '_smtp', 'from': s['from'], 'rcpt': s['rcpt'], 'data': norm_mail(s['data'])})
        self.seen_smtp = len(self.smtp.messages)
        for r in AI_REQS[self.seen_ai:]:
            out.append({'type': '_ai', 'req': r})
        self.seen_ai = len(AI_REQS)
        with open(self.notes) as f:
            lines = f.readlines()
        for ln in lines[self.seen_notes:]:
            out.append({'type': '_notify', **json.loads(ln)})
        self.seen_notes = len(lines)
        self.steps.append((label, [norm(m) for m in out]))
        return out

    def step(self, label, cmd, until=None, **kw):
        self.send(cmd)
        return self.collect(label, until, **kw)

    def items(self, view, rid, limit=300):
        msgs = self.step(f'list {view} rid={rid}', {'cmd': 'list', 'view': view, 'rid': rid, 'limit': limit, 'watch': False},
                         lambda m: m['type'] == 'list' and m['rid'] == rid, quiet=0.3)
        return next(m for m in msgs if m['type'] == 'list' and m['rid'] == rid)['items']

    # ---------------------------------------------------------------- the session
    def script(self):
        acc = None
        S = self.step
        S('hello', {'cmd': 'hello', 'colors': {'accent': '#80d4db'}}, lambda m: m['type'] == 'hello')
        saved = S('account-save', {'cmd': 'account-save', 'rid': 1, 'account': {
            'email': USER, 'name': 'Me Test', 'password': PASS, 'imapHost': '127.0.0.1', 'imapPort': PORT,
            'smtpHost': '127.0.0.1', 'smtpPort': SMTP_PORT, 'smtpSecurity': 'plain'}},
          lambda m: m['type'] == 'account-saved', quiet=4, t=120)
        acc = next(m for m in saved if m['type'] == 'account-saved')['id']
        inbox = lambda: self.items({'acc': acc, 'folder': 'INBOX'}, 9)  # noqa: E731
        find = lambda subj: next((r for r in inbox() if r['subject'] == subj), None)  # noqa: E731
        it = lambda r, folder='INBOX': [{'acc': acc, 'folder': folder, 'uid': r['uid'], 'msgid': r['msgid']}]  # noqa: E731

        items = inbox()
        self.items({'kind': 'starred'}, 2)
        self.items({'acc': '*', 'role': 'inbox'}, 3)
        for f in ('Sent', 'Junk', 'Trash', 'Nope'):
            self.items({'acc': acc, 'folder': f}, 4)
        S('list+watch', {'cmd': 'list', 'view': {'acc': acc, 'folder': 'Junk'}, 'rid': 5}, lambda m: m['type'] == 'changed', quiet=1.5)

        # every cached message through the reader (this also marks them read, on the server too)
        for i, r in enumerate(items):
            S(f'open {r["subject"]}', {'cmd': 'open', 'acc': acc, 'folder': 'INBOX', 'uid': r['uid'], 'rid': 100 + i},
              lambda m, i=i: m['type'] == 'msg' and m['rid'] == 100 + i, quiet=0.25)
        fig = find('This week in design: glass, blur and depth')
        S('images always', {'cmd': 'images', 'addr': 'News@Figma.example', 'always': True}, quiet=0.3)
        S('open with images', {'cmd': 'open', 'acc': acc, 'folder': 'INBOX', 'uid': fig['uid'], 'rid': 99},
          lambda m: m['type'] == 'msg' and m['rid'] == 99, quiet=0.5)
        S('open missing uid', {'cmd': 'open', 'acc': acc, 'folder': 'INBOX', 'uid': 999999, 'rid': 98},
          lambda m: m.get('rid') == 98, quiet=0.5)

        # actions
        r = find('Photos from Saturday')
        for op in ('flag', 'unseen', 'seen', 'unflag', 'flag', 'unseen'):
            S(f'act {op}', {'cmd': 'act', 'op': op, 'rid': 10, 'items': it(r)}, lambda m, op=op: m['type'] == 'acted' and m['op'] == op, quiet=0.5)
        self.items({'kind': 'starred'}, 11)
        ci = find('[glass] CI passed on main')
        S('archive', {'cmd': 'act', 'op': 'archive', 'rid': 12, 'items': it(ci)}, lambda m: m['type'] == 'acted', quiet=0.8)
        S('undo', {'cmd': 'undo', 'acc': acc, 'src': 'INBOX', 'dest': 'Archive', 'msgids': [ci['msgid']], 'rid': 13},
          lambda m: m['type'] == 'undone', quiet=0.8)
        S('bad op', {'cmd': 'act', 'op': 'junk', 'rid': 14, 'items': it(find('Old message #3'))}, lambda m: m['type'] == 'op-failed', quiet=0.5)
        S('spam', {'cmd': 'act', 'op': 'spam', 'rid': 14, 'items': it(find('Old message #3'))}, lambda m: m['type'] == 'acted', quiet=0.8)
        S('move', {'cmd': 'act', 'op': 'move', 'dest': 'Archive', 'rid': 15, 'items': it(find('Old message #4')) + it(find('Old message #5'))},
          lambda m: m['type'] == 'acted', quiet=0.8)
        S('trash', {'cmd': 'act', 'op': 'trash', 'rid': 16, 'items': it(r)}, lambda m: m['type'] == 'acted', quiet=0.8)
        S('watch trash', {'cmd': 'list', 'view': {'acc': acc, 'folder': 'Trash'}, 'rid': 17},
          lambda m: m['type'] == 'changed' and m['folder'] == 'Trash', quiet=0.8)
        tr = self.items({'acc': acc, 'folder': 'Trash'}, 17)
        S('trash forever', {'cmd': 'act', 'op': 'trash', 'rid': 18, 'items': [{'acc': acc, 'folder': 'Trash', 'uid': tr[0]['uid']}]},
          lambda m: m['type'] == 'acted', quiet=0.8)
        S('delete', {'cmd': 'act', 'op': 'delete', 'rid': 19, 'items': it(find('Old message #6'))}, lambda m: m['type'] == 'acted', quiet=0.8)
        S('unknown acc', {'cmd': 'act', 'op': 'flag', 'rid': 20, 'items': [{'acc': 'nope', 'folder': 'INBOX', 'uid': 1}]}, quiet=0.5)

        # search, contacts, older
        for i, q in enumerate(['договор', 'message 3.', 'Mika', 'nothing-like-this', '  ', 'ДОКУМЕНТЫ', 'sora@example.net']):
            S(f'search {q!r}', {'cmd': 'search', 'q': q, 'rid': 21 + i}, quiet=1.0)
        S('search local only', {'cmd': 'search', 'q': 'plan', 'rid': 29, 'server': False}, quiet=0.5)
        for q in ('mi', 'EXAMPLE', '', 'ива'):
            S(f'contacts {q!r}', {'cmd': 'contacts', 'q': q, 'rid': 30}, lambda m: m['type'] == 'contacts', quiet=0.2)
        for k in range(3):
            S(f'older {k}', {'cmd': 'older', 'view': {'acc': acc, 'folder': 'INBOX'}}, lambda m: m['type'] == 'changed' and m.get('older'), quiet=0.8)
        self.items({'acc': acc, 'folder': 'INBOX'}, 31, limit=1000)

        # sending
        plan = find('Trip plan for the weekend')
        att = TMP + '/notes.txt'
        with open(att, 'w') as f:
            f.write('packing list\n')
        S('send reply', {'cmd': 'send', 'acc': acc, 'rid': 40, 'attachments': [att], 'draftId': 'd1', 'draft': {
            'to': 'Mika Aalto <mika@example.org>', 'cc': '', 'bcc': 'hidden@example.org', 'subject': 'Re: Trip plan for the weekend',
            'body': 'Great!\n\n> Hi!\n> > nested', 'inReplyTo': plan['msgid'], 'refs': '', 'replyTo': {'folder': 'INBOX', 'uid': plan['uid']}}},
          lambda m: m['type'] == 'sent', quiet=1.0)
        doc = find('Документы на подпись')
        S('send forward', {'cmd': 'send', 'acc': acc, 'rid': 41, 'attachments': [], 'forward': {'folder': 'INBOX', 'uid': doc['uid'], 'keep': [0, 1]},
                           'draft': {'to': 'boss@example.org', 'subject': 'Fwd: Документы на подпись', 'body': 'FYI'}},
          lambda m: m['type'] == 'sent', quiet=1.0)
        S('send new', {'cmd': 'send', 'acc': acc, 'rid': 42, 'attachments': [], 'draft': {
            'to': '"Иван Смирнов" <ivan@example.ru>, sora@example.net', 'cc': 'Lena <lena@example.com>', 'subject': 'Привет — встреча 🍣',
            'body': 'Long line ' * 40 + '\n.\n..dots\nПока!'}}, lambda m: m['type'] == 'sent', quiet=1.0)
        S('send bad rcpt', {'cmd': 'send', 'acc': acc, 'rid': 43, 'attachments': [], 'draft': {'to': '', 'subject': 'x', 'body': 'y'}},
          lambda m: m['type'] in ('sent', 'op-failed'), quiet=1.0)
        self.items({'acc': acc, 'folder': 'Sent'}, 44)

        # drafts, attachments, settings, accounts
        S('draft-save', {'cmd': 'draft-save', 'id': 'k-1', 'data': {'to': 'a@b.c', 'body': 'Черновик'}}, quiet=0.2)
        S('draft-save bad id', {'cmd': 'draft-save', 'id': '../evil', 'data': {}}, quiet=0.2)
        S('hello again', {'cmd': 'hello'}, lambda m: m['type'] == 'hello', quiet=1.5)
        S('draft-drop', {'cmd': 'draft-drop', 'id': 'k-1'}, quiet=0.2)
        for i in (0, 1, 7):
            S(f'att-save {i}', {'cmd': 'att-save', 'acc': acc, 'folder': 'INBOX', 'uid': doc['uid'], 'i': i}, quiet=0.8)
        S('att-save again', {'cmd': 'att-save', 'acc': acc, 'folder': 'INBOX', 'uid': doc['uid'], 'i': 0}, quiet=0.8)
        S('settings', {'cmd': 'settings', 'set': {'markRead': False, 'translateTo': 'en'}}, lambda m: m['type'] == 'settings', quiet=0.3)
        S('account-update', {'cmd': 'account-update', 'id': acc, 'fields': {'name': 'Me Renamed', 'signature': '-- \nMe', 'bogus': 1}},
          lambda m: m['type'] == 'accounts', quiet=0.5)
        for i, e in enumerate(('x@gmail.com', 'y@yandex.ru', 'z@mail.ru', 'w@example.org', 'broken')):
            S(f'guess {e}', {'cmd': 'account-guess', 'email': e, 'rid': 50 + i}, lambda m: m['type'] == 'account-guess', quiet=0.2)
        S('copy', {'cmd': 'copy', 'text': '123456', 'clear': 0}, quiet=0.3)

        # AI (fake model: the prompts are what we compare)
        S('ai-analyze', {'cmd': 'ai-analyze', 'acc': acc, 'folder': 'INBOX', 'uid': doc['uid'], 'rid': 60},
          lambda m: m['type'] in ('ai-analysis', 'ai-error'), quiet=0.5)
        S('ai-analyze cached', {'cmd': 'ai-analyze', 'acc': acc, 'folder': 'INBOX', 'uid': doc['uid'], 'rid': 61},
          lambda m: m['type'] in ('ai-analysis', 'ai-error'), quiet=0.5)
        S('ai-analyze thread', {'cmd': 'ai-analyze', 'acc': acc, 'folder': 'INBOX', 'uid': find('Re: Trip plan for the weekend')['uid'], 'rid': 62, 'force': True},
          lambda m: m['type'] in ('ai-analysis', 'ai-error'), quiet=0.5)
        S('ai-reply', {'cmd': 'ai-reply', 'acc': acc, 'folder': 'INBOX', 'uid': plan['uid'], 'rid': 63, 'intent': 'yes, but Sunday only'},
          lambda m: m['type'] in ('ai-done', 'ai-error'), quiet=0.5)
        S('ai-translate', {'cmd': 'ai-translate', 'acc': acc, 'folder': 'INBOX', 'uid': doc['uid'], 'rid': 64},
          lambda m: m['type'] in ('ai-done', 'ai-error'), quiet=0.5)
        S('ai-write', {'cmd': 'ai-write', 'acc': acc, 'rid': 65, 'prompt': 'ask Sora for the slides', 'ctx': {'to': 'sora@example.net', 'subject': 'Slides'}},
          lambda m: m['type'] in ('ai-done', 'ai-error'), quiet=0.5)
        for i, mode in enumerate(('improve', 'shorter', 'formal', 'friendly', 'fix', 'weird')):
            S(f'ai-rewrite {mode}', {'cmd': 'ai-rewrite', 'rid': 66 + i, 'text': 'hey can u send it tmrw', 'mode': mode},
              lambda m: m['type'] in ('ai-done', 'ai-error'), quiet=0.5)
        S('ai-ask', {'cmd': 'ai-ask', 'q': 'Что Лена прислала на подпись?', 'rid': 80}, lambda m: m['type'] in ('ai-done', 'ai-error'), quiet=0.5)
        S('ai-ask nothing', {'cmd': 'ai-ask', 'q': 'zzzz qqqq', 'rid': 81}, lambda m: m['type'] in ('ai-done', 'ai-error'), quiet=0.5)
        S('ai-brief', {'cmd': 'ai-brief', 'rid': 82}, lambda m: m['type'] in ('ai-done', 'ai-error'), quiet=0.5)
        S('ai-cancel', {'cmd': 'ai-cancel', 'rid': 83}, quiet=0.3)
        S('ai off', {'cmd': 'settings', 'set': {'aiOn': False}}, lambda m: m['type'] == 'settings', quiet=0.3)
        S('ai-rewrite off', {'cmd': 'ai-rewrite', 'rid': 84, 'text': 'x'}, lambda m: m['type'] == 'ai-error', quiet=0.3)

        # new mail pushed through IDLE, and a login code
        c = imap()
        m = seed.msg(('Nadia K', 'nadia@example.org'), USER, 'Fresh one', 'Just arrived!', msgid='<fresh@example.test>', when=time.time())
        c.append('INBOX', None, imaplib.Time2Internaldate(time.time()), m.as_bytes())
        c.logout()
        self.collect('idle new mail', lambda m: m['type'] == 'changed' and m['folder'] == 'INBOX', quiet=2.0, t=30)
        c = imap()
        m = seed.msg(('Telegram', 'noreply@telegram.example'), USER, 'Sign in to Telegram',
                     'Your login code: 62519. Do not give this code to anyone.', msgid='<tg@example.test>', when=time.time())
        c.append('INBOX', None, imaplib.Time2Internaldate(time.time()), m.as_bytes())
        c.logout()
        self.collect('idle code', lambda m: m['type'] == 'code', quiet=2.5, t=30)
        S('refresh', {'cmd': 'refresh'}, quiet=2.0)
        inbox()

        # accounts
        S('wrong password', {'cmd': 'account-save', 'rid': 90, 'account': {
            'email': 'other@test.local', 'password': 'nope', 'imapHost': '127.0.0.1', 'imapPort': PORT,
            'smtpHost': '127.0.0.1', 'smtpPort': SMTP_PORT, 'smtpSecurity': 'plain'}}, lambda m: m['type'] == 'account-saved', quiet=0.5)
        S('no server', {'cmd': 'account-save', 'rid': 91, 'account': {
            'email': 'x@test.local', 'password': 'p', 'imapHost': '127.0.0.1', 'imapPort': 1, 'smtpHost': '127.0.0.1', 'smtpPort': 1}},
          lambda m: m['type'] == 'account-saved', quiet=0.5)
        S('garbage', {'cmd': 'nope'}, quiet=0.3)
        self.send({'not': 'json'})
        self.p.stdin.write('this is not json\n')
        self.collect('garbage input', quiet=0.3)
        S('account-remove', {'cmd': 'account-remove', 'id': acc}, lambda m: m['type'] == 'toast', quiet=1.0)
        from tests.parity.watch_diff import proc_stats
        self.stats = proc_stats(self.p.pid)
        self.send({'cmd': 'quit'})
        try:
            self.p.wait(15)
            self.exit = self.p.returncode
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.exit = 'hung'
        self.elapsed = time.time() - self.t0

    # ---------------------------------------------------------------- what is left behind
    def leftovers(self):
        out = {'exit': self.exit}
        c = imap()
        boxes = sorted(ln.decode().rsplit(' ', 1)[-1].strip('"') for ln in c.list()[1])
        for b in boxes:
            c.select(f'"{b}"')
            typ, data = c.uid('FETCH', '1:*', '(FLAGS BODY.PEEK[])')
            msgs = []
            for d in data:
                if isinstance(d, tuple):
                    flags = sorted(set(re.search(rb'FLAGS \(([^)]*)\)', d[0]).group(1).decode().split()) - {'\\Recent'})
                    msgs.append({'flags': flags, 'mail': norm_mail(d[1])})
            out[f'imap {b}'] = msgs
        c.logout()
        files = {}
        for base, _, names in os.walk(TMP):
            for n in names:
                p = os.path.join(base, n)
                rel = os.path.relpath(p, TMP)
                if rel.startswith('cache/mail.db') or rel == 'notify.log':
                    continue
                with open(p, 'rb') as f:
                    data = f.read()
                if rel.startswith('cache/bodies/'):
                    data = norm_mail(data).encode('utf-8', 'surrogateescape')
                if rel.endswith('.json'):
                    try:
                        data = json.dumps(norm(json.loads(data)), ensure_ascii=False, sort_keys=True).encode()
                    except ValueError:
                        pass
                files[rel] = data.decode('utf-8', 'replace') if len(data) < 4000 else hashlib.sha1(data).hexdigest()
        out['files'] = files
        db = sqlite3.connect(TMP + '/cache/mail.db')
        for (t,) in db.execute("select name from sqlite_master where type='table' order by name"):
            cols = [r[1] for r in db.execute(f'pragma table_info({t})')]
            rows = [norm(dict(zip(cols, r))) for r in db.execute(f'select * from {t}')]
            out[f'db {t}'] = sorted(json.dumps(r, ensure_ascii=False, sort_keys=True, default=str) for r in rows)
        return out

    def run(self):
        self.start()
        try:
            self.script()
            self.left = self.leftovers()
        finally:
            if self.p.poll() is None:
                self.p.kill()
            self.smtp.shutdown()
            self.smtp.server_close()


# background updates whose timing relative to a step is not deterministic: compared over the whole run
BACKGROUND = {'folders', 'unread', 'changed', 'acc-status', 'ai-state'}


def canon(msgs, bg=False):
    return sorted(json.dumps(m, ensure_ascii=False, sort_keys=True) for m in msgs if (m.get('type') in BACKGROUND) == bg)


def main():
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    os.makedirs(OUT, exist_ok=True)
    ai = AI(('127.0.0.1', AI_PORT), AIHandler)
    threading.Thread(target=ai.serve_forever, daemon=True).start()
    runs = {}
    for name, cmd in (('python', [sys.executable, '-m', 'glassmail.server']), ('rust', [RUST])):
        if only and name != only:
            continue
        r = Run(name, cmd)
        print(f'--- {name}', flush=True)
        r.run()
        runs[name] = r
        with open(f'{OUT}/{name}.json', 'w') as f:
            json.dump({'steps': r.steps, 'left': r.left, 'stderr': r.err}, f, ensure_ascii=False, indent=1)
        print(f'{name}: {len(r.steps)} steps, {sum(len(m) for _, m in r.steps)} messages, {r.elapsed:.1f}s, exit {r.exit}', flush=True)
    subprocess.run(['docker', 'rm', '-f', NAME], capture_output=True)
    if '--keep' not in sys.argv:
        shutil.rmtree(TMP, ignore_errors=True)
    if len(runs) < 2:
        return 0
    a, b = runs['python'], runs['rust']
    bad = 0
    for (la, ma), (lb, mb) in zip(a.steps, b.steps):
        assert la == lb, (la, lb)
        ca, cb = canon(ma), canon(mb)
        if ca != cb:
            bad += 1
            print(f'\n=== step {la!r}')
            for x in sorted(set(ca) - set(cb)):
                print('  py  ', x[:1500])
            for x in sorted(set(cb) - set(ca)):
                print('  rs  ', x[:1500])
            if set(ca) == set(cb):
                print('  (same messages, different counts)')
        elif [json.dumps(m, sort_keys=True) for m in ma] != [json.dumps(m, sort_keys=True) for m in mb]:
            print(f'  (order differs in step {la!r})')
    import collections
    ba = collections.Counter(x for _, m in a.steps for x in canon(m, True))
    bb = collections.Counter(x for _, m in b.steps for x in canon(m, True))
    if ba != bb:
        bad += 1
        print(f'\n=== background updates over the whole run ({sum(ba.values())} py, {sum(bb.values())} rs)')
        for x in sorted((ba - bb).elements()):
            print('  py  ', x[:700])
        for x in sorted((bb - ba).elements()):
            print('  rs  ', x[:700])
    for k in sorted(set(a.left) | set(b.left)):
        if a.left.get(k) != b.left.get(k):
            bad += 1
            print(f'\n=== left {k}')
            va, vb = a.left.get(k), b.left.get(k)
            if isinstance(va, dict) and isinstance(vb, dict):
                for f in sorted(set(va) | set(vb)):
                    if va.get(f) != vb.get(f):
                        print(f'  {f}:\n    py {str(va.get(f))[:600]!r}\n    rs {str(vb.get(f))[:600]!r}')
            elif isinstance(va, list) and isinstance(vb, list):
                for x in va:
                    if x not in vb:
                        print('  py  ', str(x)[:1200])
                for x in vb:
                    if x not in va:
                        print('  rs  ', str(x)[:1200])
            else:
                print(f'  py {str(va)[:800]}\n  rs {str(vb)[:800]}')
    print(f'\n{len(a.steps)} steps; {bad} differing; python {a.elapsed:.1f}s, rust {b.elapsed:.1f}s')
    print(f'python {a.stats}\nrust   {b.stats}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
