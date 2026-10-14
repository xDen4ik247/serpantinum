"""Differential test of the background side: glass-mail-watch (IMAP IDLE) and the one-shot check,
Python vs Rust, against the same freshly seeded Dovecot. Compares notifications, clipboard copies,
the cache and the server state; prints latency, memory and CPU. Never touches real accounts.

    python -m tests.parity.watch_diff
"""
import email.utils
import imaplib
import json
import os
import random
import shutil
import signal
import sqlite3
import subprocess
import sys
import time

from tests import seed
from tests.parity.live_diff import norm, norm_mail, NAME, PORT, USER, PASS, imap, SEED_AT, RUST

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.environ.get('GLASS_MAIL_DIFF_OUT', '/tmp/glass-mail-diff')
TMP = os.path.join(OUT, 'watch-home')
CONF = {'id': 'acc0000001', 'email': USER, 'name': 'Me Test', 'user': USER, 'password': PASS, 'provider': 'other',
        'imap': {'host': '127.0.0.1', 'port': PORT}, 'smtp': {'host': '127.0.0.1', 'port': 25, 'security': 'plain'},
        'signature': '', 'color': '#80d4db'}


def fresh_server():
    subprocess.run(['docker', 'rm', '-f', NAME], capture_output=True)
    subprocess.run(['docker', 'run', '-d', '--name', NAME, '-e', f'USER_PASSWORD={PASS}',
                    '-p', f'127.0.0.1:{PORT}:31993', 'dovecot/dovecot:latest'], check=True, capture_output=True)
    for _ in range(100):
        try:
            imap().logout()
            break
        except Exception:
            time.sleep(0.2)
    n = iter(range(10 ** 6))
    email.utils.make_msgid = lambda idstring=None, domain=None: f'<seed{next(n)}@{domain or "x"}>'
    seed.time = type('T', (), {'time': staticmethod(lambda: SEED_AT)})
    random.seed(7)
    seed.seed('127.0.0.1', PORT, USER, PASS, many=40)


def append(frm, subject, text, msgid):
    c = imap()
    m = seed.msg(frm, USER, subject, text, msgid=msgid, when=time.time())
    c.append('INBOX', None, imaplib.Time2Internaldate(time.time()), m.as_bytes())
    c.logout()


def notes(path):
    try:
        with open(path) as f:
            return [json.loads(ln) for ln in f]
    except OSError:
        return []


def wait_for(pred, t=20):
    end = time.time() + t
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


def proc_stats(pid):
    with open(f'/proc/{pid}/status') as f:
        st = dict(ln.split(':', 1) for ln in f if ':' in ln)
    with open(f'/proc/{pid}/stat') as f:
        fields = f.read().rsplit(')', 1)[1].split()
    tick = os.sysconf('SC_CLK_TCK')
    cpu = (int(fields[11]) + int(fields[12])) / tick
    return {'rss_kb': int(st['VmRSS'].split()[0]), 'hwm_kb': int(st['VmHWM'].split()[0]), 'cpu_s': cpu,
            'threads': int(st['Threads']), 'ctxsw': int(st['voluntary_ctxt_switches']) + int(st['nonvoluntary_ctxt_switches'])}


def run(name, cmd):
    fresh_server()
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP + '/config')
    with open(TMP + '/config/accounts.json', 'w') as f:
        json.dump({'accounts': [CONF]}, f)
    log = TMP + '/notify.log'
    env = dict(os.environ, PYTHONPATH=ROOT, GLASS_MAIL_INSECURE='1', GLASS_MAIL_NOTIFY_LOG=log,
               GLASS_MAIL_CONFIG=TMP + '/config', GLASS_MAIL_CACHE=TMP + '/cache', GLASS_MAIL_STATE=TMP + '/state',
               GLASS_MAIL_DOWNLOADS=TMP + '/downloads', TZ='Asia/Tokyo', LANG='C.UTF-8', LC_ALL='C.UTF-8')
    res = {'events': []}
    t0 = time.time()
    p = subprocess.Popen(cmd + ['watch'] if name == 'rust' else cmd + ['-m', 'glassmail.watch'], cwd=ROOT, env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        db = TMP + '/cache/mail.db'

        def synced():
            try:
                c = sqlite3.connect(db)
                n = c.execute("select count(*) from messages").fetchone()[0]
                c.close()
                return n >= 40
            except sqlite3.Error:
                return False
        res['first_sync_s'] = round(time.time() - t0, 2) if wait_for(synced, 30) else None
        time.sleep(2)
        # idle cost over 20 s with an IDLE connection open
        a = proc_stats(p.pid)
        time.sleep(20)
        b = proc_stats(p.pid)
        res['idle'] = {'cpu_ms_per_min': round((b['cpu_s'] - a['cpu_s']) * 3000, 1), 'wakeups_per_min': (b['ctxsw'] - a['ctxsw']) * 3,
                       'rss_kb': b['rss_kb'], 'threads': b['threads']}
        n0 = len(notes(log))
        t1 = time.time()
        append(('Nadia K', 'nadia@example.org'), 'Fresh one', 'Just arrived!', '<fresh@example.test>')
        ok = wait_for(lambda: len(notes(log)) > n0, 20)
        res['new_mail_latency_s'] = round(time.time() - t1, 2) if ok else None
        n0 = len(notes(log))
        t1 = time.time()
        append(('Telegram', 'noreply@telegram.example'), 'Sign in to Telegram', 'Your login code: 62519. Do not give this code to anyone.', '<tg@example.test>')
        ok = wait_for(lambda: any(x.get('copied') for x in notes(log)[n0:]), 20)
        res['code_latency_s'] = round(time.time() - t1, 2) if ok else None
        time.sleep(3)     # the code mail goes to the Trash
        # an edited account restarts its watcher
        conf = dict(CONF, name='Renamed')
        with open(TMP + '/config/accounts.json', 'w') as f:
            json.dump({'accounts': [conf]}, f)
        time.sleep(5)
        append(('Sora Tanaka', 'sora@example.net'), 'After the edit', 'Still watching?', '<after@example.test>')
        n0 = len(notes(log))
        res['after_edit'] = wait_for(lambda: len(notes(log)) > n0, 20)
        res['proc'] = proc_stats(p.pid)
    finally:
        p.send_signal(signal.SIGTERM)
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            p.kill()
    res['stderr'] = p.stderr.read()
    # the one-shot check (app not running): picks up what arrived while nothing watched
    append(('Lena Petrova', 'lena@example.com'), 'While you were away', 'Checked by the timer.', '<away@example.test>')
    t1 = time.time()
    subprocess.run(cmd + ['check'] if name == 'rust' else cmd + ['-m', 'glassmail.check'], cwd=ROOT, env=env, check=True,
                   capture_output=True, timeout=60)
    res['check_s'] = round(time.time() - t1, 2)
    res['notes'] = [norm(x) for x in notes(log)]
    c = imap()
    left = {}
    for b in ('INBOX', 'Trash'):
        c.select(b)
        typ, data = c.uid('FETCH', '1:*', '(FLAGS BODY.PEEK[HEADER.FIELDS (SUBJECT)])')
        left[b] = sorted((d[1].decode().strip(), ' '.join(sorted(set(d[0].decode().split('FLAGS (')[1].split(')')[0].split()) - {'\\Recent'})))
                         for d in data if isinstance(d, tuple))
    c.logout()
    res['imap'] = left
    dbc = sqlite3.connect(TMP + '/cache/mail.db')
    res['db'] = {t: sorted(json.dumps(norm(dict(zip([r[1] for r in dbc.execute(f'pragma table_info({t})')], row))), sort_keys=True, ensure_ascii=False, default=str)
                           for row in dbc.execute(f'select * from {t}'))
                 for (t,) in dbc.execute("select name from sqlite_master where type='table'")}
    with open(TMP + '/state/unread.json') as f:
        res['unread'] = norm(json.load(f))
    return res


def main():
    os.makedirs(OUT, exist_ok=True)
    py = run('python', [sys.executable])
    rs = run('rust', [RUST])
    subprocess.run(['docker', 'rm', '-f', NAME], capture_output=True)
    shutil.rmtree(TMP, ignore_errors=True)
    with open(OUT + '/watch.json', 'w') as f:
        json.dump({'python': py, 'rust': rs}, f, ensure_ascii=False, indent=1)
    bad = 0
    for k in ('notes', 'imap', 'db', 'unread', 'after_edit'):
        if py[k] != rs[k]:
            bad += 1
            print(f'=== {k} differs')
            if isinstance(py[k], dict):
                for kk in py[k]:
                    if py[k][kk] != rs[k].get(kk):
                        print(f'  {kk}:\n   py {str(py[k][kk])[:900]}\n   rs {str(rs[k].get(kk))[:900]}')
            else:
                print(f'   py {str(py[k])[:1500]}\n   rs {str(rs[k])[:1500]}')
    for k in ('first_sync_s', 'new_mail_latency_s', 'code_latency_s', 'check_s', 'idle', 'proc'):
        print(f'{k:20} py {py[k]}\n{"":20} rs {rs[k]}')
    for n, r in (('python', py), ('rust', rs)):
        if r['stderr'].strip():
            print(f'--- {n} stderr\n{r["stderr"][-800:]}')
    print(f'watch: {bad} differing')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
