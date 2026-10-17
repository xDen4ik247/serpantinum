<div align="center">
  <img src="docs/assets/banner.png" alt="Serpantinum" width="850" />

  <h1>Serpantinum — liquid glass edition</h1>

  <p>A niri desktop where every surface is glass, with its own music, mail and study apps<br>
  and a local-AI layer that runs entirely on the laptop.</p>
</div>

This is an edition of [ilyamiro/serpantinum](https://github.com/ilyamiro/serpantinum) (v2.2.4, niri), tuned for an
Intel Core Ultra 200V ("Lunar Lake") laptop with an Arc 140V GPU and an NPU. The shell becomes **liquid glass**:
translucent tints over niri blur, hairline rims and soft shadows. Three apps in the same style, a cheat sheet,
an agenda and a set of local AI tools are added on top. Nothing is sent to the cloud.

> [!NOTE]
> Screenshots and short videos are on the way.

## Contents

- [What you get](#what-you-get)
- [Apps](#apps)
- [Shortcuts](#shortcuts)
- [Install](#install)
- [Repository layout](#repository-layout)
- [Development](#development)
- [Credits and license](#credits-and-license)

## What you get

| Area | What it does |
|---|---|
| **Top bar** | Floating glass islands, dynamic workspace dots, an EN/RU/JP input pill, now playing, system tray. |
| **Desktop widgets** | Clock with agenda, month calendar, vitals rings (CPU, GPU, NPU, RAM, temperature, battery), favourite apps, network graph, weather. |
| **Agenda** | Google Calendar (through a secret iCal link) and Obsidian tasks in 8-day and month views, with quick capture in plain language. |
| **Notifications** | Glass popups and a notification centre with do-not-disturb. |
| **Music** | MPD with a glass now-playing panel, synced lyrics and an equaliser. My Vibe builds an endless smart queue from your listening history. |
| **Cheat sheet** | A searchable overlay of every shortcut, generated live from the niri config (Mod+Shift+/). |
| **Japanese** | Mozc that starts in hiragana, NPU OCR for any screen area, a reading helper with furigana, Anki mining and an adaptive quiz. |
| **Local AI** | llama.cpp on the Arc GPU (OpenVINO backend), started on demand: an assistant, clipboard actions, Obsidian AI notes and Whisper dictation on the NPU. |
| **Login** | A liquid-glass SDDM greeter that follows the wallpaper and its colours. You can type your password right away, and the screen locks before sleep. |
| **Power** | `power-mode auto|perf|save`, lazy widgets, an on-demand LLM and runtime power management. The panel stays at 120 Hz. |
| **Rust** | Everything that runs all the time is written in Rust, like niri itself: the app backends and the shell helpers ([why and how](docs/rust.md)). |

Colours come from the wallpaper (Matugen), so picking a wallpaper (Mod+W) recolours the whole desktop.

## Apps

**Glass Music** (Mod+Shift+M) is a Spotify-style library app for MPD. It has home shelves, albums, artists, search,
a queue you can reorder, and synced lyrics. Lyrics come from your own `.lrc` files first, then from online
sources when a song has none. It also has My Vibe styles. With continuous play (on by default, the ∞ button in the
queue), My Vibe takes over when the queue ends. Optional online search and download go through
`yandex-music-downloader`, and everything is downloaded before it plays. [apps/glass-music](apps/glass-music/)

**Glass Mail** (Mod+I) is IMAP and SMTP with app passwords, and an always-on IDLE watcher that sends desktop
notifications. HTML mail is drawn by a real web engine (WebKitGTK), with remote content blocked until you allow
it. Login codes are copied to the clipboard automatically. AI summaries, replies and translations run on the
local model. [apps/glass-mail](apps/glass-mail/)

**JP Quiz** (Mod+J) is an endless adaptive Japanese quiz from N5 to N3. It covers particles, conjugation,
grammar, word order, kanji and vocabulary, all built from real example sentences, and picks each next
question so you get about 75 % right. Answers are explained with JMdict glosses. It also teaches about 6 000
everyday words beyond the JLPT lists (slang, tech, brands, cars, food), and a **Rank** tab (R) shows how
much of real Japanese you know, from N5 to N1 and the 常用漢字, measured against the full lists, with a quick
placement test and an automatic daily goal. [apps/jp-quiz](apps/jp-quiz/)

## Shortcuts

The full list is one keypress away (**Mod+Shift+/**). The ones added by this edition:

| Keys | Action | Keys | Action |
|---|---|---|---|
| Mod+Shift+M | Glass Music | Mod+C | Agenda |
| Mod+M | Now-playing panel | Mod+K | Month calendar |
| Mod+S | My Vibe (start / re-roll) | Mod+O | Today's Obsidian note |
| Mod+, / Mod+. | Previous / next track | Mod+Shift+O | Quick task capture |
| Mod+/ | Play / pause | Mod+N | Ask your notes (local AI) |
| Mod+I | Glass Mail | Mod+Shift+N | Actions for the open note |
| Mod+J | JP Quiz | Mod+A | AI assistant |
| Mod+X | Japanese OCR | Mod+Shift+A | AI actions on the clipboard |
| Mod+Shift+X | OCR + translate | Mod+Z | Dictation |
| Mod+Shift+Z | Reading helper | Alt+K | Hiragana ↔ katakana |
| Mod+W | Wallpaper picker | Mod+Shift+G | Show / hide widgets |
| Mod+Alt+I | Repair the input method | Mod+Alt+R | Restart the shell |

## Install

On Arch Linux (or an Arch-based distribution), as your normal user:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xDen4ik247/serpantinum/glass/install/glass.sh)"
```

Options go after a `_`. For example, a dry run that only shows what would change:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xDen4ik247/serpantinum/glass/install/glass.sh)" _ --dry-run --diff
```

From a clone of the `glass` branch, run `install/glass.sh [options]`. Run it in a terminal: upstream's installer
asks for your sudo password once (the installer keeps it fresh for the whole run). On a fresh install a menu asks
what to install:

```text
   Apps
    1 [x] Glass Music   music library player: synced lyrics, My Vibe, Yandex Music (Mod+Shift+M)
    2 [x] Glass Mail    mail for any IMAP account, HTML mails in a WebKitGTK view (Mod+I)
    3 [ ] JP Quiz       adaptive Japanese trainer; builds its question bank: ~80 MB download, 5–10 min (Mod+J)
   AI features (local, on the Intel NPU/GPU; Intel NPU found)
    4 [x] AI features   assistant, dictation, OCR, notes: keys, scripts, services. Off = nothing AI is installed
    5   [ ] dictation   Whisper speech-to-text, Mod+Z: ~1.2 GB
    …
   Desktop
    9 [x] login screen  the glass SDDM greeter (your wallpaper + colours)
```

Every choice is remembered. Later, `serp-glass` (installed in `~/.local/bin`) re-runs the installer with them:
plain `serp-glass` updates everything, `serp-glass --menu` changes the choices, `serp-glass --ai off` removes the
AI features and `serp-glass --ai on` brings them back.

The installer works in these steps:

1. **Base:** installs (or updates) plain upstream Serpantinum for niri with upstream's own installer modules, at
   the commit this edition is built on. Upstream's `serpantinum update` keeps working.
2. **Root:** extra packages from the official repos (git, Rust and the apps' build dependencies included), the
   glass login screen and, on laptops, the battery tweaks.
3. **Dotfiles:** everything in `home/`. Files that were already there are backed up to
   `~/.config/serp-glass_backup/<date>/` first. Files of a feature you switched off are left out (and removed
   again if the installer put them there); `~/.config/niri/user/output.kdl` is only created when missing, so
   niri picks your displays' own modes.
4. **Shell:** applies the glass changes to Serpantinum as `serp-tweaks` patches, which are re-applied after
   every upstream update.
5. **Apps:** builds and installs the apps you picked; an app you drop later is removed, its data stays.
6. **Extras:** the AI features' models and runtimes you picked (only while the AI features are on).
7. **Services:** installs systemd user units for whatever was installed. The LLM, notes and greeter units start
   on demand.

Running it again is safe, because it only fixes what differs. A file you edited is never overwritten: the new
version is written next to it as `<file>.glass-new`, and `--force` replaces it after making a backup. Your music,
mail, notes, calendar links and quiz progress are never touched. Every change is recorded in
`~/.local/state/serp-glass/`.

| Option | What it does |
|---|---|
| `--dry-run` (`-n`), `--diff` | Show what would change (with diffs) and change nothing |
| `--yes` (`-y`) | Don't ask questions (saved choices, else the defaults) |
| `--menu`, `--no-menu` | Show the choices menu (it shows by itself on a first install in a terminal), or never |
| `--apps LIST` | `glass-music`, `glass-mail`, `jp-quiz`, `all` or `none` (default: Glass Music + Glass Mail) |
| `--ai on\|off` | The AI features (default: on with an Intel NPU). `off` installs nothing AI: no scripts, services, keybinds or NPU packages |
| `--with LIST` | The AI features' heavy parts (below) |
| `--no-sddm`, `--power auto\|yes\|no`, `--no-shell-rc` | Skip the login screen, the battery tweaks or the zsh files |
| `--vault NAME` | Your Obsidian vault in `~/Obsidian` |
| `--only STEPS` | Run only some steps: `base,root,dotfiles,shell,apps,extras,services` |
| `--skip-base`, `--reinstall-base`, `--upstream latest`, `--upstream-menu` | Control the upstream base install |
| `--wallpapers few\|full\|none` | Upstream's wallpaper pack (default: a few) |
| `--status` | Show what is installed |
| `--uninstall [--purge]` | Remove the glass layer (upstream stays); `--purge` also deletes downloaded models |

**AI extras.** The default install downloads no models. The desktop works without them; with the AI features on,
their keys just do nothing until the model is there.

| Extra | What you get | Cost |
|---|---|---|
| `dictation` | Whisper dictation (Mod+Z) on the NPU | ~1.2 GB |
| `ocr` | Japanese OCR (Mod+X) on the NPU, with the JMdict popup | ~1 GB kept, ~2.5 GB temporary |
| `llm` | Local LLM on the Intel Arc GPU (assistant, calendar capture, OCR translation): OpenVINO + llama.cpp built locally + Qwen3.5-4B | ~3.2 GB download, 10–20 min build, ~9 GB RAM while running |
| `notes` | Obsidian AI notes (Mod+N); needs `llm` | 640 MB |
| `all` | All of the above | |

All downloads are pinned to exact upstream revisions and checked against their sha256. With `--ai off` the
downloaded models stay on disk (listed at the end of the run) so `--ai on` doesn't fetch them again;
`--uninstall --purge` deletes them.

After the first install, log out and pick the niri session (or reboot). Press **Mod+Shift+/** to see every
shortcut, and run `gcal-setup` to add a Google Calendar. Its secret address stays in `~/.config/gcal-sync/`.

## Repository layout

```text
src/        Serpantinum itself: upstream + the glass changes, one commit per feature
home/       dotfiles relative to $HOME (paths written as /home/user; the installer renders your own)
system/     root-owned parts: SDDM theme + installer, udev/sysctl power tweaks, package list
apps/       Glass Music, Glass Mail and JP Quiz (each with a Rust backend and its tests)
rust/       the Rust shell helpers (Python/bash originals in rust/reference/, tests in rust/tests/)
install/    glass.sh + glass-modules/ (this edition) next to upstream's install.sh + modules/
compositors/, config/, bin/   upstream's compositor samples, app configs and CLI
docs/       rust.md (Python/bash vs Rust), banner
tools/      sync-from-system.sh (machine → repo), check-secrets.sh (run before every commit)
```

The niri config keeps upstream's copies in `~/.config/niri/config/` (never edited) and adds your own layer in
`~/.config/niri/user/`, with one `binds-<feature>.kdl` / `rules-<feature>.kdl` file per feature.

## Development

```bash
git fetch upstream && git merge upstream/master         # on branch glass
tools/sync-from-system.sh && tools/check-secrets.sh && git add -p
```

After merging upstream, set `G_UPSTREAM_BASE` in `install/glass.sh` to the upstream commit you merged, so the
installer builds its patches against it. Each app has its own tests, including differential tests between the Rust backends and
the original Python ones (see `apps/*/tests/` and `rust/tests/`).

## Credits and license

Built on [Serpantinum](https://github.com/ilyamiro/serpantinum) by [ilyamiro](https://github.com/ilyamiro) and its
contributors. If you like the shell, support its author on [Ko-fi](https://ko-fi.com/ilyamiro). Upstream thanks
Darkall44/Qylock for its SDDM theme.

<div align="center">
  <h3>Upstream contributors</h3>
  <br>

  <a href="https://github.com/TheRinder2"><img src="https://avatars.githubusercontent.com/u/48689803?v=4&s=48" width="48" height="48" alt="TheRinder2"></a>
  <a href="https://github.com/bizneskind-droid"><img src="https://avatars.githubusercontent.com/u/245046997?v=4&s=48" width="48" height="48" alt="bizneskind-droid"></a>
  <a href="https://github.com/Pigeon78"><img src="https://avatars.githubusercontent.com/u/151051379?v=4&s=48" width="48" height="48" alt="Pigeon78"></a>
  <a href="https://github.com/Eduarduar"><img src="https://avatars.githubusercontent.com/u/104547727?v=4&s=48" width="48" height="48" alt="Eduarduar"></a>
  <a href="https://github.com/Spinty-dev"><img src="https://avatars.githubusercontent.com/u/123001216?v=4&s=48" width="48" height="48" alt="Spinty-dev"></a>
  <a href="https://github.com/MrDexstor"><img src="https://avatars.githubusercontent.com/u/97257847?v=4&s=48" width="48" height="48" alt="MrDexstor"></a>
  <a href="https://github.com/coloramamoe"><img src="https://avatars.githubusercontent.com/u/117035740?v=4&s=48" width="48" height="48" alt="coloramamoe"></a>
  <a href="https://github.com/Zyxilon"><img src="https://avatars.githubusercontent.com/u/234867627?v=4&s=48" width="48" height="48" alt="Zyxilon"></a>
  <a href="https://github.com/gouthamkrishnap"><img src="https://avatars.githubusercontent.com/u/224089015?v=4&s=48" width="48" height="48" alt="gouthamkrishnap"></a>
  <a href="https://github.com/Stoltembergg"><img src="https://avatars.githubusercontent.com/u/312632452?v=4&s=48" width="48" height="48" alt="Stoltembergg"></a>
  <a href="https://github.com/andckadir"><img src="https://avatars.githubusercontent.com/u/175446585?v=4&s=48" width="48" height="48" alt="andckadir"></a>
  <a href="https://github.com/ArseniiTkachuk"><img src="https://avatars.githubusercontent.com/u/257102547?v=4&s=48" width="48" height="48" alt="ArseniiTkachuk"></a>
  <a href="https://github.com/MCUxDaredevil"><img src="https://avatars.githubusercontent.com/u/59441946?v=4&s=48" width="48" height="48" alt="MCUxDaredevil"></a>
  <a href="https://github.com/MILKv2"><img src="https://avatars.githubusercontent.com/u/142674287?v=4&s=48" width="48" height="48" alt="MILKv2"></a>
  <a href="https://github.com/pedrolourencosilva"><img src="https://avatars.githubusercontent.com/u/184855780?v=4&s=48" width="48" height="48" alt="pedrolourencosilva"></a>
  <a href="https://github.com/Vaspyyy"><img src="https://avatars.githubusercontent.com/u/197029450?v=4&s=48" width="48" height="48" alt="Vaspyyy"></a>
  <a href="https://github.com/Sergi122"><img src="https://avatars.githubusercontent.com/u/171693999?v=4&s=48" width="48" height="48" alt="Sergi122"></a>
  <a href="https://github.com/Syrup5845"><img src="https://avatars.githubusercontent.com/u/310795939?v=4&s=48" width="48" height="48" alt="Syrup5845"></a>
  <a href="https://github.com/forteleaf"><img src="https://avatars.githubusercontent.com/u/14119264?v=4&s=48" width="48" height="48" alt="forteleaf"></a>
  <a href="https://github.com/kranks-uga"><img src="https://avatars.githubusercontent.com/u/179175113?v=4&s=48" width="48" height="48" alt="kranks-uga"></a>
  <a href="https://github.com/zynx-real"><img src="https://avatars.githubusercontent.com/u/320626542?v=4&s=48" width="48" height="48" alt="zynx-real"></a>
</div>


## License

Copyright (C) 2026 Illia Miroshnichenko and the contributors of this edition.

Licensed under the GNU Affero General Public License version 3, or (at your option) any later version, like
upstream. See [LICENSE.md](LICENSE.md) for the full text.
