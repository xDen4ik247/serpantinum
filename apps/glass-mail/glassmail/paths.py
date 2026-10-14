"""Where Glass Mail keeps things. Every path can be moved with an environment variable (tests)."""
import os

HOME = os.path.expanduser('~')
CONFIG = os.environ.get('GLASS_MAIL_CONFIG') or os.path.join(HOME, '.config', 'glass-mail')
CACHE = os.environ.get('GLASS_MAIL_CACHE') or os.path.join(HOME, '.cache', 'glass-mail')
STATE = os.environ.get('GLASS_MAIL_STATE') or os.path.join(HOME, '.local', 'state', 'glass-mail')
DOWNLOADS = os.environ.get('GLASS_MAIL_DOWNLOADS') or os.path.join(HOME, 'Downloads')

ACCOUNTS = os.path.join(CONFIG, 'accounts.json')      # passwords live here, mode 600
SETTINGS = os.path.join(CONFIG, 'settings.json')
DB = os.path.join(CACHE, 'mail.db')
BODIES = os.path.join(CACHE, 'bodies')
IMAGES = os.path.join(CACHE, 'images')
OPENED = os.path.join(CACHE, 'open')                  # attachments opened with xdg-open
UNREAD = os.path.join(STATE, 'unread.json')           # for the bar / scripts
DRAFTS = os.path.join(STATE, 'drafts')


def ensure():
    for d in (CONFIG, CACHE, STATE, BODIES, IMAGES, OPENED, DRAFTS):
        os.makedirs(d, exist_ok=True)
    try:
        os.chmod(CONFIG, 0o700)
    except OSError:
        pass
