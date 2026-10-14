"""Fill a test IMAP account with realistic mail (made-up people, no real data).
   python -m tests.seed HOST PORT USER PASSWORD [--many N]"""
import email.utils
import imaplib
import ssl
import sys
import time
from email.message import EmailMessage

def png(w, h, rgb):
    """A valid solid-colour PNG (no image libraries needed)."""
    import struct
    import zlib
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def chunk(t, data):
        return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


PNG = png(48, 48, (0x80, 0xd4, 0xdb))


PEOPLE = [('Mika Aalto', 'mika@example.org'), ('Sora Tanaka', 'sora@example.net'), ('Lena Petrova', 'lena@example.com'),
          ('GitHub', 'noreply@github.example'), ('Figma Weekly', 'news@figma.example'), ('Tomás Ruiz', 'tomas@example.org'),
          ('Bank Alerts', 'alerts@bank.example'), ('Иван Смирнов', 'ivan@example.ru')]


def msg(frm, to, subject, text=None, html=None, when=None, attach=(), inline=None, msgid=None, reply_to_id=None, extra=None):
    m = EmailMessage()
    m['From'] = email.utils.formataddr(frm)
    m['To'] = to
    m['Subject'] = subject
    m['Date'] = email.utils.formatdate(when or time.time(), localtime=True)
    m['Message-ID'] = msgid or email.utils.make_msgid(domain='example.test')
    if reply_to_id:
        m['In-Reply-To'] = reply_to_id
        m['References'] = reply_to_id
    for k, v in (extra or {}).items():
        m[k] = v
    m.set_content(text or 'See the HTML version.')
    if html:
        m.add_alternative(html, subtype='html')
        if inline:
            m.get_payload()[1].add_related(PNG, 'image', 'png', cid='<logo1@example.test>')
    for name, ctype, data in attach:
        mt, st = ctype.split('/')
        m.add_attachment(data, maintype=mt, subtype=st, filename=name)
    return m


def seed(host, port, user, password, many=0):
    c = imaplib.IMAP4_SSL(host, port, ssl_context=ssl._create_unverified_context())
    c.login(user, password)
    now = time.time()
    me = user
    d = lambda h: now - h * 3600  # noqa: E731
    first = '<plan-1@example.test>'
    mails = [
        ('INBOX', msg(PEOPLE[0], me, 'Trip plan for the weekend', 'Hi!\n\nHere is the plan:\n- Saturday: lake\n- Sunday: the old town\n\nTickets are at https://tickets.example.org/abc\n\nMika', when=d(0.3), msgid=first), ()),
        ('INBOX', msg(PEOPLE[1], me, 'Re: Trip plan for the weekend', 'Sounds great, count me in.\n\n> Hi!\n> Here is the plan:\n> - Saturday: lake', when=d(0.2), reply_to_id=first), ()),
        ('INBOX', msg(PEOPLE[4], me, 'This week in design: glass, blur and depth',
                      html='<html><head><style>.x{color:red}</style></head><body><div style="display:none">Preheader text you should not see</div>'
                           '<img src="cid:logo1@example.test" width="24" alt="logo"><h1>Glass is back</h1><p>Translucent surfaces, soft rims and <b>depth</b> are everywhere this season. '
                           '<a href="https://figma.example/read">Read the story</a>.</p><img src="https://images.example/hero.jpg" width="600" alt="Hero image">'
                           '<ul><li>Blur behind panels</li><li>Hairline rims</li><li>Tinted backgrounds</li></ul>'
                           '<img src="https://track.example/p.gif" width="1" height="1"><p style="font-size:11px">Unsubscribe any time.</p></body></html>',
                      inline=True, when=d(3), extra={'List-Unsubscribe': '<https://figma.example/unsub?u=1>, <mailto:unsub@figma.example>'}), ()),
        ('INBOX', msg(PEOPLE[2], me, 'Документы на подпись', 'Привет!\n\nВо вложении договор и счёт. Посмотри, пожалуйста, до пятницы.\n\nЛена',
                      when=d(5), attach=[('Договор.pdf', 'application/pdf', b'%PDF-1.4 fake pdf\n'), ('invoice.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', b'PK fake')]), ('\\Flagged',)),
        ('INBOX', msg(PEOPLE[3], me, '[glass] CI passed on main', 'All checks have passed.\n\nhttps://github.example/glass/actions/runs/1', when=d(26)), ('\\Seen',)),
        ('INBOX', msg(PEOPLE[5], me, 'Photos from Saturday', 'A few photos from the lake 📷', when=d(30), attach=[('lake.png', 'image/png', PNG)]), ('\\Seen',)),
        ('INBOX', msg(PEOPLE[6], me, 'Your statement is ready', html='<table><tr><th>Date</th><th>Amount</th></tr><tr><td>01.10</td><td>−1 200 ₽</td></tr><tr><td>05.10</td><td>+30 000 ₽</td></tr></table><p>Thanks for banking with us.</p>', when=d(80)), ('\\Seen',)),
        ('INBOX', msg(PEOPLE[7], me, 'Встреча в четверг', 'Ок, четверг в 18:00 подходит.', when=d(200)), ('\\Seen', '\\Answered')),
        ('INBOX', msg(('Google', 'no-reply@accounts.google.example'), me, 'G-482913 is your Google verification code',
                      'Use this code to finish signing in on a new device.\n\nG-482913\n\nIf this wasn’t you, review your security.', when=d(0.1)), ()),
        ('Sent', msg(('Me', me), 'mika@example.org', 'Re: dinner', 'See you at 7!', when=d(48)), ('\\Seen',)),
        ('Junk', msg(('Prize Team', 'win@spam.example'), me, 'You won!!!', 'Click here.', when=d(10)), ()),
    ]
    # older mail first: servers hand out UIDs in arrival order
    old = []
    for i in reversed(range(many)):
        p = PEOPLE[i % len(PEOPLE)]
        old.append(('INBOX', msg(p, me, f'Old message #{i + 1}', f'Body of message {i + 1}.', when=d(300 + i * 5)), ('\\Seen',)))
    mails = old + sorted(mails, key=lambda x: email.utils.parsedate_to_datetime(x[1]['Date']).timestamp())
    for box, m, flags in mails:
        when = email.utils.parsedate_to_datetime(m['Date']).timestamp()
        typ, data = c.append(box, '(' + ' '.join(flags) + ')' if flags else None, imaplib.Time2Internaldate(when), m.as_bytes())
        assert typ == 'OK', (box, data)
    c.logout()
    return len(mails)


if __name__ == '__main__':
    a = sys.argv[1:]
    many = int(a[a.index('--many') + 1]) if '--many' in a else 0
    print(seed(a[0], int(a[1]), a[2], a[3], many))
