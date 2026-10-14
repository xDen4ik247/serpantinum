"""Mail accounts: ~/.config/glass-mail/accounts.json (mode 600, holds the app passwords) and
server presets for the common providers."""
import hashlib
import json
import os
import tempfile

from . import paths

# domain -> (imap host, imap port, smtp host, smtp port, smtp security, app-password page, label)
PRESETS = {
    'gmail': ('imap.gmail.com', 993, 'smtp.gmail.com', 465, 'ssl',
              'https://myaccount.google.com/apppasswords', 'Gmail'),
    'yandex': ('imap.yandex.ru', 993, 'smtp.yandex.ru', 465, 'ssl',
               'https://id.yandex.ru/security/app-passwords', 'Yandex Mail'),
    'mailru': ('imap.mail.ru', 993, 'smtp.mail.ru', 465, 'ssl',
               'https://account.mail.ru/user/2-step-auth/passwords', 'Mail.ru'),
    'outlook': ('outlook.office365.com', 993, 'smtp-mail.outlook.com', 587, 'starttls',
                'https://account.live.com/proofs/AppPassword', 'Outlook'),
    'icloud': ('imap.mail.me.com', 993, 'smtp.mail.me.com', 587, 'starttls',
               'https://account.apple.com/account/manage', 'iCloud Mail'),
}
DOMAINS = {
    'gmail.com': 'gmail', 'googlemail.com': 'gmail',
    'yandex.ru': 'yandex', 'ya.ru': 'yandex', 'yandex.com': 'yandex', 'yandex.by': 'yandex',
    'yandex.kz': 'yandex', 'yandex.ua': 'yandex', 'narod.ru': 'yandex',
    'mail.ru': 'mailru', 'inbox.ru': 'mailru', 'list.ru': 'mailru', 'bk.ru': 'mailru', 'internet.ru': 'mailru',
    'outlook.com': 'outlook', 'hotmail.com': 'outlook', 'live.com': 'outlook', 'msn.com': 'outlook',
    'icloud.com': 'icloud', 'me.com': 'icloud', 'mac.com': 'icloud',
}
COLORS = ['#80d4db', '#f2b880', '#b7c7ea', '#e8a0bf', '#a6d189', '#c6a0f6', '#f5c2a0']


def guess(email):
    """Server settings for an address: a known provider, else imap./smtp.<domain>."""
    dom = email.rsplit('@', 1)[-1].strip().lower()
    key = DOMAINS.get(dom)
    if key:
        ih, ip, sh, sp, sec, help_url, label = PRESETS[key]
        return {'provider': key, 'label': label, 'help': help_url,
                'imap': {'host': ih, 'port': ip}, 'smtp': {'host': sh, 'port': sp, 'security': sec}}
    return {'provider': '', 'label': dom, 'help': '',
            'imap': {'host': 'imap.' + dom, 'port': 993},
            'smtp': {'host': 'smtp.' + dom, 'port': 465, 'security': 'ssl'}}


def account_id(email):
    return hashlib.sha1(email.strip().lower().encode()).hexdigest()[:10]


def load():
    try:
        with open(paths.ACCOUNTS) as f:
            data = json.load(f)
        return data.get('accounts', [])
    except (OSError, ValueError):
        return []


def save(accounts):
    paths.ensure()
    fd, tmp = tempfile.mkstemp(dir=paths.CONFIG, prefix='.accounts.')
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump({'accounts': accounts}, f, indent=2, ensure_ascii=False)
        os.replace(tmp, paths.ACCOUNTS)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def public(a):
    """What the UI may see (no password)."""
    return {k: v for k, v in a.items() if k != 'password'} | {'hasPassword': bool(a.get('password'))}


def is_gmail(a):
    return a.get('provider') == 'gmail' or a.get('imap', {}).get('host', '').endswith('gmail.com')


def load_settings():
    try:
        with open(paths.SETTINGS) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_settings(s):
    paths.ensure()
    tmp = paths.SETTINGS + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
    os.replace(tmp, paths.SETTINGS)
