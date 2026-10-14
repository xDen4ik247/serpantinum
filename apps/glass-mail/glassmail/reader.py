"""HTML mail -> a calm "reader view" for the glass window.

QML can't host a browser engine inside quickshell, and newsletters' white boxes would fight
the dark glass anyway, so HTML is rewritten into a small, safe rich-text subset that Qt's
Text renders: paragraphs, headings, bold/italic, links, lists, quotes, code, rules and simple
tables flattened into lines. Images become their own blocks (scaled by QML). Nothing runs:
scripts, styles, forms, iframes and tracking pixels are dropped.

Output: [{"t": "text", "html": ...} | {"t": "img", "src": url-or-cid, "alt", "href", "w", "h"}]
"""
import html
import re
from html.parser import HTMLParser

DROP = {'script', 'style', 'head', 'title', 'noscript', 'iframe', 'object', 'embed', 'form', 'select',
        'option', 'textarea', 'button', 'svg', 'canvas', 'template', 'video', 'audio', 'map', 'meta', 'link'}
BLOCK = {'p', 'div', 'section', 'article', 'header', 'footer', 'main', 'aside', 'nav', 'center', 'table',
         'tbody', 'thead', 'tfoot', 'tr', 'dl', 'dd', 'dt', 'figure', 'figcaption', 'address', 'fieldset', 'body', 'html'}
INLINE_KEEP = {'b': 'b', 'strong': 'b', 'i': 'i', 'em': 'i', 'u': 'u', 'ins': 'u', 's': 's', 'strike': 's',
               'del': 's', 'code': 'code', 'tt': 'code', 'kbd': 'code', 'sub': 'sub', 'sup': 'sup', 'small': 'small', 'big': 'big'}
VOID = {'br', 'img', 'hr', 'input', 'col', 'wbr', 'meta', 'link', 'area', 'source'}
HEAD = {'h1': 1, 'h2': 2, 'h3': 3, 'h4': 4, 'h5': 4, 'h6': 4}
SAFE_LINK = re.compile(r'^(https?:|mailto:|tel:)', re.I)


class _Reader(HTMLParser):
    def __init__(self, link_color, quote_color, code_bg):
        super().__init__(convert_charrefs=True)
        self.blocks = []
        self.cur = []                # pieces of the current text block
        self.drop = 0
        self.stack = []              # open inline tags we emitted
        self.links = []              # open <a> hrefs (None when not emitted)
        self.lists = []              # 'ul' / 'ol' counters
        self.pre = 0
        self.quote = 0
        self.cell = False
        self.link_color = link_color
        self.quote_color = quote_color
        self.code_bg = code_bg
        self.hide = []               # [tag, nesting] of display:none elements being skipped

    # ---- helpers
    def has_text(self):
        return any(p.strip() and p not in ('<br>',) for p in self.cur)

    def br(self):
        if self.cur and self.cur[-1] != '<br>':
            self.cur.append('<br>')

    def para(self):
        """End the current paragraph (blank line), without closing the block."""
        while self.cur and self.cur[-1] == '<br>':
            self.cur.pop()
        if self.has_text():
            self.cur.append('<br>')
            self.cur.append('<br>')

    def flush(self):
        while self.cur and self.cur[-1] == '<br>':
            self.cur.pop()
        if self.has_text():
            body = ''.join(self.cur)
            # close any inline tags still open, so each block is valid on its own
            for t in reversed(self.stack):
                body += f'</{t}>'
            if self.links and self.links[-1]:
                body += '</a>'
            if self.quote:
                body = f'<span style="color:{self.quote_color}">{body}</span>'
            self.blocks.append({'t': 'text', 'html': body, 'q': self.quote})
        self.cur = []
        # re-open inline tags that continue after the block break
        for t in self.stack:
            self.cur.append(f'<{t}>')

    # ---- parser callbacks
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in DROP:
            self.drop += 1
            return
        if self.hide and tag == self.hide[-1][0]:
            self.hide[-1][1] += 1           # same tag nested inside the hidden one
        if self.drop or self.hide:
            return
        style = (a.get('style') or '').replace(' ', '').lower()
        if 'display:none' in style or 'visibility:hidden' in style or ('max-height:0' in style and 'overflow:hidden' in style):
            if tag not in VOID:
                self.hide.append([tag, 1])  # preheaders and other invisible text
            return
        if tag == 'br':
            self.cur.append('<br>')
        elif tag in HEAD:
            self.para()
            self.flush()
            size = {1: 'x-large', 2: 'large', 3: 'medium', 4: 'medium'}[HEAD[tag]]
            self.cur.append(f'<span style="font-size:{size}"><b>')
        elif tag in ('p', 'blockquote', 'pre', 'ul', 'ol', 'table', 'dl', 'figure', 'address', 'center'):
            self.para()
            if tag == 'blockquote':
                self.flush()
                self.quote += 1
            elif tag == 'pre':
                self.pre += 1
                self.cur.append(f'<span style="font-family:monospace; background-color:{self.code_bg}">')
            elif tag in ('ul', 'ol'):
                self.lists.append([tag, 0])
        elif tag == 'li':
            self.br()
            depth = max(0, len(self.lists) - 1)
            if self.lists and self.lists[-1][0] == 'ol':
                self.lists[-1][1] += 1
                mark = f'{self.lists[-1][1]}.'
            else:
                mark = '•'
            self.cur.append('&nbsp;' * (3 + depth * 4) + mark + '&nbsp;&nbsp;')
        elif tag in ('tr', 'dt', 'dd'):
            self.br()
            self.cell = False
        elif tag in ('td', 'th'):
            if self.cell and self.cur and self.cur[-1] not in ('<br>',) and self.has_text():
                self.cur.append('&nbsp;&nbsp; ')
            self.cell = True
            if tag == 'th':
                self.stack.append('b')
                self.cur.append('<b>')
        elif tag in BLOCK:
            self.br()
        elif tag == 'hr':
            self.flush()
            self.blocks.append({'t': 'hr'})
        elif tag == 'a':
            href = (a.get('href') or '').strip()
            if SAFE_LINK.match(href):
                self.links.append(href)
                self.cur.append(f'<a href="{html.escape(href, True)}" style="color:{self.link_color}; text-decoration:none">')
            else:
                self.links.append(None)
        elif tag in INLINE_KEEP:
            t = INLINE_KEEP[tag]
            self.stack.append(t)
            if t == 'code':
                self.cur.append(f'<code style="background-color:{self.code_bg}">')
            elif t in ('small', 'big'):
                self.cur.append(f'<span style="font-size:{"small" if t == "small" else "large"}">')
            else:
                self.cur.append(f'<{t}>')
        elif tag == 'img':
            self.image(a)

    def image(self, a):
        src = (a.get('src') or '').strip()
        w = _px(a.get('width')) or _px(_style(a.get('style'), 'width'))
        h = _px(a.get('height')) or _px(_style(a.get('style'), 'height'))
        if not src or (w and w <= 3) or (h and h <= 3):
            return                                   # tracking pixels / spacers
        if not (src.lower().startswith(('http://', 'https://', 'cid:', 'data:image/'))):
            return
        alt = (a.get('alt') or '').strip()
        href = self.links[-1] if self.links and self.links[-1] else ''
        self.flush()
        self.blocks.append({'t': 'img', 'src': src, 'alt': alt, 'href': href, 'w': w or 0, 'h': h or 0})

    def handle_endtag(self, tag):
        if tag in DROP:
            self.drop = max(0, self.drop - 1)
            return
        if self.hide:
            if tag == self.hide[-1][0]:
                self.hide[-1][1] -= 1
                if not self.hide[-1][1]:
                    self.hide.pop()
            return
        if self.drop:
            return
        if tag in HEAD:
            self.cur.append('</b></span>')
            self.para()
        elif tag == 'blockquote':
            self.flush()
            self.quote = max(0, self.quote - 1)
        elif tag == 'pre':
            if self.pre:
                self.pre -= 1
                self.cur.append('</span>')
            self.para()
        elif tag in ('ul', 'ol'):
            if self.lists:
                self.lists.pop()
            self.para()
        elif tag in ('p', 'table', 'dl', 'figure', 'address', 'center'):
            self.para()
        elif tag in ('th',):
            if self.stack and self.stack[-1] == 'b':
                self.stack.pop()
                self.cur.append('</b>')
        elif tag in BLOCK or tag == 'li':
            self.br()
        elif tag == 'a':
            if self.links:
                if self.links.pop():
                    self.cur.append('</a>')
        elif tag in INLINE_KEEP:
            t = INLINE_KEEP[tag]
            if t in self.stack:
                # close up to and including t (tolerates sloppy nesting)
                while self.stack:
                    x = self.stack.pop()
                    self.cur.append('</span>' if x in ('small', 'big') else f'</{x}>')
                    if x == t:
                        break

    def handle_data(self, data):
        if self.drop or self.hide:
            return
        if self.pre:
            self.cur.append(html.escape(data).replace('\n', '<br>').replace('  ', '&nbsp; '))
            return
        data = re.sub(r'[\s‌​͏­ ﻿]+', ' ', data)
        if not data.strip():
            if self.cur and not self.cur[-1].endswith((' ', '>')):
                self.cur.append(' ')
            return
        if self.cur and self.cur[-1] == '<br>':
            data = data.lstrip()
        self.cur.append(linkify(html.escape(data, False), self.link_color) if not (self.links and self.links[-1]) else html.escape(data, False))


def _px(v):
    if not v:
        return 0
    m = re.match(r'\s*(\d+)', str(v))
    return int(m.group(1)) if m else 0


def _style(style, prop):
    if not style:
        return ''
    m = re.search(r'(?:^|;)\s*' + prop + r'\s*:\s*([^;]+)', style, re.I)
    return m.group(1) if m else ''


URL_RE = re.compile(r'(https?://[^\s<>"\']+[^\s<>"\'.,;:!?)\]])')


def linkify(escaped, color):
    return URL_RE.sub(lambda m: f'<a href="{m.group(1)}" style="color:{color}; text-decoration:none">{m.group(1)}</a>', escaped)


def html_blocks(src, link_color='#80d4db', quote_color='#899393', code_bg='#252b2c'):
    p = _Reader(link_color, quote_color, code_bg)
    try:
        p.feed(src)
        p.close()
    except Exception:
        pass
    p.flush()
    return merge(p.blocks)


def merge(blocks):
    """Glue neighbouring text blocks with the same quote level (fewer Text items to lay out)."""
    out = []
    for b in blocks:
        if out and b['t'] == 'text' and out[-1]['t'] == 'text' and out[-1].get('q') == b.get('q'):
            out[-1] = dict(out[-1], html=out[-1]['html'] + '<br><br>' + b['html'])
        else:
            out.append(b)
    # drop empty trailing rules
    while out and out[-1]['t'] == 'hr':
        out.pop()
    return out


def text_blocks(body, link_color='#80d4db', quote_color='#899393'):
    """Plain-text mail -> blocks; '>' quoted runs become dimmed quote blocks, the rest is linkified."""
    lines = body.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    blocks = []
    cur, q = [], 0
    for line in lines:
        depth = len(re.match(r'^(>\s?)*', line).group(0).replace(' ', ''))
        level = 1 if depth else 0
        stripped = re.sub(r'^(>\s?)+', '', line) if depth else line
        if level != q and cur:
            blocks.append(_text_block(cur, q, link_color, quote_color))
            cur = []
        q = level
        cur.append(stripped)
    if cur:
        blocks.append(_text_block(cur, q, link_color, quote_color))
    return [b for b in blocks if b['html'].replace('<br>', '').strip()]


def _text_block(lines, q, link_color, quote_color):
    while lines and not lines[0].strip():
        lines = lines[1:]
    while lines and not lines[-1].strip():
        lines = lines[:-1]
    out = []
    for ln in lines:
        e = html.escape(ln, False)
        e = re.sub(r'^( +)', lambda m: '&nbsp;' * len(m.group(1)), e)
        out.append(linkify(e, link_color))
    body = '<br>'.join(out)
    if q:
        body = f'<span style="color:{quote_color}">{body}</span>'
    return {'t': 'text', 'html': body, 'q': q}


def html_to_text(src):
    """For snippets, quoting in replies and the plain-text fallback of what we send."""
    blocks = html_blocks(src)
    parts = []
    for b in blocks:
        if b['t'] == 'text':
            t = re.sub(r'<br\s*/?>', '\n', b['html'])
            t = re.sub(r'<[^>]+>', '', t)
            t = html.unescape(t).replace('\xa0', ' ')
            if b.get('q'):
                t = '\n'.join('> ' + ln for ln in t.split('\n'))
            parts.append(t)
        elif b['t'] == 'img' and b.get('alt'):
            parts.append(f'[{b["alt"]}]')
        elif b['t'] == 'hr':
            parts.append('———')
    text = '\n\n'.join(parts)
    return re.sub(r'\n{3,}', '\n\n', text).strip()


def snippet_of(text, n=180):
    t = re.sub(r'\s+', ' ', text).strip()
    return t[:n]
