#!/usr/bin/env python3
"""Build a corpus of inputs for the pure functions (reader, codes): gen_pure.py OUT.jsonl
Sources: cached mail bodies (local only, never committed), the test seed's messages, the HTML
documentation installed on this machine, and seeded random HTML / code-mail fuzz."""
import email, email.policy, glob, json, os, random, sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
from glassmail import mime

out = open(sys.argv[1], "w", encoding="utf-8")
n = {"cache": 0, "seed": 0, "doc": 0, "fuzz": 0, "codes": 0}


def put(kind, **kw):
    out.write(json.dumps(dict(fn=kind, **kw), ensure_ascii=False) + "\n")


def mail(raw, src):
    try:
        msg = mime.parse(raw)
        plain, htm, _, _ = mime.walk_parts(msg)
    except Exception:
        return
    if htm:
        put("html_blocks", src=htm)
        put("html_to_text", src=htm)
    if plain:
        put("text_blocks", src=plain)
    put("codes", subject=mime.dec(msg.get("Subject")), text=mime.text_of(raw))
    n[src] += 1


for p in sorted(glob.glob(os.path.expanduser("~/.cache/glass-mail/bodies/**/*.eml"), recursive=True)):
    mail(open(p, "rb").read(), "cache")

# the Dovecot test seed (made-up mail)
from tests import seed
seen = []
real_append = None
class Fake:
    def append(self, box, flags, date, data):
        seen.append(data)
        return ("OK", [b""])
    def __getattr__(self, k):
        return lambda *a, **kw: ("OK", [b""])
try:
    import imaplib
    orig = imaplib.IMAP4_SSL
    imaplib.IMAP4_SSL = lambda *a, **kw: Fake()
    seed.seed("x", 1, "u", "p", many=40)
except Exception as e:
    print("seed:", e, file=sys.stderr)
for raw in seen:
    mail(raw if isinstance(raw, bytes) else bytes(raw), "seed")

docs = sorted(glob.glob("/usr/share/doc/**/*.html", recursive=True))
random.Random(3).shuffle(docs)
for p in docs[:2500]:
    try:
        s = open(p, encoding="utf-8", errors="replace").read()[:200000]
    except OSError:
        continue
    put("html_blocks", src=s)
    if n["doc"] % 4 == 0:
        put("html_to_text", src=s)
    n["doc"] += 1

R = random.Random(42)
TAGS = ("p div span a img br hr ul ol li table tr td th h1 h2 h3 h4 h5 h6 b i em strong code pre blockquote script style title "
        "textarea iframe svg noscript center small big sub sup s u font head body html meta link input select option form button "
        "dl dt dd figure figcaption tbody thead tt kbd del ins strike section article header footer nav main aside xmp").split()
WS = [" ", "  ", "\t", "\n", "\r\n", "\x0c", "\x0b", "\x1c", "​", "\xa0", " ", "‌", "\xad", "﻿", "　"]
WORDS = ("hello world Привет мир 日本語 code 123456 G-482913 your verification code is 7391 https://ex.example/a?b=1&c=2 "
         "mailto:a@b.c (x) [y] ok, done. visit www.site.example now! 2026 г. 12 Oct ₽ $5 #9981").split()
ENTS = ["&amp;", "&amp", "&nbsp;", "&#65;", "&#x42;", "&#x1F600;", "&#0;", "&#128;", "&#xD800;", "&#99999999;", "&notin;", "&notit;",
        "&bogus;", "&", "&lt;b&gt;", "&#", "&#x", "&quot;", "&AMP", "&copy", "&copyx"]


def text():
    return "".join(R.choice([R.choice(WORDS), R.choice(WS), R.choice(ENTS), R.choice(WORDS) + " "]) for _ in range(R.randint(0, 8)))


def attr():
    name = R.choice(["style", "href", "src", "width", "height", "alt", "class", "id", "STYLE", "data-x", "x", "=bad", "a b"])
    vals = {"style": ["display:none", "display: none", "visibility:hidden", "max-height:0;overflow:hidden", "max-height: 0; overflow: hidden",
                      "width:1px;height:1px", "color:red", "width: 600px", "height:2px"],
            "href": ["https://ok.example/x", "javascript:bad()", "mailto:a@b.c", "/rel", " https://sp.example ", "tel:+123", "HTTP://UP.EX"],
            "src": ["https://img.example/a.png", "cid:logo@x", "data:image/png;base64,iVBOR", "/rel.png", "http://t.example/p.gif", ""],
            "width": ["1", "600", "100%", " 3px", "x", "0", "4"], "height": ["1", "300", "2", "auto"]}
    v = R.choice(vals.get(name.lower(), [text(), "plain", "a&amp;b", "x&copy=y"]))
    q = R.choice(['"', "'", "", '"', "'", "UNCLOSED"])
    if q == "UNCLOSED":
        return f' {name}="{v}' if R.random() < 0.2 else f' {name}={v}'
    if R.random() < 0.1:
        return f" {name}"
    return f" {name}{R.choice(['=', ' = ', '='])}{q}{v}{q}"


def doc(depth=0):
    parts = []
    for _ in range(R.randint(1, 7)):
        r = R.random()
        if r < 0.35:
            parts.append(text())
        elif r < 0.75 and depth < 6:
            t = R.choice(TAGS)
            T = t.upper() if R.random() < 0.1 else t
            attrs = "".join(attr() for _ in range(R.randint(0, 3)))
            if R.random() < 0.08:
                parts.append(f"<{T}{attrs}/>")
                continue
            inner = doc(depth + 1)
            close = R.choice([f"</{T}>", f"</{t}>", "", f"</{t} >", f"</{t}\n>"]) if R.random() < 0.9 else ""
            parts.append(f"<{T}{attrs}>{inner}{close}")
        else:
            parts.append(R.choice(["<!-- c -->", "<!--->", "<!-- x --!>", "<!---->", "<!doctype html>", "<?pi x?>", "<![CDATA[x<y]]>",
                                   "<", "</>", "</ x>", "</p>", "</div>", "<3", "a < b", "&", "<!x>", "</b", "<br/>", "<hr>", "<li>", "</li>",
                                   "<img src=https://i.example/a.png alt=A>", "<img src='cid:x'>", "<a href=https://u.example>link</a>"]))
    return "".join(parts)


for i in range(6000):
    d = doc()
    if R.random() < 0.05:
        d += R.choice(["<div class=", "<!-- open", "&am", "</", "<a href='x", "<p"])
    put("html_blocks", src=d)
    if i % 3 == 0:
        put("html_to_text", src=d)
    if i % 2 == 0:
        put("text_blocks", src="\n".join(R.choice(["> quoted " + text(), ">>deep", "> ", "plain " + text(), "", "   indented", "\t>tab", text()])
                                          for _ in range(R.randint(1, 9))))
    n["fuzz"] += 1

SUBJ = ["Your code", "Sign in to Telegram", "Код подтверждения", "Order #123456 shipped", "Verify your email", "Invoice 2026",
        "Votre code", "Ваш заказ", "Login attempt", "Weekly digest", "認証コード", "Security alert", ""]
SNIP = ["Your login code: {c}. Do not share it.", "{c} is your Google verification code", "Код для входа: {c}", "Order number {c}",
        "Total: {c} руб", "Call +7 (999) {c}", "Use {c} to sign in", "Promo code {c} gives 10% off", "Meeting on 12 Oct {c}",
        "Your one-time password is {c}.", "Код подтверждения — {c}", "PIN: {c}", "Tracking: {c}", "{c}", "Year {c}", "access code {c} expires"]
for i in range(4000):
    c = R.choice([str(R.randint(1000, 99999999)), f"{R.randint(100, 999)} {R.randint(100, 999)}", f"{R.randint(100, 999)}-{R.randint(100, 999)}",
                  f"G-{R.randint(10000, 999999)}", "AB12CD34", "X9Y8Z7", "2026", "1111", "0000", "12.50", "3:15"])
    t = " ".join(R.choice(SNIP).format(c=c) if R.random() < 0.5 else text() for _ in range(R.randint(1, 4)))
    put("codes", subject=R.choice(SUBJ).format(c=c), text=t)
    n["codes"] += 1
print(json.dumps(n), file=sys.stderr)
