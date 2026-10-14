# Glass Music

A Spotify-style library app for the MPD music library, in the liquid-glass / Matugen look of
the Serpantinum desktop. Quickshell window (app-id `glass-music`) + a small backend in Rust (`backend/`, a port of the
Python `glassmusic.server`, which stays as the fallback).

- `glass-music` (Mod+Shift+M) opens it, or focuses it if it is already open (via the shared
  `niri-focus-or-run` helper in `~/.local/bin`; without it a second window opens). Mod+Q closes it;
  playback keeps running in MPD. `glass-music --current` opens (or focuses) it on the album of
  the playing track.
- **My Vibe** (Home): one big play button for an endless smart queue from `music-smart`, plus a
  style picker: My Vibe (what you play most, from the play history), Favourites, Discover (rarely
  played), Reggae (from genre tags) and the moods. Styles top themselves up as you listen; Mod+S
  re-rolls within the style. Local overrides / extra styles: `~/.config/glass-music/styles.json`
  (see `music-smart --help`).
- Keys: Space play/pause · Ctrl+F search · Ctrl+L lyrics · Ctrl+Shift+Q queue · Ctrl+←/→ prev/next ·
  Ctrl+↑/↓ volume · Ctrl+S shuffle · Ctrl+R repeat · Alt+←/→ back/forward.
- Double-click a song: play it with its album / artist / list as the queue. Right-click: play next,
  add to queue, favourite, add to playlist, never play in My Vibe, go to artist / album.
- **Remove…** (right-click a song, an album, a queue entry or a downloaded Yandex song): library
  songs go to the Trash with their `.lrc` (restorable), temp-cache ones are deleted; emptied
  album / artist folders are cleaned up and the songs leave the queue. "Remove and unlike on
  Yandex" also drops the Yandex like (found by the link tag the downloader writes, or by
  matching your liked tracks' paths), otherwise the daily sync downloads liked songs again.
- The whole library counts as liked. ☆ Favourite = MPD sticker `favourite` (a strong boost in My
  Vibe and its own style; old `love` stickers are migrated by music-smart); "Never play in My Vibe"
  = sticker `ban`.
- Menu (⋯, top right): Open terminal player (rmpc), Save queue as playlist, Rescan library,
  Sync Yandex likes now, Yandex Music & downloads.
- **Yandex Music**: Search also searches all of Yandex Music (songs, artists, albums, playlists;
  artists / albums / playlists open as pages). Nothing streams: playing a song first runs
  `yandex-music-downloader -u <music.yandex.ru link>`, then MPD plays the local file. The clicked
  song plays as soon as it is down; the rest of the album / list follows in order. Where songs go
  (Downloads & sync page): **Library** (`~/Music`, `Artist/Album/N - Title`, like the rest) or
  **Temporary** (`~/.cache/glass-music/yandex-temp`, oldest pruned past a size limit; ✓/⬇ keeps
  one in `~/Music`). ♥ likes / unlikes on Yandex. The page also sets quality and which Yandex
  playlists the daily sync downloads (likes by default; `glass-music-yandex-sync.timer`).
  Search and pages read api.music.yandex.ru, the JSON the music.yandex.ru site itself loads,
  through the yandex_music library that comes with the downloader.
- **Lyrics embedding (lrcput)**: after every download the synced `.lrc` is written into the
  file's lyrics tag (MP4 ©lyr, FLAC LYRICS, ID3 USLT), only when it differs; the `.lrc` stays.
  Whole tree by hand: `glassmusic.yandex embed [DIR]` (see below). If Yandex's lyrics server
  fails for a song, it is downloaded without lyrics rather than not at all.

Layout: `qml/` (shell.qml = state + window; one file per component/page), `glassmusic/`
(server.py = JSON-lines protocol, library.py = index + cache, search.py, thumbs.py, mpdclient.py,
yandex.py = Yandex worker in its own venv, removal.py = Trash / delete), `systemd/` (the daily sync timer).
Caches: `~/.cache/glass-music/{library.json,thumbs/}` (rebuilt when MPD's db_update changes).

Install / update: `./install.sh` (also creates `~/.local/share/glass-music/yandex-venv` with
yandex-music-downloader + mutagen and enables the sync timer). Sign in on the Downloads & sync
page; the token is kept only in `~/.config/glass-music/yandex.json` (mode 600). CLI, run with
`PYTHONPATH=~/.local/share/glass-music/app ~/.local/share/glass-music/yandex-venv/bin/python -m glassmusic.yandex`
`sync | embed [DIR] | status | login` (login reads the token or the sign-in redirect URL from stdin).

Tests: `python -m unittest discover -s tests -t .` (the Yandex ones need the venv's python).

**Backend.** The window runs `bin/glass-music-backend` (Rust, built by `install.sh` with cargo) and
falls back to `python3 -m glassmusic.server` when the binary is missing or `GLASS_MUSIC_PYTHON` is
set. The Yandex worker (`glassmusic.yandex`, in its venv) stays Python; the Rust backend spawns it the
same way. Pillow's resampling and colorsys are ported as is and covers decode through libjpeg-turbo,
so cover colours and thumbnails come out identical. Parity tests, Python vs Rust:
- `python -m tests.parity.pure`: the pure parts over the real library (read-only): search
  (8.8k queries), lyrics on every song, the lyrics resolver's matching, cover colour + thumbnail
  pixels for every cover. 0 differences.
- `python -m tests.parity.live_diff`: both backends run one scripted session (85 steps: playback,
  queue, favourites, playlists, lyrics lookups, Yandex play/next/add/sync, removal, errors) against a
  private MPD (own socket / database, null output) over a symlink mirror of the library, with fakes
  for the Yandex worker, LRCLIB (`GLASS_MUSIC_LRCLIB`), music-smart and the Trash; every message, MPD
  state and file left behind is compared. Output in `tests/parity/out/` (git-ignored).

Environment overrides (for tests): `GLASS_MUSIC_MPD` (socket or host:port), `GLASS_MUSIC_CACHE`,
`GLASS_MUSIC_HISTORY`, `GLASS_MUSIC_SMART_STATE`, `GLASS_MUSIC_SMART_ENV` (JSON env for music-smart),
`GLASS_MUSIC_TITLE`, `GM_W`/`GM_H` (initial size), `GLASS_MUSIC_DIR` (music directory),
`GLASS_MUSIC_YM_CONF` / `GLASS_MUSIC_YM_TEMP` / `GLASS_MUSIC_YM_PYTHON` (Yandex settings file,
temp cache, venv python), `GLASS_MUSIC_LRCLIB` (LRCLIB API base), `GLASS_MUSIC_SMART_BIN`, `GLASS_MUSIC_DEBUG`. IPC: `quickshell ipc -p <app>/qml call glassmusic …`
(`go`, `panel`, `search`, `state`, `vibe <style>`, `pickStyle <style>`, `openCurrent`,
`shot <png>` renders only this window; Yandex: `ymSearch <q>`, `ymOpen <kind> <id>`,
`ymPlayResult <i>`, `ymPlayPage <i>`, `ymState`).
