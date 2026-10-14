"""Outgoing mail parity: mime.build (Python) vs the Rust builder on many drafts, compared after
normalizing what is random (boundaries, Message-ID, Date).
    python -m tests.parity.build_parity [RUST_BIN]"""
import base64
import itertools
import json
import os
import random
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'backend/target/release/glass-mail-backend')

BOUND = re.compile(r'boundary="?([^";\s]+)"?')


def norm(raw):
    t = base64.b64decode(raw).decode('utf-8', 'surrogateescape')
    for i, b in enumerate(dict.fromkeys(BOUND.findall(t))):
        t = t.replace(b, f'BOUNDARY{i}')
    t = re.sub(r'(?m)^Message-ID: <[^>]*>\r$', 'Message-ID: <MSGID>\r', t)
    t = re.sub(r'(?m)^Date: [^\r]*\r$', 'Date: NOW\r', t)
    return t


def cases(tmp):
    rnd = random.Random(5)
    words = ['Hello', 'world', 'Привет', 'мир', 'встреча', 'в', 'пятницу', '🍣', 'café', 'naïve', 'a', 'договор',
             'ДОКУМЕНТЫ', 'x' * 30, 'Re:', 'Fwd:', '—', '(note)', '"quoted"', 'a,b', 'semi;colon', '日本語', 'テスト',
             '=?utf-8?q?hi?=', 'tab\there', 'end.', 'ok?', 'question?=', '=?bogus']
    subjects = ['', 'Hi', 'Re: Trip plan for the weekend', 'Fwd: Документы на подпись', 'Привет — встреча 🍣',
                'x' * 77, 'x' * 78, 'x' * 79, 'y' * 200, ('word ' * 30).strip(), 'Hello Мир world', 'Мир hello Мир',
                'a' * 60 + ' Привет', 'Привет ' * 20, '  leading and trailing  ', 'Line\nbreak', 'trailing newline\n',
                '=?utf-8?b?0J/RgNC40LLQtdGC?= there', 'mixed =?utf-8?q?caf=C3=A9?= =?utf-8?q?_ok?=', 'Ünïcödé ' * 6]
    for _ in range(int(os.environ.get("N_SUBJ", "60"))):
        subjects.append(' '.join(rnd.choice(words) for _ in range(rnd.randint(1, 25))))
    bodies = ['', 'Hi', 'Great!\n\n> Hi!\n> > nested', 'Пока!', 'Long line ' * 40 + '\n.\n..dots\nПока!',
              'a' * 78, 'a' * 79, 'a' * 76 + '=', 'a' * 75 + '==b', 'trailing space \nnext', 'x' * 77 + ' ', 'x' * 76 + ' ',
              'x' * 150 + '\t', 'crlf\r\nbody\r\n', 'cr\ronly', 'Привет мир ' * 12, '\n'.join(['short'] * 15 + ['L' * 100]),
              '\n'.join(['Ш' * 50] * 12), 'From the start\nFrom here', 'emoji 🍣🍣🍣 ' * 10, 'tab\tsep', '\x0bvt\x0cff',
              '<b>html</b> & "quotes"\nhttps://example.org/a?b=c&d=e', 'end with newline\n', '\n\n\n']
    for _ in range(int(os.environ.get("N_BODY", "25"))):
        bodies.append('\n'.join(' '.join(rnd.choice(words) for _ in range(rnd.randint(0, 30))) for _ in range(rnd.randint(1, 14))))
    tos = ['', 'mika@example.org', 'Mika Aalto <mika@example.org>', '"Иван Смирнов" <ivan@example.ru>, sora@example.net',
           'Smith, John <john@x.org>', '"Smith, John" <john@x.org>; b@y.z', 'J. R. R. Tolkien <jrr@example.com>',
           ', '.join(f'Person Number {i} <p{i}@example.org>' for i in range(8)),
           ', '.join(f'Пользователь {i} <u{i}@example.ru>' for i in range(6)),
           'Очень длинное имя пользователя которое не помещается в одну строку заголовка <long@example.ru>',
           'Back\\slash "q" <bq@x.org>', 'O\'Brien <ob@x.org>', 'bad address, also bad', 'a@b, a@b']
    refs = ['', '<a@b>', '<a@b> <c@d>', ' '.join(f'<msg{i}.{"x" * 20}@example.org>' for i in range(25)), 'abc', '<a b@c>', 'foo <x@y> bar',
            '<x@[1.2.3.4]>', '<a@b><c@d>', '<a@b>,<c@d>', '<' + 'z' * 90 + '@example.org>']
    att = os.path.join(tmp, 'notes.txt')
    open(att, 'w').write('packing list\n')
    att2 = os.path.join(tmp, 'Очень длинное имя файла для проверки переноса параметров RFC 2231.pdf')
    open(att2, 'wb').write(bytes(range(256)) * 3)
    att3 = os.path.join(tmp, 'a "quoted" name; with=specials.tar.gz')
    open(att3, 'wb').write(b'')
    att4 = os.path.join(tmp, 'x' * 70 + '.docx')
    open(att4, 'wb').write(b'PK' * 100)
    atts = [[], [att], [att, att2, att3, att4]]
    fwds = [[], [['Договор.pdf', 'application/pdf', base64.b64encode(b'%PDF-1.4 fake').decode()],
                 ['invoice.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', base64.b64encode(b'PK fake').decode()],
                 ['msg.eml', 'message/rfc822', base64.b64encode(b'Subject: x\r\n\r\nhi').decode()]]]
    accs = [{'email': 'me@test.local', 'name': 'Me Test'}, {'email': 'me@test.local', 'name': ''},
            {'email': 'ivan@example.ru', 'name': 'Иван Смирнов'}, {'email': 'd@x.org', 'name': 'Dr. Who'}]
    out = []
    for i, s in enumerate(subjects):
        out.append({'fn': 'build', 'acc': accs[i % len(accs)], 'draft': {'to': tos[i % len(tos)], 'subject': s, 'body': bodies[i % len(bodies)]},
                    'attachments': atts[i % 3], 'forwarded': fwds[i % 2]})
    for b, a in itertools.product(bodies, accs[:2]):
        out.append({'fn': 'build', 'acc': a, 'draft': {'to': 'a@b.c', 'subject': 'body', 'body': b}, 'attachments': [], 'forwarded': []})
    for t, c in itertools.product(tos, tos[:4]):
        out.append({'fn': 'build', 'acc': accs[2], 'draft': {'to': t, 'cc': c, 'bcc': 'h@x.org', 'subject': 'addr', 'body': 'b'}, 'attachments': [], 'forwarded': []})
    for r in refs:
        for irt in ['<plan-1@example.test>', r]:
            out.append({'fn': 'build', 'acc': accs[0], 'draft': {'to': 'a@b.c', 'subject': 'Re: x', 'body': 'b', 'inReplyTo': irt, 'refs': r}, 'attachments': [att], 'forwarded': []})
    return out


def main():
    tmp = tempfile.mkdtemp(prefix='gm-build-')
    reqs = cases(tmp)
    inp = ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in reqs)
    env = dict(os.environ, TZ='Asia/Tokyo')
    py = subprocess.run([sys.executable, os.path.join(ROOT, 'tests/parity/pure_ref.py')], input=inp, capture_output=True, text=True, env=env, check=True).stdout.splitlines()
    rs = subprocess.run([RUST, '--pure'], input=inp, capture_output=True, text=True, env=env, check=True).stdout.splitlines()
    bad = 0
    for req, a, b in zip(reqs, py, rs):
        a, b = json.loads(a), json.loads(b)
        if a[0] != 'error':
            a[0] = norm(a[0])
        if b[0] != 'error':
            b[0] = norm(b[0])
        if a != b:
            bad += 1
            if bad <= int(os.environ.get('SHOW', '4')):
                print('--- draft', json.dumps(req['draft'], ensure_ascii=False)[:300], req['acc'])
                if isinstance(a[0], str) and isinstance(b[0], str):
                    al, bl = a[0].split('\r\n'), b[0].split('\r\n')
                    for x, y in zip(al, bl):
                        if x != y:
                            print('  py', repr(x)[:300])
                            print('  rs', repr(y)[:300])
                            break
                    else:
                        print('  lengths', len(al), len(bl))
                    if a[1] != b[1]:
                        print('  rcpts', a[1], b[1])
                else:
                    print('  py', str(a)[:300], '\n  rs', str(b)[:300])
    print(f'build: {bad} / {len(reqs)} differ')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
