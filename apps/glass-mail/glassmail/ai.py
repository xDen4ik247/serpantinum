"""Mail AI on the local model (npu-llm: llama.cpp, OpenAI-compatible API on 127.0.0.1:8765).
Nothing leaves the laptop. One request at a time (the server has one slot): what you clicked goes
first, background work (summaries of new mail) waits and is dropped when something newer comes.

Tasks: analyze (summary, to-dos, dates, 3 replies), reply (a full reply from a chosen intent),
write (a draft from a prompt), rewrite (improve / shorten / formal / friendly / fix / translate),
translate (a message), ask (questions over your mail, with sources), brief (catch me up).
"""
import datetime
import itertools
import json
import os
import queue
import re
import threading
import time
import urllib.error
import urllib.request

URL = os.environ.get('GLASS_MAIL_AI_URL', 'http://127.0.0.1:8765/v1').rstrip('/')
MAX_CHARS = 6000          # of mail text per prompt (8k-token context, room for the answer)
LANGS = {'ru': 'Russian', 'en': 'English', 'ja': 'Japanese', 'de': 'German', 'es': 'Spanish', 'fr': 'French'}


def lang_of(text):
    """Very small language guess for prompts: ru / ja / en."""
    t = text[:3000]
    cyr = len(re.findall(r'[а-яёА-ЯЁ]', t))
    kana = len(re.findall(r'[぀-ヿ一-鿿]', t))
    lat = len(re.findall(r'[a-zA-Z]', t))
    if kana > max(20, lat // 3):
        return 'ja'
    if cyr > lat * 0.6:
        return 'ru'
    return 'en'


def clip(text, n=MAX_CHARS):
    text = re.sub(r'\n{3,}', '\n\n', (text or '').strip())
    return text if len(text) <= n else text[:n] + '\n[…]'


def strip_quotes(text):
    """Drop quoted history ("> …", "On … wrote:") so the model reads only the new part."""
    out = []
    for ln in (text or '').split('\n'):
        if re.match(r'^\s*(On .{5,80} wrote:|.{5,80} написал\(а\):|-----Original Message-----|---------- Forwarded)', ln):
            break
        if ln.lstrip().startswith('>'):
            continue
        out.append(ln)
    return '\n'.join(out).strip()


class Cancelled(Exception):
    pass


class AI:
    def __init__(self, emit, log):
        self.emit = emit
        self.log = log
        self.q = queue.PriorityQueue()
        self.seq = itertools.count()
        self.model = None
        self.state = 'idle'            # idle | waking | ready | off
        self.cancelled = set()
        self.current = None
        threading.Thread(target=self.loop, daemon=True, name='ai').start()

    # ---------------------------------------------------------------- queue
    def submit(self, rid, fn, *args, background=False):
        """rid identifies the request for the UI; background work runs last."""
        self.q.put((1 if background else 0, next(self.seq), rid, fn, args))

    def cancel(self, rid):
        self.cancelled.add(rid)

    def loop(self):
        while True:
            prio, _, rid, fn, args = self.q.get()
            if rid in self.cancelled:
                self.cancelled.discard(rid)
                continue
            self.current = rid
            try:
                fn(rid, *args)
            except Cancelled:
                self.emit({'type': 'ai-done', 'rid': rid, 'cancelled': True})
            except Exception as e:
                self.log(f'ai {rid}: {e}')
                self.emit({'type': 'ai-error', 'rid': rid, 'text': self.explain(e)})
            finally:
                self.current = None
                self.cancelled.discard(rid)

    def explain(self, e):
        if isinstance(e, urllib.error.URLError) or isinstance(e, ConnectionError):
            return 'The local AI isn’t answering (npu-llm). Try again in a minute, or check `ai status`.'
        if isinstance(e, TimeoutError):
            return 'The local AI took too long.'
        return f'AI error: {e}'

    # ---------------------------------------------------------------- the model
    def set_state(self, s):
        if s != self.state:
            self.state = s
            self.emit({'type': 'ai-state', 'state': s})

    def warm(self):
        """Wake the on-demand model early (socket-activated, ~45 s cold start)."""
        def run():
            try:
                self.ensure_model()
            except Exception as e:
                self.log(f'ai warm: {e}')
                self.set_state('off')
        threading.Thread(target=run, daemon=True).start()

    def ensure_model(self):
        if self.model:
            return self.model
        self.set_state('waking')
        with urllib.request.urlopen(URL + '/models', timeout=150) as r:
            data = json.load(r)
        items = data.get('data') or data.get('models') or []
        self.model = (items[0].get('id') or items[0].get('name')) if items else 'local'
        self.set_state('ready')
        return self.model

    def chat(self, rid, system, user, schema=None, max_tokens=500, temperature=0.4, stream=False):
        """-> the answer text. With stream=True, chunks go to the UI as ai-chunk."""
        model = self.ensure_model()
        body = {'model': model, 'max_tokens': max_tokens, 'temperature': temperature,
                'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}],
                'chat_template_kwargs': {'enable_thinking': False}}
        if schema:
            body['response_format'] = {'type': 'json_schema', 'json_schema': {'name': 'out', 'schema': schema}}
        if stream:
            body['stream'] = True
        req = urllib.request.Request(URL + '/chat/completions', json.dumps(body).encode(), {'Content-Type': 'application/json'})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=240) as r:
            if not stream:
                out = json.load(r)['choices'][0]['message']['content']
            else:
                parts = []
                for raw in r:
                    if rid in self.cancelled:
                        raise Cancelled()
                    line = raw.decode('utf-8', 'replace').strip()
                    if not line.startswith('data:'):
                        continue
                    data = line[5:].strip()
                    if data == '[DONE]':
                        break
                    try:
                        delta = json.loads(data)['choices'][0].get('delta', {}).get('content') or ''
                    except (ValueError, KeyError, IndexError):
                        continue
                    if delta:
                        parts.append(delta)
                        self.emit({'type': 'ai-chunk', 'rid': rid, 'text': delta})
                out = ''.join(parts)
        self.set_state('ready')
        self.log(f'ai {rid}: {time.time() - t0:.1f}s')
        return re.sub(r'^\s*<think>.*?</think>\s*', '', out, flags=re.S).strip()

    # ---------------------------------------------------------------- tasks
    def analyze(self, rid, mail, done):
        """mail: {subject, from, date, text, thread: [text], me}. done(result) caches it."""
        lang = LANGS.get(lang_of(mail['subject'] + ' ' + mail['text']), 'English')
        today = datetime.date.today().strftime('%A, %d %B %Y')
        sent = datetime.datetime.fromtimestamp(mail['date']).strftime('%A, %d %B %Y %H:%M') if mail.get('date') else 'unknown'
        schema = {'type': 'object', 'properties': {
            'summary': {'type': 'string'},
            'actions': {'type': 'array', 'items': {'type': 'string'}, 'maxItems': 4},
            'events': {'type': 'array', 'maxItems': 3, 'items': {'type': 'object', 'properties': {
                'title': {'type': 'string'}, 'when': {'type': 'string'}}, 'required': ['title', 'when']}},
            'replies': {'type': 'array', 'items': {'type': 'string'}, 'maxItems': 3},
            'needsReply': {'type': 'boolean'},
        }, 'required': ['summary', 'actions', 'events', 'replies', 'needsReply']}
        system = (f'You help {mail.get("me") or "the user"} read email. Today is {today}. Answer in {lang}.\n'
                  '- summary: what the email is about and what is asked, 1-2 short sentences.\n'
                  '- actions: concrete to-dos for the reader (empty for newsletters and notifications).\n'
                  '- events: meetings, deadlines, flights with their date/time, written so a calendar parser '
                  'understands them (e.g. "Tuesday 15:00", "before Friday", "13 October 18:30"); empty if none.\n'
                  '- replies: 3 short, different replies the reader might send (a few words each, first person); '
                  'empty for notifications, newsletters and automated mail.\n'
                  '- needsReply: true only if a person expects an answer.')
        ctx = ''
        if mail.get('thread'):
            ctx = 'Earlier in this conversation:\n' + '\n---\n'.join(clip(t, 900) for t in mail['thread'][-3:]) + '\n\n'
        user = (f'{ctx}Email sent {sent}\nFrom: {mail.get("from", "")}\nSubject: {mail["subject"]}\n\n'
                + clip(strip_quotes(mail['text']) or mail['text']))
        out = json.loads(self.chat(rid, system, user, schema=schema, max_tokens=600, temperature=0.3))
        out['lang'] = lang
        done(out)
        self.emit({'type': 'ai-analysis', 'rid': rid, 'result': out})

    def reply(self, rid, mail, intent, me):
        lang = LANGS.get(lang_of(mail['text'] + ' ' + intent), 'English')
        system = (f'Write the body of an email reply as {me or "the user"}. Language: {lang}. '
                  'Match the tone of the original (casual stays casual). No subject line, no quoted text, '
                  "no placeholders like [Name]. Don't end with a sign-off name or signature — the user's signature is "
                  'added separately. Output only the reply text.')
        user = (f'Original email from {mail.get("from", "")}:\nSubject: {mail["subject"]}\n\n{clip(strip_quotes(mail["text"]), 3500)}\n\n'
                f'What my reply should say: {intent}')
        text = self.chat(rid, system, user, max_tokens=500, temperature=0.6, stream=True)
        self.emit({'type': 'ai-done', 'rid': rid, 'text': text})

    def write(self, rid, prompt, ctx, me):
        lang = LANGS.get(lang_of(prompt + ' ' + ctx.get('body', '')), 'English')
        system = (f'Write an email as {me or "the user"} from their instructions. Language: {lang} unless the '
                  'instructions ask for another. First line: "Subject: …", then a blank line, then the body. '
                  "Natural, concise, no placeholders like [Name]. Don't end with a sign-off name or signature — the "
                  "user's signature is added separately. Output only the email.")
        user = f'Instructions: {prompt}'
        if ctx.get('to'):
            user += f'\nTo: {ctx["to"]}'
        if ctx.get('subject'):
            user += f'\nSubject so far: {ctx["subject"]}'
        if ctx.get('quote'):
            user += f'\n\nThis replies to:\n{clip(strip_quotes(ctx["quote"]), 3000)}'
        text = self.chat(rid, system, user, max_tokens=700, temperature=0.6, stream=True)
        subject = ''
        m = re.match(r'^\s*(subject|тема)\s*:\s*(.+?)\s*\n+', text, re.I)
        if m:
            subject, text = m.group(2), text[m.end():]
        self.emit({'type': 'ai-done', 'rid': rid, 'text': text.strip(), 'subject': subject})

    REWRITE = {
        'improve': 'Improve this email: clearer, better flow, correct grammar. Keep the language, meaning and length roughly the same.',
        'shorten': 'Make this email much shorter while keeping every request, date and fact. Keep the language.',
        'formal': 'Rewrite this email in a polite, professional tone. Keep the language and every fact.',
        'friendly': 'Rewrite this email in a warm, friendly, casual tone. Keep the language and every fact.',
        'fix': 'Fix spelling, grammar and punctuation only. Change nothing else. Keep the language.',
        'en': 'Translate this email into natural English.',
        'ru': 'Translate this email into natural Russian.',
        'ja': 'Translate this email into natural Japanese (polite です/ます style).',
    }

    def rewrite(self, rid, text, mode):
        task = self.REWRITE.get(mode) or f'Rewrite this email following this instruction: {mode}. Keep every fact unless told otherwise.'
        if mode not in ('en', 'ru', 'ja'):
            task += f' Write it in {LANGS[lang_of(text)]}, the language it is in now (unless the instruction says otherwise).'
        system = (task + ' Never add placeholders like [Name] or [Your name]; use only names that appear in the text. '
                  "Don't add a sign-off name or signature the text doesn't have (the user's signature is added separately). "
                  'Output only the rewritten email text, without a subject line or comments.')
        out = self.chat(rid, system, clip(text, 5000), max_tokens=900, temperature=0.4, stream=True)
        self.emit({'type': 'ai-done', 'rid': rid, 'text': out})

    def translate(self, rid, text, target):
        system = (f'Translate the email into {LANGS.get(target, target)}. Keep paragraphs, lists and links. '
                  'Output only the translation.')
        out = self.chat(rid, system, clip(text, 5000), max_tokens=1400, temperature=0.2, stream=True)
        self.emit({'type': 'ai-done', 'rid': rid, 'text': out})

    def ask(self, rid, question, docs):
        """docs: [{n, from, date, subject, text}] — answer citing [n]."""
        lang = LANGS.get(lang_of(question), 'English')
        today = datetime.date.today().strftime('%A, %d %B %Y')
        system = (f'Answer the question using only the emails below. Today is {today}. Answer in {lang}, briefly '
                  '(a few sentences or bullets). Cite emails as [1], [2]. If the emails don\'t contain the answer, '
                  'say so in one sentence.')
        parts, budget = [], MAX_CHARS
        for d in docs:
            body = clip(strip_quotes(d['text']), 700)
            chunk = f'[{d["n"]}] {d["date"]} · from {d["from"]} · "{d["subject"]}"\n{body}'
            if len(chunk) > budget:
                break
            parts.append(chunk)
            budget -= len(chunk)
        out = self.chat(rid, system, 'Emails:\n\n' + '\n\n'.join(parts) + f'\n\nQuestion: {question}',
                        max_tokens=450, temperature=0.2, stream=True)
        self.emit({'type': 'ai-done', 'rid': rid, 'text': out})

    def brief(self, rid, docs, lang):
        today = datetime.date.today().strftime('%A, %d %B %Y')
        system = (f'You brief the user on their unread email. Today is {today}. Answer in {LANGS.get(lang, "English")}. '
                  'Start with one line on the overall picture, then group: what needs a reply or action (most urgent '
                  'first), then FYI, then a single line for newsletters/promotions. One short bullet per email, '
                  'citing it as [n]. No preamble.')
        parts = [f'[{d["n"]}] {d["date"]} · {d["from"]} · "{d["subject"]}" — {d["text"][:260]}' for d in docs]
        out = self.chat(rid, system, '\n'.join(parts), max_tokens=650, temperature=0.3, stream=True)
        self.emit({'type': 'ai-done', 'rid': rid, 'text': out})
