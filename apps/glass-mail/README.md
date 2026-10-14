# Glass Mail

A mail app in the liquid-glass / Matugen look of the Serpantinum desktop: Gmail, Yandex, Mail.ru,
Outlook, iCloud or any IMAP/SMTP account. Quickshell window (app-id `glass-mail`) + a small,
dependency-free Python backend (standard library only).

- `glass-mail` (Mod+I) opens it, or focuses it if it is already open (`niri-focus-or-run`).
  It is also the default `mailto:` handler and has a "New message" desktop action.
- **Sign in** (Accounts & settings): the address + an **app password**. The form links to the
  provider's app-password page; servers are filled in for the known providers (Advanced to change
  them). Passwords stay in `~/.config/glass-mail/accounts.json` (mode 600) and nowhere else.
- **Layout**: sidebar (Compose, All inboxes with 2+ accounts, Starred, each account's folders with
  unread counts), the list (date groups, filter chips All / Unread / Starred / Attachments, hover
  actions, Ctrl/Shift+click to select), the reader. Narrow windows collapse the sidebar; very narrow
  ones show the list and the message in turn.
- **Reader view**: HTML mail is rewritten by the backend into themed text and images (headings,
  links, lists, quotes, tables as lines). Scripts, styles, hidden preheaders and tracking pixels are
  dropped. **Remote images stay blocked** until you click Show (or "Always from sender"); inline
  images show at once. ⋯ → *Open original in browser* shows the real layout (script-free, CSP-locked)
  and *Show original* the raw source. Unsubscribe uses List-Unsubscribe.
- **Actions** are instant and undoable: archive (E), delete (#), spam (!), move, star (S), read (U).
  The next message opens in place of the one that goes away. Archive uses the Archive folder (Gmail:
  All mail) and creates it if the server has none. Delete in Trash deletes forever.
- **Compose** (C): a card in the corner. From (several accounts), To/Cc/Bcc with address suggestions
  from your mail, attachments (file picker), reply / reply all / forward with quoting and the
  original attachments. **Ctrl+Enter sends, with 5 s to undo.** The draft is autosaved and comes
  back with the app. Sent mail is filed in Sent (Gmail does that itself).
- **Search** (/ or Ctrl+F): instant results from the cache, then the servers (Gmail syntax works
  on Gmail: `from:`, `has:attachment`, `older_than:1y`…).
- **New mail**: `glass-mail-watch.service` (always on) keeps one IMAP IDLE connection per account, so
  the server pushes new mail within a second or two, app open or not. Idle cost measured: 0 CPU over
  a minute, ~38 MB RAM; it reconnects right after resume from sleep and on dead networks
  (TCP keepalive). `python -m glassmail.check` is a one-shot sync for scripts. Notifications have an Open action. The unread total is written to
  `~/.local/state/glass-mail/unread.json` (for the bar / scripts).
- **Login codes** (no AI, instant): a fresh verification code ("G-482913 is your Google code",
  «Код для входа: 384920», Telegram, Apple, Steam…) goes **straight to the clipboard** with a
  "copied" notification — measured 0.1–0.6 s after the mail reaches the server, app open or not —
  and the clipboard is cleared after 3 min. The code mail then goes **straight to the Trash**
  (restorable; Settings → AI & codes: Trash now / after a day / keep). Codes also show as a key
  chip in the list and a Copy banner in the message. Detection scores number-like tokens by context (code words
  in EN/RU/ES/DE/JA vs. order numbers, prices, dates, phones, promo codes) — `glassmail/codes.py`.
- **AI, all on the local model** (npu-llm, Qwen on the Arc GPU; nothing leaves the laptop; first use
  wakes it in ~45 s):
  - **Summary card** on each message (automatic after a second, cached): the gist, to-dos, dates
    with one-click *Add to calendar* (via `gcal-sync`), and 3 **smart replies** — click one and the
    AI writes the full reply into Compose.
  - **Compose**: "Ask AI to write it…" drafts from a prompt (subject included); on existing text
    "Ask AI to change it…" or Improve / Shorter / Formal / Friendly / Fix grammar / → EN / RU / JA.
    Streams in, keeps your signature and the quoted history, Stop and Undo.
  - **Translate** a message (T) into your language (Settings → AI & codes).
  - **Ask your mail**: type a question in search and press Enter ("когда рейс?", "what did Lena
    send to sign?") — an answer with [n] citations linking to the source messages.
  - **Catch me up** (B, or the button when nothing is open): a briefing on the unread inbox.
  - **Smart inbox**: People / Updates / News filters (instant, from the headers).
- Keys: J/K or ↑/↓ move · Enter open · C compose · R / A / F reply / all / forward · E archive ·
  # delete · ! spam · S star · U read/unread · X select · Ctrl+A all · Z undo · / search ·
  Ctrl+R refresh · Esc back · ? shortcuts.

Layout of the code: `qml/` (shell.qml = state + window; one file per component), `glassmail/`
(server.py = JSON-lines protocol, engine.py = per-account IMAP threads (fg / bg / idle) and SMTP,
store.py = SQLite cache, mime.py = parsing and building mail, reader.py = HTML → reader view,
imapparse.py = FETCH/LIST/BODYSTRUCTURE parsing, check.py = the background check, codes.py = login
codes, ai.py = the local-model tasks).
The backend runs in Rust: `backend/` is a line-for-line port of `glassmail/` (one binary:
`glass-mail-backend` = the window's server, `glass-mail-backend watch` = the IDLE watcher,
`glass-mail-backend check` = the one-shot sync). It keeps the protocol, the cache and the files
byte-compatible, so either backend can open the other's cache; the window and the watcher fall back
to Python when the binary isn't installed (or with `GLASS_MAIL_PYTHON=python3`). Parity with the
Python original (tests/parity/):

| check | result |
|---|---|
| live session vs Dovecot: 256 steps, every emitted message, sent mail, IMAP, cache, files | identical (1 background unread snapshot differs in timing) |
| outgoing MIME (`build`), 2448 drafts | byte-identical |
| reader / login codes / MIME parsing, 29k inputs from a real cache | identical except 284 inputs that hit known Python email bugs |
| watcher + check: notifications, clipboard, cache, server state | identical |

| cost | Python | Rust |
|---|---|---|
| live session CPU | 1.81 s | 0.76 s |
| live session RSS | 43 MB | 33 MB |
| idle watcher RSS | 35 MB | 21 MB |
| reader/codes over 18k mails | 14.5 s | 2.4 s |

Cache: `~/.cache/glass-mail/{mail.db,bodies/,images/}` — safe to delete, it is rebuilt.

Install / update: `./install.sh`.

Tests: `python -m unittest tests.test_basics tests.test_codes` (offline) and `python -m unittest tests.test_live`
(a throwaway Dovecot in Docker + a fake SMTP server; never touches real accounts, your config or
your clipboard). `GLASS_MAIL_TEST_AI=1` adds the local-model tests; `GLASS_MAIL_SERVER_CMD=backend/target/release/glass-mail-backend`
runs them against the Rust backend. Differential tests: `python -m tests.parity.live_diff`,
`python -m tests.parity.watch_diff`, `python -m tests.parity.build_parity` (Docker for the first two).

Environment overrides (tests): `GLASS_MAIL_CONFIG`, `GLASS_MAIL_CACHE`, `GLASS_MAIL_STATE`,
`GLASS_MAIL_DOWNLOADS`, `GLASS_MAIL_NOTIFY_LOG` (record notifications instead of showing them),
`GLASS_MAIL_INSECURE=1` (accept a self-signed server), `GLASS_MAIL_TITLE`, `GM_W` / `GM_H`.
