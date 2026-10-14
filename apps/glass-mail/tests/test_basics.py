"""Offline tests: IMAP parsing, the reader view, building mail. python -m unittest tests.test_basics"""
import email
import email.policy
import unittest

from glassmail import imapparse as ip
from glassmail import mime, reader
from glassmail.engine import uidset


class Parse(unittest.TestCase):
    def test_fetch_with_literals_and_flags(self):
        data = [(b'1 (UID 7 FLAGS (\\Seen $Label) BODY[HEADER.FIELDS (SUBJECT)] {13}', b'Subject: hi\r\n'), b' X-GM-THRID 99)',
                b'2 (UID 8 FLAGS () BODY[1]<0> NIL)']
        r = ip.parse_fetch(data)
        self.assertEqual(r[0][b'UID'], b'7')
        self.assertEqual(r[0][b'FLAGS'], [b'\\Seen', b'$Label'])
        self.assertEqual(r[0][b'BODY[HEADER.FIELDS (SUBJECT)]'], b'Subject: hi\r\n')
        self.assertEqual(r[0][b'X-GM-THRID'], b'99')
        self.assertIsNone(r[1][b'BODY[1]<0>'])

    def test_list_and_utf7(self):
        data = [b'(\\HasNoChildren \\Sent) "/" "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-"', b'(\\Noselect) "/" "[Gmail]"', b'(\\HasNoChildren) "." INBOX']
        out = ip.parse_list(data)
        self.assertEqual(out[0][2], 'Отправленные')
        self.assertIn('\\sent', out[0][0])
        self.assertEqual(out[2][2], 'INBOX')
        self.assertEqual(ip.encode_utf7('Отправленные'), '&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-')
        self.assertEqual(ip.decode_utf7(ip.encode_utf7('A & B')), 'A & B')

    def test_bodystructure(self):
        bs = [[[b'text', b'plain', [b'charset', b'utf-8'], None, None, b'quoted-printable', b'100', b'3', None, None, None, None],
               [b'text', b'html', [b'charset', b'utf-8'], None, None, b'base64', b'900', b'12', None, None, None, None], b'alternative'],
              [b'application', b'pdf', [b'name', b'a.pdf'], None, None, b'base64', b'5000', None, [b'attachment', [b'filename', b'a.pdf']], None, None],
              b'mixed']
        part, info, att = ip.summarize_structure(bs)
        self.assertEqual(part, '1.1')
        self.assertEqual(info['encoding'], 'quoted-printable')
        self.assertTrue(att)

    def test_uidset(self):
        self.assertEqual(uidset([5, 1, 2, 3, 9, 10]), '1:3,5,9:10')


class Reader(unittest.TestCase):
    def test_html_cleanup(self):
        h = ('<div style="display:none">pre <div>x</div> hidden</div><script>x()</script><h2>Hi</h2>'
             '<p>a <a href="javascript:bad()">bad</a> <a href="https://ok.example">ok</a></p>'
             '<img src="https://t.example/p.gif" width="1" height="1"><img src="https://i.example/a.png" alt="A">')
        b = reader.html_blocks(h)
        text = ''.join(x.get('html', '') for x in b)
        self.assertNotIn('pre', text)
        self.assertNotIn('javascript', text)
        self.assertIn('https://ok.example', text)
        self.assertEqual([x['src'] for x in b if x['t'] == 'img'], ['https://i.example/a.png'])

    def test_plain_quotes(self):
        b = reader.text_blocks('hello\n> old\n> more\nbye')
        self.assertEqual([x['q'] for x in b], [0, 1, 0])

    def test_snippet_from_base64_cut(self):
        import base64
        raw = base64.encodebytes('Привет, это длинное письмо. '.encode() * 20)[:301]
        s = mime.snippet_from_part(raw, {'encoding': 'base64', 'params': {'charset': 'utf-8'}, 'subtype': 'plain'})
        self.assertTrue(s.startswith('Привет, это'))


class Build(unittest.TestCase):
    def test_reply_headers_and_bcc(self):
        acc = {'email': 'me@example.org', 'name': 'Me'}
        m, rcpts = mime.build(acc, {'to': 'A <a@x.org>, b@y.org', 'bcc': 'c@z.org', 'subject': 'Re: x', 'body': 'hi\n> q',
                                    'inReplyTo': '<1@x>', 'refs': '<0@x>'})
        self.assertEqual(rcpts, ['a@x.org', 'b@y.org', 'c@z.org'])
        self.assertIsNone(m['Bcc'])
        self.assertEqual(m['References'], '<0@x> <1@x>')
        parsed = email.message_from_bytes(bytes(m), policy=email.policy.default)
        self.assertIn('blockquote', parsed.get_body(('html',)).get_content())

    def test_reply_subject(self):
        self.assertEqual(mime.reply_subject('Re: a', 'Re'), 'Re: a')
        self.assertEqual(mime.reply_subject('a', 'Fwd'), 'Fwd: a')


if __name__ == '__main__':
    unittest.main()
