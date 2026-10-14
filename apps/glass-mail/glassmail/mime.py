"""Reading and writing messages: headers -> list rows, a full message -> what the reader pane
shows, and replies / forwards / new mail -> an EmailMessage ready for SMTP."""
import base64
import email
import email.policy
import email.utils
import html
import mimetypes
import os
import re
import time
from email.header import decode_header, make_header
from email.message import EmailMessage

from . import reader

POLICY = email.policy.default.clone(raise_on_defect=False)


def dec(v):
    """Decode an RFC 2047 header value to str, forgiving broken charsets."""
    if v is None:
        return ''
    if isinstance(v, bytes):
        v = v.decode('utf-8', 'replace')
    try:
        return str(make_header(decode_header(v))).strip()
    except Exception:
        return v.strip()


def addresses(v):
    """-> [(name, addr)]"""
    if not v:
        return []
    out = []
    for name, addr in email.utils.getaddresses([dec(v) if '=?' in str(v) else str(v)]):
        if addr or name:
            out.append((dec(name), addr))
    return out


def parse_date(v):
    if not v:
        return 0
    try:
        d = email.utils.parsedate_to_datetime(str(v))
        return d.timestamp()
    except Exception:
        return 0


def header_row(raw_headers, uid, flags, internaldate=0, size=0, part='', att=False, thrid=''):
    """Header bytes from BODY[HEADER.FIELDS (...)] -> a messages row."""
    msg = email.message_from_bytes(raw_headers or b'', policy=email.policy.compat32)
    frm = addresses(msg.get('From'))
    rcpt = addresses(msg.get('To'))
    cc = addresses(msg.get('Cc'))
    refs = ' '.join(re.findall(r'<[^>]+>', (msg.get('References') or '') + ' ' + (msg.get('In-Reply-To') or '')))
    flags = {f.lower() for f in flags}
    date = parse_date(msg.get('Date')) or internaldate or time.time()
    # a Date header from the future (broken clocks) sorts by arrival instead
    if internaldate and date > internaldate + 86400:
        date = internaldate
    return {
        'uid': uid,
        'msgid': (msg.get('Message-ID') or '').strip(),
        'thrid': thrid,
        'date': date,
        'from_name': frm[0][0] if frm else '',
        'from_addr': frm[0][1] if frm else '',
        'rcpt': [list(x) for x in rcpt],
        'cc': [list(x) for x in cc],
        'subject': dec(msg.get('Subject')) or '',
        'snippet': '',
        'seen': '\\seen' in flags,
        'flagged': '\\flagged' in flags,
        'answered': '\\answered' in flags,
        'draft': '\\draft' in flags,
        'att': att,
        'size': size,
        'refs': refs,
        'unsub': (msg.get('List-Unsubscribe') or '').strip(),
        'part': part or '',
    }


def snippet_from_part(data, info):
    """The first bytes of the text part (BODY[n]<0.2048>) -> a one-line preview."""
    return snippet_of_text(part_text(data, info))


def snippet_of_text(txt):
    # drop quoted history and signatures from the preview
    lines = []
    for ln in txt.splitlines():
        s = ln.strip()
        if s.startswith('>'):
            continue
        if s in ('--', '-- '):
            break
        lines.append(s)
    return reader.snippet_of(' '.join(lines))


def part_text(data, info):
    """Decoded text of a (partial) body part; HTML becomes plain text."""
    enc = (info or {}).get('encoding', '7bit')
    charset = ((info or {}).get('params') or {}).get('charset') or 'utf-8'
    raw = data or b''
    try:
        if enc == 'base64':
            clean = re.sub(rb'[^A-Za-z0-9+/=]', b'', raw)
            raw = base64.b64decode(clean[:len(clean) // 4 * 4])     # the cut may end mid-quantum
        elif enc == 'quoted-printable':
            import quopri
            raw = quopri.decodestring(raw)
    except Exception:
        pass
    try:
        txt = raw.decode(charset, 'replace')
    except LookupError:
        txt = raw.decode('utf-8', 'replace')
    if info and info.get('subtype') == 'html':
        txt = reader.html_to_text(txt)
    return txt


def text_of(raw):
    """The readable text of a whole message (for AI and code detection): the plain part, or the
    HTML as text when the plain part is missing or just says "see the HTML version"."""
    plain, htm, _, _ = walk_parts(parse(raw))
    if htm and (not plain or len(plain.strip()) < 200):
        return reader.html_to_text(htm)
    return plain or ''


# ------------------------------------------------------------------ reading


def parse(raw):
    return email.message_from_bytes(raw, policy=POLICY)


def _payload_text(part):
    try:
        return part.get_content()
    except Exception:
        data = part.get_payload(decode=True) or b''
        cs = part.get_content_charset() or 'utf-8'
        try:
            return data.decode(cs, 'replace')
        except LookupError:
            return data.decode('utf-8', 'replace')


def walk_parts(msg):
    """-> (plain text, html text, inline images {cid: part}, attachments [part])."""
    plain = htm = None
    cids = {}
    atts = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        ctype = part.get_content_type()
        disp = (part.get_content_disposition() or '').lower()
        fname = part.get_filename()
        cid = (part.get('Content-ID') or '').strip().strip('<>')
        if ctype == 'message/rfc822' or (disp == 'attachment') or (fname and not ctype.startswith('text/') and not (cid and ctype.startswith('image/'))):
            atts.append(part)
            continue
        if ctype.startswith('image/') and cid:
            cids[cid] = part
            if disp == 'attachment':
                atts.append(part)
            continue
        if ctype == 'text/plain' and plain is None:
            plain = _payload_text(part)
        elif ctype == 'text/html' and htm is None:
            htm = _payload_text(part)
        elif ctype in ('text/calendar',) or (fname and ctype.startswith('text/')):
            atts.append(part)
        elif not ctype.startswith('text/'):
            atts.append(part)
    return plain, htm, cids, atts


def attachment_info(part, i):
    fname = part.get_filename() or ''
    ctype = part.get_content_type()
    if ctype == 'message/rfc822' and not fname:
        inner = part.get_payload(0) if part.is_multipart() else None
        fname = (dec(inner.get('Subject')) if inner is not None else '') or 'message'
        fname += '.eml'
    if not fname:
        fname = 'attachment-%d%s' % (i + 1, mimetypes.guess_extension(ctype) or '')
    try:
        size = len(part.get_payload(decode=True) or b'') if ctype != 'message/rfc822' else len(part.as_bytes())
    except Exception:
        size = 0
    return {'i': i, 'name': fname, 'type': ctype, 'size': size, 'kind': kind_of(ctype, fname)}


def kind_of(ctype, name):
    ext = os.path.splitext(name.lower())[1]
    if ctype.startswith('image/'):
        return 'image'
    if ctype == 'application/pdf' or ext == '.pdf':
        return 'pdf'
    if ext in ('.zip', '.rar', '.7z', '.tar', '.gz', '.xz', '.zst', '.bz2'):
        return 'archive'
    if ext in ('.doc', '.docx', '.odt', '.rtf', '.pages'):
        return 'doc'
    if ext in ('.xls', '.xlsx', '.ods', '.csv', '.numbers'):
        return 'sheet'
    if ext in ('.ppt', '.pptx', '.odp', '.key'):
        return 'slides'
    if ctype.startswith('audio/'):
        return 'audio'
    if ctype.startswith('video/'):
        return 'video'
    if ctype == 'text/calendar' or ext == '.ics':
        return 'calendar'
    if ctype == 'message/rfc822':
        return 'mail'
    return 'file'


def attachment_bytes(msg, i):
    _, _, _, atts = walk_parts(msg)
    if i < 0 or i >= len(atts):
        return None, None
    part = atts[i]
    info = attachment_info(part, i)
    if part.get_content_type() == 'message/rfc822':
        inner = part.get_payload(0) if part.is_multipart() else None
        return info['name'], (inner.as_bytes() if inner is not None else part.get_payload(decode=True) or b'')
    return info['name'], part.get_payload(decode=True) or b''


def view(raw, colors=None):
    """Full message bytes -> the reader pane's data (blocks are QML-ready)."""
    colors = colors or {}
    lc, qc, cb = colors.get('link', '#80d4db'), colors.get('quote', '#899393'), colors.get('code', '#252b2c')
    msg = parse(raw)
    plain, htm, cids, atts = walk_parts(msg)
    if htm and htm.strip():
        blocks = reader.html_blocks(htm, lc, qc, cb)
        if not blocks and plain:
            blocks = reader.text_blocks(plain, lc, qc)
        kind = 'html'
    else:
        blocks = reader.text_blocks(plain or '', lc, qc)
        kind = 'text'
    remote = 0
    for b in blocks:
        if b['t'] == 'img':
            if b['src'].lower().startswith('cid:'):
                b['cid'] = b['src'][4:].strip('<>')
                b['src'] = ''
            elif b['src'].lower().startswith('data:'):
                b['data'] = b['src']
                b['src'] = ''
            else:
                remote += 1
    used = {b.get('cid') for b in blocks if b.get('cid')}
    # inline images the HTML never referenced (Apple Mail, phones) are shown under the text
    for cid, part in cids.items():
        if cid not in used and not htm:
            blocks.append({'t': 'img', 'src': '', 'cid': cid, 'alt': part.get_filename() or '', 'href': '', 'w': 0, 'h': 0})
    frm = addresses(msg.get('From'))
    return {
        'subject': dec(msg.get('Subject')),
        'from': [list(x) for x in frm],
        'to': [list(x) for x in addresses(msg.get('To'))],
        'cc': [list(x) for x in addresses(msg.get('Cc'))],
        'replyTo': [list(x) for x in addresses(msg.get('Reply-To'))],
        'date': parse_date(msg.get('Date')),
        'msgid': (msg.get('Message-ID') or '').strip(),
        'refs': (msg.get('References') or '').strip(),
        'unsub': (msg.get('List-Unsubscribe') or '').strip(),
        'unsubPost': (msg.get('List-Unsubscribe-Post') or '').strip(),
        'blocks': blocks,
        'kind': kind,
        'remote': remote,
        'attachments': [attachment_info(p, i) for i, p in enumerate(atts)],
        'plain': plain if plain is not None else (reader.html_to_text(htm) if htm else ''),
        'html': htm or '',
    }


def cid_bytes(raw, cid):
    msg = parse(raw)
    _, _, cids, _ = walk_parts(msg)
    part = cids.get(cid)
    if part is None:
        return None, None
    return part.get_content_type(), part.get_payload(decode=True)


def original_html(raw, allow_remote=False):
    """The message as a standalone, script-free HTML page (Open in browser). cid: images are
    inlined as data: URIs; remote loads are blocked by a CSP unless allowed."""
    msg = parse(raw)
    plain, htm, cids, _ = walk_parts(msg)
    if not htm:
        htm = '<pre style="white-space:pre-wrap;font-family:sans-serif">' + html.escape(plain or '') + '</pre>'

    def sub(m):
        cid = m.group(2)
        part = cids.get(cid)
        if part is None:
            return m.group(0)
        data = base64.b64encode(part.get_payload(decode=True) or b'').decode()
        return f'{m.group(1)}data:{part.get_content_type()};base64,{data}'
    htm = re.sub(r'''(src\s*=\s*["']?)cid:<?([^"'\s>]+?)>?(?=["'\s>])''', sub, htm, flags=re.I)
    img = "img-src data: https: http:;" if allow_remote else "img-src data:;"
    csp = f"default-src 'none'; {img} style-src 'unsafe-inline' https:; font-src https: data:;"
    head = (f'<meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="{csp}">'
            f'<title>{html.escape(dec(msg.get("Subject")))}</title>')
    htm = re.sub(r'<script\b.*?</script>', '', htm, flags=re.I | re.S)
    if re.search(r'<head[^>]*>', htm, re.I):
        return re.sub(r'(<head[^>]*>)', lambda m: m.group(1) + head, htm, count=1, flags=re.I)
    return '<!doctype html><html><head>' + head + '</head><body>' + htm + '</body></html>'


# ------------------------------------------------------------------ writing


def fmt_addr(name, addr):
    return email.utils.formataddr((name, addr)) if name else addr


def parse_rcpt(text):
    """'Ann <a@x>, b@y; c@z' -> [(name, addr)] (only things that look like addresses)."""
    out = []
    for name, addr in email.utils.getaddresses([text.replace(';', ',')]):
        addr = addr.strip()
        if re.match(r'^[^@\s]+@[^@\s]+\.[^@\s]+$', addr):
            out.append((name.strip(), addr))
    return out


def reply_subject(s, prefix):
    s = s or ''
    if re.match(r'^\s*(re|aw|sv|ответ)\s*:', s, re.I) and prefix == 'Re':
        return s
    if re.match(r'^\s*(fwd?|wg|пересл)\s*:', s, re.I) and prefix == 'Fwd':
        return s
    return f'{prefix}: {s}'


def quote_text(v):
    """The quoted history under a reply."""
    when = time.strftime('%a, %d %b %Y at %H:%M', time.localtime(v['date'])) if v.get('date') else ''
    who = fmt_addr(*v['from'][0]) if v.get('from') else 'someone'
    body = (v.get('plain') or '').rstrip()
    quoted = '\n'.join('> ' + ln if ln else '>' for ln in body.split('\n'))
    return f'\n\nOn {when}, {who} wrote:\n{quoted}\n'


def forward_text(v):
    lines = ['', '', '---------- Forwarded message ---------']
    if v.get('from'):
        lines.append('From: ' + fmt_addr(*v['from'][0]))
    if v.get('date'):
        lines.append('Date: ' + time.strftime('%a, %d %b %Y at %H:%M', time.localtime(v['date'])))
    lines.append('Subject: ' + (v.get('subject') or ''))
    if v.get('to'):
        lines.append('To: ' + ', '.join(fmt_addr(*x) for x in v['to']))
    if v.get('cc'):
        lines.append('Cc: ' + ', '.join(fmt_addr(*x) for x in v['cc']))
    lines.append('')
    lines.append((v.get('plain') or '').rstrip())
    return '\n'.join(lines) + '\n'


def text_to_html(body):
    """Plain text compose body -> a simple HTML alternative (links, quotes)."""
    out = []
    quote = 0
    for ln in body.split('\n'):
        depth = len(re.match(r'^(>\s?)*', ln).group(0).replace(' ', ''))
        txt = re.sub(r'^(>\s?)+', '', ln) if depth else ln
        while quote < depth:
            out.append('<blockquote style="margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex">')
            quote += 1
        while quote > depth:
            out.append('</blockquote>')
            quote -= 1
        e = html.escape(txt)
        e = reader.URL_RE.sub(lambda m: f'<a href="{m.group(1)}">{m.group(1)}</a>', e)
        out.append(e + '<br>')
    out.extend(['</blockquote>'] * quote)
    return '<div dir="auto">' + '\n'.join(out) + '</div>'


def build(acc, d, attachments=(), forwarded=()):
    """d: {to, cc, bcc, subject, body, inReplyTo, refs}; attachments: [path];
    forwarded: [(filename, ctype, bytes)] (a forward's original attachments)."""
    m = EmailMessage(policy=email.policy.SMTP)
    m['From'] = fmt_addr(acc.get('name', ''), acc['email'])
    to = parse_rcpt(d.get('to', ''))
    cc = parse_rcpt(d.get('cc', ''))
    bcc = parse_rcpt(d.get('bcc', ''))
    if to:
        m['To'] = ', '.join(fmt_addr(*x) for x in to)
    if cc:
        m['Cc'] = ', '.join(fmt_addr(*x) for x in cc)
    m['Subject'] = d.get('subject', '')
    m['Date'] = email.utils.formatdate(localtime=True)
    dom = acc['email'].rsplit('@', 1)[-1]
    m['Message-ID'] = email.utils.make_msgid(domain=dom)
    if d.get('inReplyTo'):
        m['In-Reply-To'] = d['inReplyTo']
        refs = (d.get('refs') or '').split()
        if d['inReplyTo'] not in refs:
            refs.append(d['inReplyTo'])
        m['References'] = ' '.join(refs[-20:])
    m['User-Agent'] = 'Glass Mail'
    body = d.get('body', '')
    m.set_content(body)
    m.add_alternative(text_to_html(body), subtype='html')
    for p in attachments:
        ctype, _ = mimetypes.guess_type(p)
        maintype, subtype = (ctype or 'application/octet-stream').split('/', 1)
        with open(p, 'rb') as f:
            m.add_attachment(f.read(), maintype=maintype, subtype=subtype, filename=os.path.basename(p))
    for name, ctype, data in forwarded:
        maintype, subtype = (ctype or 'application/octet-stream').split('/', 1)
        if maintype == 'message':
            maintype, subtype = 'application', 'octet-stream'
        m.add_attachment(data, maintype=maintype, subtype=subtype, filename=name)
    return m, [a for _, a in to + cc + bcc]
