"""A tiny SMTP server for tests: accepts AUTH, stores what is sent (no TLS, no relaying)."""
import socketserver
import threading


class _Handler(socketserver.StreamRequestHandler):
    def send(self, s):
        self.wfile.write((s + '\r\n').encode())

    def handle(self):
        srv = self.server
        self.send('220 fake ESMTP')
        mail, rcpt = None, []
        while True:
            line = self.rfile.readline()
            if not line:
                return
            cmd = line.decode('utf-8', 'replace').strip()
            up = cmd.upper()
            if up.startswith(('EHLO', 'HELO')):
                self.wfile.write(b'250-fake\r\n250-AUTH PLAIN LOGIN\r\n250-8BITMIME\r\n250 SMTPUTF8\r\n')
            elif up.startswith('AUTH PLAIN'):
                parts = cmd.split()
                if len(parts) == 2:
                    self.send('334 ')
                    self.rfile.readline()
                ok = srv.password_ok
                self.send('235 ok' if ok else '535 bad credentials')
            elif up.startswith('AUTH LOGIN'):
                self.send('334 VXNlcm5hbWU6')
                self.rfile.readline()
                self.send('334 UGFzc3dvcmQ6')
                self.rfile.readline()
                self.send('235 ok' if srv.password_ok else '535 bad credentials')
            elif up.startswith('MAIL FROM'):
                mail, rcpt = cmd[10:].strip(), []
                self.send('250 ok')
            elif up.startswith('RCPT TO'):
                rcpt.append(cmd[8:].strip().strip('<>'))
                self.send('250 ok')
            elif up == 'DATA':
                self.send('354 go')
                data = bytearray()
                while True:
                    ln = self.rfile.readline()
                    if ln in (b'.\r\n', b'.\n', b''):
                        break
                    if ln.startswith(b'..'):
                        ln = ln[1:]
                    data += ln
                srv.messages.append({'from': mail, 'rcpt': rcpt, 'data': bytes(data)})
                self.send('250 queued')
            elif up == 'RSET':
                mail, rcpt = None, []
                self.send('250 ok')
            elif up == 'NOOP':
                self.send('250 ok')
            elif up == 'QUIT':
                self.send('221 bye')
                return
            else:
                self.send('502 not here')


class FakeSMTP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, port=0):
        super().__init__(('127.0.0.1', port), _Handler)
        self.messages = []
        self.password_ok = True
        self.port = self.server_address[1]
        threading.Thread(target=self.serve_forever, daemon=True).start()
