#!/usr/bin/env python3
"""Corpus for the MIME parity test: gen_mime.py OUT.jsonl
Cached bodies (local only), the test seed's messages, and a few thousand generated messages that
exercise charsets, transfer encodings, nested multiparts, attached mail, inline images, RFC 2047 /
2231 names, odd dates and folded headers. Every input is a whole message (base64)."""
import base64, email.utils, glob, json, os, random, sys
from email.message import EmailMessage
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email.mime.image import MIMEImage
from email.mime.message import MIMEMessage
from email import encoders
from email.header import Header
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

out = open(sys.argv[1], "w", encoding="utf-8")
R = random.Random(9)
counts = {"cache": 0, "seed": 0, "gen": 0}


def b(x):
    return base64.b64encode(x).decode()


def put(raw, src):
    out.write(json.dumps({"fn": "view", "raw": b(raw)}) + "\n")
    out.write(json.dumps({"fn": "text_of", "raw": b(raw)}) + "\n")
    hdr = raw.split(b"\r\n\r\n", 1)[0] if b"\r\n\r\n" in raw else raw.split(b"\n\n", 1)[0]
    out.write(json.dumps({"fn": "header_row", "hdr": b(hdr + b"\r\n\r\n"), "flags": R.sample(["\\Seen", "\\Flagged", "\\Answered", "\\Draft", "$Label"], R.randint(0, 3)),
                          "idate": 1791800000.0 + R.randint(0, 900000)}) + "\n")
    counts[src] += 1


for p in sorted(glob.glob(os.path.expanduser("~/.cache/glass-mail/bodies/**/*.eml"), recursive=True)):
    put(open(p, "rb").read(), "cache")

from tests import seed
import imaplib
seen = []
class Fake:
    def append(self, box, flags, date, data):
        seen.append(data)
        return ("OK", [b""])
    def __getattr__(self, k):
        return lambda *a, **kw: ("OK", [b""])
imaplib.IMAP4_SSL = lambda *a, **kw: Fake()
seed.seed("x", 1, "u", "p", many=30)
for raw in seen:
    put(bytes(raw), "seed")

NAMES = ["Mika Aalto", "Иван Смирнов", "田中 空", "O'Brien, Pat", "Tomás Ruiz", "", "Support Team", "\"Quoted\" Name", "Zoë (Work)"]
SUBJ = ["Hello", "Привет, как дела?", "会議の件", "Re: Fwd: Quarterly report 2026 — final version with all the numbers and a very long tail that will need folding",
        "Тест =?utf-8?q?not encoded?=", "Ünïcödé ✓", "", "Your code is 482913", "Invoice #9981"]
CHARSETS = ["utf-8", "koi8-r", "windows-1251", "iso-8859-1", "us-ascii", "shift_jis", "iso-2022-jp", "iso-8859-5", "cp1252"]
TEXTS = ["Hi!\n\nSee the plan below.\n> quoted line\n> another\n\nBye", "Привет!\nЭто тестовое письмо с кириллицей.\n-- \nподпись",
         "日本語のメールです。\nよろしくお願いします。", "Plain ascii text with a link https://ex.example/path?a=1&b=2 and more.",
         "Line one\r\nLine two\r\n\r\nLine four", "x" * 300, "Your login code: 62519. Do not share."]
HTMLS = ["<html><head><style>p{}</style></head><body><h1>Title</h1><p>Hello <b>world</b> <a href='https://ok.example'>link</a></p>"
         "<img src='cid:logo@x' width=48><img src='https://img.example/hero.jpg'><img src='https://t.example/p.gif' width=1 height=1></body></html>",
         "<div style='display:none'>preheader</div><table><tr><td>A</td><td>B</td></tr></table><ul><li>one<li>two</ul>",
         "<p>Привет, <i>мир</i>!</p><blockquote>quoted</blockquote><pre>code  here</pre>", "<p>short</p>",
         "<html><body>" + "<p>para</p>" * 40 + "</body></html>"]


def addr():
    n = R.choice(NAMES)
    a = R.choice(["mika@example.org", "ivan@example.ru", "sora@example.jp", "noreply@service.example", "a.b+tag@sub.example.com"])
    return email.utils.formataddr((n, a)) if n and R.random() < 0.8 else a


def date():
    return R.choice([email.utils.formatdate(1791000000 + R.randint(0, 9000000), localtime=R.random() < 0.5),
                     "Mon, 12 Oct 2026 10:00:00 -0000", "12 Oct 2026 10:00:00", "Mon, 12 Oct 2026 10:00:00 GMT",
                     "Mon, 12 Oct 2026 10:00:00 +0530 (IST)", "garbage date", "Tue, 13 Oct 2026 01:02:03 EST"])


def headers(m):
    m["From"] = addr()
    m["To"] = ", ".join(addr() for _ in range(R.randint(1, 3)))
    if R.random() < 0.4:
        m["Cc"] = addr()
    if R.random() < 0.3:
        m["Reply-To"] = addr()
    s = R.choice(SUBJ)
    m["Subject"] = Header(s, "utf-8").encode() if (R.random() < 0.5 and not s.isascii()) else s
    m["Date"] = date()
    m["Message-ID"] = f"<{R.randint(1, 10**9)}@gen.example>"
    if R.random() < 0.4:
        m["In-Reply-To"] = "<parent@gen.example>"
        m["References"] = "<root@gen.example>\r\n <parent@gen.example>"
    if R.random() < 0.3:
        m["List-Unsubscribe"] = "<https://u.example/unsub?x=1>, <mailto:unsub@u.example>"
        m["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"


def text_part(sub="plain"):
    cs = R.choice(CHARSETS)
    body = R.choice(HTMLS if sub == "html" else TEXTS)
    try:
        body.encode(cs)
    except (UnicodeEncodeError, LookupError):
        cs = "utf-8"
    p = MIMEText(body, sub, cs)
    if R.random() < 0.3:
        del p["Content-Transfer-Encoding"]
        enc = R.choice(["base64", "quoted-printable", "8bit"])
        data = body.encode(cs)
        if enc == "base64":
            p.set_payload(base64.encodebytes(data).decode())
        elif enc == "quoted-printable":
            import quopri
            p.set_payload(quopri.encodestring(data).decode("ascii"))
        else:
            p.set_payload(data.decode("ascii", "surrogateescape"))
        p["Content-Transfer-Encoding"] = enc
    return p


def attachment():
    kind = R.choice(["pdf", "png", "txt", "ics", "docx", "noname", "rfc2231"])
    if kind == "png":
        p = MIMEImage(seed.PNG, "png")
        if R.random() < 0.5:
            p["Content-ID"] = "<logo@x>"
        else:
            p.add_header("Content-Disposition", "attachment", filename="picture.png")
        return p
    p = MIMEBase(*{"pdf": ("application", "pdf"), "txt": ("text", "plain"), "ics": ("text", "calendar"),
                   "docx": ("application", "vnd.openxmlformats-officedocument.wordprocessingml.document"),
                   "noname": ("application", "octet-stream"), "rfc2231": ("application", "pdf")}[kind])
    p.set_payload(os.urandom(R.randint(10, 2000)) if kind not in ("txt", "ics") else b"BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
    encoders.encode_base64(p)
    if kind == "rfc2231":
        p.add_header("Content-Disposition", "attachment", filename=("utf-8", "", "Договор.pdf"))
    elif kind != "noname":
        p.add_header("Content-Disposition", R.choice(["attachment", "inline"]), filename=f"file.{kind}")
    return p


def message(depth=0):
    shape = R.choice(["plain", "html", "alt", "mixed", "related", "fwd"] if depth == 0 else ["plain", "alt"])
    if shape == "plain":
        m = text_part("plain")
    elif shape == "html":
        m = text_part("html")
    elif shape == "alt":
        m = MIMEMultipart("alternative")
        m.attach(text_part("plain"))
        m.attach(text_part("html"))
    elif shape == "related":
        m = MIMEMultipart("related")
        m.attach(text_part("html"))
        img = MIMEImage(seed.PNG, "png")
        img["Content-ID"] = "<logo@x>"
        m.attach(img)
    elif shape == "mixed":
        m = MIMEMultipart("mixed")
        m.attach(message(1) if R.random() < 0.5 else text_part(R.choice(["plain", "html"])))
        for _ in range(R.randint(1, 3)):
            m.attach(attachment())
    else:
        m = MIMEMultipart("mixed")
        m.attach(text_part("plain"))
        inner = message(1)
        headers(inner)
        m.attach(MIMEMessage(inner))
    return m


for i in range(2500):
    m = message()
    headers(m)
    raw = m.as_bytes()
    if R.random() < 0.5:
        raw = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    put(raw, "gen")

# partial text parts (snippets): cut at 3 KB like the FETCH
for i in range(1500):
    cs = R.choice(CHARSETS)
    body = R.choice(TEXTS + HTMLS) * R.randint(1, 20)
    try:
        data = body.encode(cs)
    except (UnicodeEncodeError, LookupError):
        cs, data = "utf-8", body.encode()
    enc = R.choice(["7bit", "base64", "quoted-printable", "8bit"])
    if enc == "base64":
        data = base64.encodebytes(data)
    elif enc == "quoted-printable":
        import quopri
        data = quopri.encodestring(data)
    data = data[:R.randint(10, 3072)]
    info = {"encoding": enc, "params": {"charset": cs} if R.random() < 0.9 else {}, "subtype": "html" if "<" in body[:5] else "plain"}
    out.write(json.dumps({"fn": "part_text", "data": b(data), "info": info}) + "\n")
    out.write(json.dumps({"fn": "snippet", "data": b(data), "info": info}) + "\n")

for t in ["Ann <a@x.org>, b@y.org; c@z.org", "bad, @nope, x@y", "\"Smith, J\" <j@s.example>", "Иван <ivan@example.ru>", "", "a@b.c; d@e.f",
          "name only", "<only@angle.example>", "x@y.z, x@y.z"]:
    out.write(json.dumps({"fn": "parse_rcpt", "text": t}) + "\n")
for s, p in [("Re: a", "Re"), ("a", "Re"), ("AW: x", "Re"), ("Fwd: a", "Fwd"), ("fw: b", "Fwd"), ("Ответ: x", "Re"), ("a", "Fwd"), ("", "Re")]:
    out.write(json.dumps({"fn": "reply_subject", "s": s, "prefix": p}) + "\n")
for body in TEXTS + ["> > nested\n>> deeper\nback", "a <b> & c https://x.example/q?a=1&b=2."]:
    out.write(json.dumps({"fn": "text_to_html", "body": body}) + "\n")
print(json.dumps(counts), file=sys.stderr)
