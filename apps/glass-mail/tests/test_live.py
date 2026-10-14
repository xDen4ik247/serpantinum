"""End-to-end tests of the backend against a real IMAP server (Dovecot in Docker) and a fake
SMTP server. Skipped when Docker isn't available. Never touches real accounts or ~/.config.

    python -m unittest tests.test_live -v
    GLASS_MAIL_SERVER_CMD=backend/target/release/glass-mail-backend python -m unittest tests.test_live -v
"""
import email
import imaplib
import json
import os
import queue
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from tests import seed
from tests.fakesmtp import FakeSMTP

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = 'glassmail-test-imap'
PORT = int(os.environ.get('GLASS_MAIL_TEST_PORT', '31993'))
USER, PASS = 'me@test.local', 'testpass'


def docker_ok():
    return shutil.which('docker') and subprocess.run(['docker', 'info'], capture_output=True).returncode == 0


def imap():
    c = imaplib.IMAP4_SSL('127.0.0.1', PORT, ssl_context=ssl._create_unverified_context())
    c.login(USER, PASS)
    return c


@unittest.skipUnless(docker_ok(), 'needs docker')
class Live(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['docker', 'rm', '-f', NAME], capture_output=True)
        subprocess.run(['docker', 'run', '-d', '--name', NAME, '-e', f'USER_PASSWORD={PASS}',
                        '-p', f'127.0.0.1:{PORT}:31993', 'dovecot/dovecot:latest'], check=True, capture_output=True)
        for _ in range(50):
            try:
                imap().logout()
                break
            except Exception:
                time.sleep(0.2)
        seed.seed('127.0.0.1', PORT, USER, PASS, many=220)
        cls.smtp = FakeSMTP()
        cls.tmp = tempfile.mkdtemp(prefix='glass-mail-test-')
        cls.notes = os.path.join(cls.tmp, 'notify.log')
        env = dict(os.environ, PYTHONPATH=ROOT, GLASS_MAIL_INSECURE='1', GLASS_MAIL_NOTIFY_LOG=cls.notes,
                   GLASS_MAIL_CONFIG=cls.tmp + '/config', GLASS_MAIL_CACHE=cls.tmp + '/cache',
                   GLASS_MAIL_STATE=cls.tmp + '/state', GLASS_MAIL_DOWNLOADS=cls.tmp + '/downloads')
        cls.env = env
        cmd = os.environ.get('GLASS_MAIL_SERVER_CMD')       # e.g. the Rust backend
        cmd = [os.path.abspath(cmd)] if cmd else [sys.executable, '-m', 'glassmail.server']
        cls.p = subprocess.Popen(cmd, cwd=ROOT, env=env, text=True,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        cls.q = queue.Queue()
        cls.err = []
        threading.Thread(target=lambda: [cls.q.put(json.loads(ln)) for ln in cls.p.stdout], daemon=True).start()
        threading.Thread(target=lambda: [cls.err.append(ln) for ln in cls.p.stderr], daemon=True).start()
        cls.send({'cmd': 'hello'})
        cls.wait(lambda m: m['type'] == 'hello')
        cls.send({'cmd': 'account-save', 'rid': 1, 'account': {
            'email': USER, 'name': 'Me Test', 'password': PASS, 'imapHost': '127.0.0.1', 'imapPort': PORT,
            'smtpHost': '127.0.0.1', 'smtpPort': cls.smtp.port, 'smtpSecurity': 'plain'}})
        m = cls.wait(lambda m: m['type'] == 'account-saved')
        assert m['ok'], m
        cls.acc = m['id']
        got = set()
        cls.wait(lambda m: (got.add('f') if m['type'] == 'folders' and m['items'] else None,
                            got.add('c') if m['type'] == 'changed' and m['folder'] == 'INBOX' else None,
                            got == {'f', 'c'})[-1], t=40)

    @classmethod
    def tearDownClass(cls):
        cls.send({'cmd': 'quit'})
        try:
            cls.p.wait(10)
        except subprocess.TimeoutExpired:
            cls.p.kill()
        cls.smtp.shutdown()
        subprocess.run(['docker', 'rm', '-f', NAME], capture_output=True)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def send(cls, o):
        cls.p.stdin.write(json.dumps(o) + '\n')
        cls.p.stdin.flush()

    @classmethod
    def wait(cls, pred, t=25):
        end = time.time() + t
        seen = []
        while time.time() < end:
            try:
                m = cls.q.get(timeout=0.2)
            except queue.Empty:
                continue
            seen.append(m['type'])
            if m['type'] in ('error', 'op-failed'):
                raise AssertionError(f'backend: {m}\n' + ''.join(cls.err[-30:]))
            if pred(m):
                return m
        raise AssertionError(f'timeout; saw {seen[-40:]}\n' + ''.join(cls.err[-30:]))

    def drain(self):
        while not self.q.empty():
            self.q.get_nowait()

    def inbox(self):
        self.send({'cmd': 'list', 'view': {'acc': self.acc, 'folder': 'INBOX'}, 'rid': 9, 'watch': False})
        return self.wait(lambda m: m['type'] == 'list')['items']

    def find(self, subject, items=None):
        for r in items if items is not None else self.inbox():
            if r['subject'] == subject:
                return r
        return None

    # ------------------------------------------------------------------------------------------
    def test_01_folders_and_list(self):
        self.send({'cmd': 'hello'})
        m = self.wait(lambda m: m['type'] == 'folders' and m['items'])
        roles = {f['role']: f for f in m['items']}
        self.assertEqual([f['name'] for f in m['items']][:2], ['Inbox', 'Sent'])
        self.assertIn('trash', roles)
        self.assertIn('junk', roles)
        self.assertEqual(roles['inbox']['total'], 229)
        self.assertEqual(roles['inbox']['unread'], 5)
        items = self.inbox()
        self.assertEqual(len(items), 150)
        self.assertEqual(items[0]['code'], 'G-482913')            # the seeded Google code mail
        self.assertEqual(items[1]['subject'], 'Re: Trip plan for the weekend')
        doc = self.find('Документы на подпись', items)
        self.assertTrue(doc['flagged'] and doc['att'] and not doc['seen'])
        self.assertIn('договор', doc['snippet'])

    def test_02_open_reader_view(self):
        r = self.find('This week in design: glass, blur and depth')
        self.send({'cmd': 'open', 'acc': self.acc, 'folder': 'INBOX', 'uid': r['uid'], 'rid': 5})
        v = self.wait(lambda m: m['type'] == 'msg' and m['rid'] == 5)['view']
        text = ' '.join(b.get('html', '') for b in v['blocks'])
        self.assertNotIn('Preheader', text)
        self.assertIn('Glass is back', text)
        imgs = [b for b in v['blocks'] if b['t'] == 'img']
        self.assertEqual(len(imgs), 2)                       # inline logo + hero; the 1px tracker is gone
        self.assertTrue(imgs[0]['src'].startswith('file://'))
        self.assertTrue(os.path.exists(imgs[0]['src'][7:]))
        self.assertEqual(imgs[1]['url'], 'https://images.example/hero.jpg')
        self.assertFalse(v['showImages'])
        self.assertIn('figma.example/unsub', v['unsub'])
        # opening marks it read, on the server too
        self.wait(lambda m: m['type'] == 'changed')
        self.assertTrue(self.find('This week in design: glass, blur and depth')['seen'])
        c = imap()
        c.select('INBOX')
        typ, data = c.uid('FETCH', str(r['uid']), '(FLAGS)')
        self.assertIn(b'\\Seen', data[0])
        c.logout()

    def test_03_archive_creates_folder_and_undo(self):
        r = self.find('[glass] CI passed on main')
        self.send({'cmd': 'act', 'op': 'archive', 'rid': 7, 'items': [{'acc': self.acc, 'folder': 'INBOX', 'uid': r['uid'], 'msgid': r['msgid']}]})
        m = self.wait(lambda m: m['type'] == 'acted' and m['rid'] == 7)
        self.assertEqual(m['dest'], 'Archive')
        self.assertIsNone(self.find('[glass] CI passed on main'))
        c = imap()
        typ, data = c.select('Archive')
        self.assertEqual(data[0], b'1')
        c.logout()
        self.send({'cmd': 'undo', 'acc': self.acc, 'src': 'INBOX', 'dest': 'Archive', 'msgids': [r['msgid']], 'rid': 8})
        m = self.wait(lambda m: m['type'] == 'undone' and m['rid'] == 8)
        self.assertEqual(m['n'], 1)
        self.assertIsNotNone(self.find('[glass] CI passed on main'))

    def test_04_star_unread_trash_delete(self):
        r = self.find('Photos from Saturday')
        it = [{'acc': self.acc, 'folder': 'INBOX', 'uid': r['uid'], 'msgid': r['msgid']}]
        for op in ('flag', 'unseen'):
            self.send({'cmd': 'act', 'op': op, 'rid': 10, 'items': it})
            self.wait(lambda m: m['type'] == 'acted' and m['op'] == op)
        r2 = self.find('Photos from Saturday')
        self.assertTrue(r2['flagged'])
        self.assertFalse(r2['seen'])
        self.send({'cmd': 'act', 'op': 'trash', 'rid': 11, 'items': it})
        m = self.wait(lambda m: m['type'] == 'acted' and m['rid'] == 11)
        self.assertEqual(m['dest'], 'Trash')
        # in Trash, trash again = delete forever
        self.send({'cmd': 'list', 'view': {'acc': self.acc, 'folder': 'Trash'}, 'rid': 12})
        self.wait(lambda m: m['type'] == 'changed' and m['folder'] == 'Trash')
        self.send({'cmd': 'list', 'view': {'acc': self.acc, 'folder': 'Trash'}, 'rid': 13, 'watch': False})
        items = self.wait(lambda m: m['type'] == 'list' and m['rid'] == 13)['items']
        self.assertEqual([x['subject'] for x in items], ['Photos from Saturday'])
        self.send({'cmd': 'act', 'op': 'trash', 'rid': 14, 'items': [{'acc': self.acc, 'folder': 'Trash', 'uid': items[0]['uid']}]})
        self.wait(lambda m: m['type'] == 'acted' and m['rid'] == 14)
        c = imap()
        typ, data = c.select('Trash')
        self.assertEqual(data[0], b'0')
        c.logout()

    def test_05_search(self):
        self.send({'cmd': 'search', 'q': 'договор', 'rid': 20})
        local = self.wait(lambda m: m['type'] == 'search' and m.get('local'))
        self.assertEqual([x['subject'] for x in local['items']], ['Документы на подпись'])
        server = self.wait(lambda m: m['type'] == 'search' and not m.get('local'))
        self.assertIn('Документы на подпись', [x['subject'] for x in server['items']])
        # an old message that isn't cached is found on the server
        self.send({'cmd': 'search', 'q': 'message 3.', 'rid': 21})
        server = self.wait(lambda m: m['type'] == 'search' and not m.get('local') and m['rid'] == 21)
        self.assertIn('Old message #3', [x['subject'] for x in server['items']])

    def test_06_older(self):
        self.send({'cmd': 'older', 'view': {'acc': self.acc, 'folder': 'INBOX'}})
        self.wait(lambda m: m['type'] == 'changed' and m.get('older'))
        self.send({'cmd': 'older', 'view': {'acc': self.acc, 'folder': 'INBOX'}})
        m = self.wait(lambda m: m['type'] == 'changed' and m.get('older'))
        self.assertTrue(m['complete'])
        self.send({'cmd': 'list', 'view': {'acc': self.acc, 'folder': 'INBOX'}, 'rid': 22, 'limit': 1000, 'watch': False})
        m = self.wait(lambda m: m['type'] == 'list' and m['rid'] == 22)
        c = imap()
        typ, data = c.select('INBOX')
        c.logout()
        self.assertEqual(len(m['items']), int(data[0]))       # the whole folder is cached now
        self.assertTrue(m['complete'])

    def test_07_reply_with_attachment_and_forward(self):
        r = self.find('Trip plan for the weekend')
        att = os.path.join(self.tmp, 'notes.txt')
        with open(att, 'w') as f:
            f.write('packing list')
        self.send({'cmd': 'send', 'acc': self.acc, 'rid': 30, 'attachments': [att], 'draft': {
            'to': 'Mika Aalto <mika@example.org>', 'cc': '', 'bcc': 'hidden@example.org', 'subject': 'Re: Trip plan for the weekend',
            'body': 'Great!\n\n> Hi!', 'inReplyTo': r['msgid'], 'refs': '', 'replyTo': {'folder': 'INBOX', 'uid': r['uid']}}})
        m = self.wait(lambda m: m['type'] == 'sent' and m['rid'] == 30)
        self.assertTrue(m['ok'], m)
        sent = self.smtp.messages[-1]
        self.assertEqual(sorted(sent['rcpt']), ['hidden@example.org', 'mika@example.org'])
        msg = email.message_from_bytes(sent['data'])
        self.assertEqual(msg['In-Reply-To'], r['msgid'])
        self.assertIsNone(msg['Bcc'])
        self.assertIn('notes.txt', [p.get_filename() for p in msg.walk() if p.get_filename()])
        # copy in Sent, \Answered on the original
        time.sleep(0.5)
        c = imap()
        typ, data = c.select('Sent')
        self.assertEqual(data[0], b'2')
        c.select('INBOX')
        typ, data = c.uid('FETCH', str(r['uid']), '(FLAGS)')
        self.assertIn(b'\\Answered', data[0])
        c.logout()
        # forward keeps the original attachments
        doc = self.find('Документы на подпись')
        self.send({'cmd': 'send', 'acc': self.acc, 'rid': 31, 'attachments': [], 'forward': {'folder': 'INBOX', 'uid': doc['uid'], 'keep': [0, 1]},
                   'draft': {'to': 'boss@example.org', 'subject': 'Fwd: Документы на подпись', 'body': 'FYI'}})
        self.assertTrue(self.wait(lambda m: m['type'] == 'sent' and m['rid'] == 31)['ok'])
        msg = email.message_from_bytes(self.smtp.messages[-1]['data'], policy=email.policy.default)
        self.assertEqual(sorted(p.get_filename() for p in msg.iter_attachments()), ['invoice.xlsx', 'Договор.pdf'])

    def test_08_attachment_save(self):
        doc = self.find('Документы на подпись')
        self.send({'cmd': 'att-save', 'acc': self.acc, 'folder': 'INBOX', 'uid': doc['uid'], 'i': 0})
        m = self.wait(lambda m: m['type'] == 'saved')
        self.assertEqual(m['name'], 'Договор.pdf')
        with open(m['path'], 'rb') as f:
            self.assertTrue(f.read().startswith(b'%PDF'))

    def test_09_new_mail_via_idle_notifies(self):
        self.drain()
        c = imap()
        m = seed.msg(('Nadia K', 'nadia@example.org'), USER, 'Fresh one', 'Just arrived!')
        c.append('INBOX', None, imaplib.Time2Internaldate(time.time()), m.as_bytes())
        c.logout()
        t0 = time.time()
        self.wait(lambda m: m['type'] == 'changed' and m['folder'] == 'INBOX', t=15)
        self.assertLess(time.time() - t0, 10)
        self.assertEqual(self.inbox()[0]['subject'], 'Fresh one')
        for _ in range(20):
            if os.path.exists(self.notes):
                break
            time.sleep(0.1)
        with open(self.notes) as f:
            notes = [json.loads(ln) for ln in f]
        self.assertEqual(notes[-1]['title'], 'Nadia K')
        self.assertIn('Fresh one', notes[-1]['body'])
        with open(os.path.join(self.tmp, 'state', 'unread.json')) as f:
            self.assertGreaterEqual(json.load(f)['unread'], 1)

    def test_09b_login_code_copied(self):
        self.drain()
        c = imap()
        m = seed.msg(('Telegram', 'noreply@telegram.example'), USER, 'Sign in to Telegram',
                     'Your login code: 62519. Do not give this code to anyone.')
        c.append('INBOX', None, imaplib.Time2Internaldate(time.time()), m.as_bytes())
        c.logout()
        self.wait(lambda m: m['type'] == 'code', t=15)
        with open(self.notes) as f:
            notes = [json.loads(ln) for ln in f]
        self.assertIn({'copied': '62519'}, notes)
        self.assertTrue(any(n.get('title') == '62519 copied' for n in notes))
        # copied → the mail goes straight to the Trash (default), read
        for _ in range(30):
            if 'Sign in to Telegram' not in [x['subject'] for x in self.inbox()[:3]]:
                break
            time.sleep(0.1)
        self.assertNotIn('Sign in to Telegram', [x['subject'] for x in self.inbox()[:3]])
        c = imap()
        c.select('Trash')
        found = c.uid('SEARCH', 'SUBJECT', 'Telegram')[1][0].split()
        typ, d = c.uid('FETCH', found[-1], '(FLAGS)')
        c.logout()
        self.assertTrue(found)
        self.assertIn(b'\\Seen', d[0])

    @unittest.skipUnless(os.environ.get('GLASS_MAIL_TEST_AI') == '1', 'set GLASS_MAIL_TEST_AI=1 (uses the local model)')
    def test_12_ai_analyze_and_ask(self):
        doc = self.find('Документы на подпись')
        self.send({'cmd': 'ai-analyze', 'acc': self.acc, 'folder': 'INBOX', 'uid': doc['uid'], 'rid': 50})
        res = self.wait(lambda m: m['type'] == 'ai-analysis' and m['rid'] == 50, t=240)['result']
        self.assertTrue(res['summary'])
        self.assertGreaterEqual(len(res['replies']), 1)
        self.send({'cmd': 'ai-analyze', 'acc': self.acc, 'folder': 'INBOX', 'uid': doc['uid'], 'rid': 51})
        self.assertTrue(self.wait(lambda m: m['type'] == 'ai-analysis' and m['rid'] == 51)['cached'])
        self.send({'cmd': 'ai-ask', 'q': 'Что Лена прислала на подпись?', 'rid': 52})
        src = self.wait(lambda m: m['type'] == 'ai-sources' and m['rid'] == 52)
        self.assertIn('Документы на подпись', [r['subject'] for r in src['items']])
        ans = self.wait(lambda m: m['type'] == 'ai-done' and m['rid'] == 52, t=240)
        self.assertIn('[', ans['text'])

    def test_10_wrong_password(self):
        self.send({'cmd': 'account-save', 'rid': 40, 'account': {
            'email': 'other@test.local', 'password': 'nope', 'imapHost': '127.0.0.1', 'imapPort': PORT,
            'smtpHost': '127.0.0.1', 'smtpPort': self.smtp.port, 'smtpSecurity': 'plain'}})
        m = self.wait(lambda m: m['type'] == 'account-saved' and m['rid'] == 40)
        self.assertFalse(m['ok'])
        self.assertIn('refused', m['text'])


if __name__ == '__main__':
    unittest.main()
