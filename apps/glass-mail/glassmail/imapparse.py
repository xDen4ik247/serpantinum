"""Small IMAP helpers on top of imaplib: parsing FETCH / LIST responses (s-expressions with
literals), BODYSTRUCTURE walking, and modified UTF-7 folder names (RFC 3501 §5.1.3)."""
import base64
import re

# ------------------------------------------------------------------ s-expressions

_ATOM_END = set(b' (){"\r\n')


class Literal(bytes):
    """A {n} literal: always raw bytes, never an atom (so b'NIL' as content stays b'NIL')."""


def _join(data):
    """imaplib gives a FETCH response as a list mixing bytes and (prefix, literal) tuples.
    Glue it into one buffer where every literal is replaced by \x00<index>\x00, and return
    the buffer plus the literal list."""
    buf = bytearray()
    lits = []
    for part in data:
        if isinstance(part, tuple):
            pre, lit = part
            # the prefix ends with "{n}"; drop that and put a placeholder instead
            pre = re.sub(rb'\{\d+\}$', b'', pre)
            buf += pre
            buf += b'\x00%d\x00' % len(lits)
            lits.append(Literal(lit))
        elif part is not None:
            buf += part
    return bytes(buf), lits


def parse_sexp(buf, lits=(), pos=0):
    """Parse one value list from buf starting at pos; returns (list, pos)."""
    out = []
    n = len(buf)
    while pos < n:
        c = buf[pos]
        if c in (0x20, 0x0d, 0x0a):
            pos += 1
        elif c == 0x28:                       # (
            sub, pos = parse_sexp(buf, lits, pos + 1)
            out.append(sub)
        elif c == 0x29:                       # )
            return out, pos + 1
        elif c == 0x22:                       # "quoted"
            pos += 1
            s = bytearray()
            while pos < n and buf[pos] != 0x22:
                if buf[pos] == 0x5c and pos + 1 < n:
                    pos += 1
                s.append(buf[pos])
                pos += 1
            out.append(Literal(bytes(s)))
            pos += 1
        elif c == 0x00:                       # literal placeholder
            end = buf.index(b'\x00', pos + 1)
            out.append(lits[int(buf[pos + 1:end])])
            pos = end + 1
        elif c == 0x7b:                       # {n} literal inline (rare, imaplib splits them)
            end = buf.index(b'}', pos)
            k = int(buf[pos + 1:end])
            start = buf.index(b'\n', end) + 1
            out.append(Literal(buf[start:start + k]))
            pos = start + k
        else:
            start = pos
            # atoms like BODY[HEADER.FIELDS (FROM TO)]<0> keep their brackets together
            depth = 0
            while pos < n:
                ch = buf[pos]
                if ch == 0x5b:
                    depth += 1
                elif ch == 0x5d:
                    depth -= 1
                elif depth == 0 and ch in _ATOM_END:
                    break
                elif depth > 0 and ch == 0x00:
                    break
                pos += 1
            if pos == start:                  # a stray delimiter: skip it rather than spin
                pos += 1
                continue
            atom = buf[start:pos]
            out.append(None if atom.upper() == b'NIL' else atom)
    return out, pos


_FETCH_RE = re.compile(rb'(\d+) \(')


def parse_fetch(data):
    """FETCH response (imaplib's list) -> list of dicts {b'UID': b'12', b'FLAGS': [...], ...}.
    Keys are upper-case bytes; BODY[...]<n> keys are normalised to drop BODY.PEEK."""
    buf, lits = _join(data)
    out = []
    pos = 0
    while True:
        m = _FETCH_RE.search(buf, pos)
        if not m:
            break
        items, pos = parse_sexp(buf, lits, m.end())
        d = {}
        for i in range(0, len(items) - 1, 2):
            k = items[i]
            if isinstance(k, (bytes, bytearray)) and not isinstance(k, Literal):
                d[bytes(k).upper().replace(b'BODY.PEEK', b'BODY')] = items[i + 1]
        d[b'SEQ'] = m.group(1)
        out.append(d)
    return out


def num(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def text(v):
    if v is None:
        return ''
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).decode('utf-8', 'replace')
    return str(v)


# ------------------------------------------------------------------ LIST

_LIST_RE = re.compile(rb'\((?P<flags>[^)]*)\) (?P<delim>NIL|"(?:\\.|[^"])*") (?P<name>.+)$')


def parse_list(data):
    """LIST / XLIST response lines -> [(flags set, delimiter, decoded name, raw name)]."""
    out = []
    i = 0
    while i < len(data):
        line = data[i]
        name_lit = None
        if isinstance(line, tuple):
            line, name_lit = line
        i += 1
        if not line:
            continue
        m = _LIST_RE.match(line.rstrip() if name_lit is None else line.rstrip() + b' "x"')
        if not m:
            continue
        flags = {f.lower() for f in m.group('flags').decode().split()}
        d = m.group('delim')
        delim = None if d == b'NIL' else d[1:-1].replace(b'\\\\', b'\\').decode()
        if name_lit is not None:
            raw = name_lit
        else:
            raw = m.group('name').strip()
            if raw.startswith(b'"'):
                raw = raw[1:-1].replace(b'\\"', b'"').replace(b'\\\\', b'\\')
        raw = raw.decode('utf-8', 'replace')
        out.append((flags, delim, decode_utf7(raw), raw))
    return out


def quote(name):
    """Quote a mailbox name for a command."""
    return '"' + name.replace('\\', '\\\\').replace('"', '\\"') + '"'


# ------------------------------------------------------------------ modified UTF-7

def decode_utf7(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == '&':
            j = s.find('-', i)
            if j < 0:
                out.append(s[i:])
                break
            if j == i + 1:
                out.append('&')
            else:
                b = s[i + 1:j].replace(',', '/')
                b += '=' * (-len(b) % 4)
                try:
                    out.append(base64.b64decode(b).decode('utf-16-be'))
                except Exception:
                    out.append(s[i:j + 1])
            i = j + 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def encode_utf7(s):
    out = []
    buf = []

    def flush():
        if buf:
            b = base64.b64encode(''.join(buf).encode('utf-16-be')).decode().rstrip('=').replace('/', ',')
            out.append('&' + b + '-')
            buf.clear()
    for c in s:
        if 0x20 <= ord(c) <= 0x7e:
            flush()
            out.append('&-' if c == '&' else c)
        else:
            buf.append(c)
    flush()
    return ''.join(out)


# ------------------------------------------------------------------ BODYSTRUCTURE

def walk_structure(bs, prefix=''):
    """Yield (part number, info dict) for every leaf part of a BODYSTRUCTURE.
    info: type, subtype, params, id, encoding, size, disposition, filename."""
    if not isinstance(bs, list) or not bs:
        return
    if isinstance(bs[0], list):              # multipart: (part)(part)... "subtype" ...
        i = 0
        n = 1
        while i < len(bs) and isinstance(bs[i], list):
            yield from walk_structure(bs[i], (prefix + '.' if prefix else '') + str(n))
            i += 1
            n += 1
        return
    t = text(bs[0]).lower()
    st = text(bs[1]).lower() if len(bs) > 1 else ''
    params = _pairs(bs[2]) if len(bs) > 2 else {}
    info = {
        'type': t, 'subtype': st, 'params': params,
        'id': text(bs[3]).strip('<>') if len(bs) > 3 and bs[3] else '',
        'encoding': text(bs[5]).lower() if len(bs) > 5 else '7bit',
        'size': num(bs[6]) if len(bs) > 6 else 0,
        'disposition': '', 'filename': params.get('name', ''),
    }
    # extension data: the disposition sits after md5; position depends on the type
    ext = 7
    if t == 'text':
        ext = 8
    elif t == 'message' and st == 'rfc822':
        ext = 10
    disp = bs[ext + 1] if len(bs) > ext + 1 else None
    if isinstance(disp, list) and disp:
        info['disposition'] = text(disp[0]).lower()
        dp = _pairs(disp[1]) if len(disp) > 1 else {}
        if dp.get('filename'):
            info['filename'] = dp['filename']
    if info['filename']:
        from email.header import decode_header, make_header
        try:
            info['filename'] = str(make_header(decode_header(info['filename'])))
        except Exception:
            pass
    yield (prefix or '1'), info


def _pairs(v):
    out = {}
    if isinstance(v, list):
        for i in range(0, len(v) - 1, 2):
            out[text(v[i]).lower()] = text(v[i + 1])
    return out


def summarize_structure(bs):
    """-> (text part number, its info, has_attachments) for the snippet / list icon."""
    plain = html = None
    att = False
    for num_, info in walk_structure(bs):
        is_att = info['disposition'] == 'attachment' or (
            info['filename'] and info['type'] not in ('text',) and info['disposition'] != 'inline')
        if is_att or (info['type'] not in ('text', 'multipart') and info['disposition'] != 'inline' and info['filename']):
            att = True
            continue
        if info['type'] == 'text' and info['subtype'] == 'plain' and plain is None:
            plain = (num_, info)
        elif info['type'] == 'text' and info['subtype'] == 'html' and html is None:
            html = (num_, info)
    pick = plain or html
    return (pick[0], pick[1], att) if pick else (None, None, att)
