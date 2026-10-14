"""The reader's web view (HTML mails drawn by glass-mail-web) end to end: Dovecot in Docker, the
Rust backend, and a local HTTP server that counts every request a mail tries to make.
Skipped without Docker or the built binaries. Never touches real accounts or ~/.config.

    cargo build --release --manifest-path backend/Cargo.toml
    cargo build --release --manifest-path web/Cargo.toml
    python -m unittest tests.test_web -v
"""
import struct
import zlib
from email.message import EmailMessage
import http.server
import imaplib
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from tests import seed
from tests.fakesmtp import FakeSMTP
from tests.test_live import NAME, PORT, USER, PASS, imap, docker_ok

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUST = os.path.join(ROOT, 'backend/target/release/glass-mail-backend')
WEB = os.path.join(ROOT, 'web/target/release/glass-mail-web')
COLORS = {'text': '#dde4e4', 'link': '#80d4db', 'quote': '#899393', 'font': 'Google Sans'}

def png(w, h, rgb):
    """A solid-colour PNG, written by hand (no Pillow needed)."""
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


RED_PNG = png(40, 40, (230, 20, 20))


class Hits(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        Hits.seen.append(self.path)
        body = RED_PNG if self.path.endswith('.png') else b'body{}'
        self.send_response(200)
        self.send_header('Content-Type', 'image/png' if self.path.endswith('.png') else 'text/css')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def newsletter(h):
    """A designed mail that also tries every way of phoning home or running code."""
    return f'''<html><head>
<link rel="stylesheet" href="{h}/style.css"><style>@import url("{h}/import.css"); .x{{color:#333}}</style>
<meta http-equiv="refresh" content="0;url={h}/refresh">
<script>fetch("{h}/script")</script></head>
<body><table width="100%" bgcolor="#f3f4f6"><tr><td align="center" background="{h}/bg.png">
<table width="560" bgcolor="#ffffff"><tr><td style="background:#4f46e5;color:#fff;padding:24px;font-size:24px">Weekly Digest</td></tr>
<tr><td style="padding:20px;color:#333">Hello! <a href="https://example.com/read">Read more</a>
<a href="javascript:alert(1)">bad link</a> <img src="{h}/remote.png" width="40" height="40">
<img src="x" onerror="fetch('{h}/onerror')"><iframe src="{h}/iframe"></iframe>
<div style="background-image:url({h}/cssbg.png);width:40px;height:40px"></div></td></tr></table>
</td></tr></table></body></html>'''


PROSE = ('<div>Hey,</div><div><br></div><div>Lunch tomorrow at <b>12:30</b>? The place on '
         '<a href="https://maps.example/x">Maple st</a>.</div><blockquote>earlier message</blockquote><div>— Lena</div>')
INLINE = '<p>Our logo:</p><p><img src="cid:logo@x" width="40" height="40"></p>'


def inline_mail(me):
    m = EmailMessage()
    m['From'] = 'Brand <brand@example.com>'
    m['To'] = f'{me[0]} <{me[1]}>'
    m['Subject'] = 'Logo'
    m.set_content('Logo')
    m.add_alternative(INLINE, subtype='html')
    m.get_payload()[1].add_related(RED_PNG, 'image', 'png', cid='<logo@x>')
    return m


@unittest.skipUnless(docker_ok() and os.path.exists(RUST) and os.path.exists(WEB), 'needs docker and the built binaries')
class Web(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Hits)
        threading.Thread(target=cls.http.serve_forever, daemon=True).start()
        h = f'http://127.0.0.1:{cls.http.server_port}'
        subprocess.run(['docker', 'rm', '-f', NAME], capture_output=True)
        subprocess.run(['docker', 'run', '-d', '--name', NAME, '-e', f'USER_PASSWORD={PASS}',
                        '-p', f'127.0.0.1:{PORT}:31993', 'dovecot/dovecot:latest'], check=True, capture_output=True)
        for _ in range(50):
            try:
                imap().logout()
                break
            except Exception:
                time.sleep(0.2)
        c = imap()
        me = ('Me Test', USER)
        now = time.time()
        mails = {
            'news': seed.msg(('Digest', 'news@shop.example'), me, 'Weekly Digest', text='Weekly Digest', html=newsletter(h), when=now - 300),
            'prose': seed.msg(('Lena Petrova', 'lena@example.com'), me, 'Lunch?', text='Lunch?', html=PROSE, when=now - 200),
            'inline': inline_mail(me),
        }
        for k, m in mails.items():
            if m is not None:
                c.append('INBOX', None, imaplib.Time2Internaldate(time.time()), m.as_bytes())
        c.select('INBOX')
        cls.uid = {}
        for k, subj in (('news', 'Weekly Digest'), ('prose', 'Lunch?'), ('inline', 'Logo')):
            typ, d = c.uid('SEARCH', None, 'SUBJECT', f'"{subj}"')
            if d and d[0]:
                cls.uid[k] = int(d[0].split()[-1])
        c.logout()

        cls.smtp = FakeSMTP()
        cls.tmp = tempfile.mkdtemp(prefix='glass-mail-web-test-')
        env = dict(os.environ, GLASS_MAIL_INSECURE='1', GLASS_MAIL_NOTIFY_LOG=cls.tmp + '/notify.log',
                   GLASS_MAIL_CONFIG=cls.tmp + '/config', GLASS_MAIL_CACHE=cls.tmp + '/cache',
                   GLASS_MAIL_STATE=cls.tmp + '/state', GLASS_MAIL_DOWNLOADS=cls.tmp + '/downloads', GLASS_MAIL_WEB=WEB)
        cls.p = subprocess.Popen([RUST], cwd=ROOT, env=env, text=True,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        cls.q = queue.Queue()
        threading.Thread(target=lambda: [cls.q.put(json.loads(ln)) for ln in cls.p.stdout], daemon=True).start()
        cls.send({'cmd': 'hello'})
        cls.wait(lambda m: m['type'] == 'hello')
        cls.send({'cmd': 'account-save', 'rid': 1, 'account': {
            'email': USER, 'name': 'Me Test', 'password': PASS, 'imapHost': '127.0.0.1', 'imapPort': PORT,
            'smtpHost': '127.0.0.1', 'smtpPort': cls.smtp.port, 'smtpSecurity': 'plain'}})
        m = cls.wait(lambda m: m['type'] == 'account-saved')
        assert m['ok'], m
        cls.acc = m['id']
        cls.wait(lambda m: m['type'] == 'changed' and m['folder'] == 'INBOX', t=40)
        cls.rid = 100

    @classmethod
    def tearDownClass(cls):
        cls.p.stdin.close()
        cls.p.terminate()
        cls.p.wait(5)
        cls.http.shutdown()
        subprocess.run(['docker', 'rm', '-f', NAME], capture_output=True)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def send(cls, obj):
        cls.p.stdin.write(json.dumps(obj) + '\n')
        cls.p.stdin.flush()

    @classmethod
    def wait(cls, pred, t=20):
        end = time.time() + t
        while time.time() < end:
            try:
                m = cls.q.get(timeout=max(0.05, end - time.time()))
            except queue.Empty:
                break
            if pred(m):
                return m
        raise AssertionError('timed out')

    def web(self, which, images=False, width=640):
        Web.rid += 1
        rid = Web.rid
        t0 = time.time()
        self.send({'cmd': 'web', 'acc': self.acc, 'folder': 'INBOX', 'uid': self.uid[which], 'rid': rid,
                   'width': width, 'zoom': 1.5, 'images': images, 'colors': COLORS})
        m = self.wait(lambda m: m['type'] == 'web' and m['rid'] == rid, t=60)
        m['took'] = time.time() - t0
        return m

    def test_1_blocks_everything_by_default(self):
        Hits.seen.clear()
        m = self.web('news')
        self.assertTrue(m['ok'], m)
        print(f"\n  newsletter drawn in {m['took']:.2f}s: {m['w']:.0f}×{m['h']:.0f} css px, paper={m['paper']}")
        self.assertTrue(os.path.getsize(m['png']) > 1000)
        self.assertTrue(m['paper'], 'a designed mail sits on white paper')
        self.assertAlmostEqual(m['w'], 640, delta=2)
        hrefs = [l[4] for l in m['links']]
        self.assertIn('https://example.com/read', hrefs)
        self.assertFalse([x for x in hrefs if x.lower().startswith('javascript')], hrefs)
        time.sleep(1)
        self.assertEqual(Hits.seen, [], 'nothing may be fetched before "Show images"')

    def test_2_images_on_loads_images_only(self):
        Hits.seen.clear()
        m = self.web('news', images=True)
        self.assertTrue(m['ok'], m)
        time.sleep(1)
        seen = set(Hits.seen)
        self.assertIn('/remote.png', seen)
        for bad in ('/script', '/onerror', '/refresh', '/iframe'):
            self.assertNotIn(bad, seen, f'{bad} must never load: {sorted(seen)}')

    def test_3_prose_blends_in(self):
        m = self.web('prose')
        self.assertTrue(m['ok'], m)
        self.assertFalse(m['paper'], 'plain prose blends into the glass')
        self.assertIn('https://maps.example/x', [l[4] for l in m['links']])

    def test_4_cache(self):
        a = self.web('prose')
        b = self.web('prose')
        self.assertEqual(a['png'], b['png'])
        self.assertLess(b['took'], 0.5)
        c = self.web('prose', width=500)
        self.assertNotEqual(a['png'], c['png'])
        self.assertAlmostEqual(c['w'], 500, delta=2)

    def test_5_inline_image(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest('needs Pillow')
        m = self.web('inline')
        self.assertTrue(m['ok'], m)
        im = Image.open(m['png']).convert('RGBA')
        red = sum(1 for p in (im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata()) if p[0] > 200 and p[1] < 40 and p[2] < 40 and p[3] > 200)
        self.assertGreater(red, 1000, 'the cid: image is drawn')


if __name__ == '__main__':
    unittest.main()
