# Serpantinum Glass — notes for Claude

## Language: Rust only (user decision, 2026-10-15)

This project is full Rust from now on.

- Every new feature, engine, helper, CLI, daemon and build/content tool is written in **Rust**.
  The UI stays QML (quickshell); tiny shell glue (`bin/` launchers, install scripts) is fine.
- **No new Python.** The Python code that still exists (`apps/jp-quiz/jpquiz/` and `apps/jp-quiz/build/`,
  `apps/glass-music/glassmusic/`, `apps/glass-mail/glassmail/`, Python helpers under `home/.local/`) is frozen
  legacy: don't extend it and don't keep it in parity with new Rust features. When a change needs a
  Python part, port that part to Rust instead.
- jp-quiz: the engine is `apps/jp-quiz/engine/` (`jp-quiz-engine`). New commands/features go there only;
  the Python engine fallback no longer gets them.

## Always install what you finish (user decision, 2026-10-15)

When a change is done and verified, install it without being asked, so the running desktop matches the repo:
- apps: `apps/<app>/install.sh` (jp-quiz, glass-music, glass-mail). They keep user data (progress, libraries).
- jp-quiz: `install.sh` needs `apps/jp-quiz/data/content.db` (the content build output, not in git; the working
  copy with `data/raw/` lives in `~/Projects/jp-quiz/data` — symlink it as `apps/jp-quiz/data` if it's missing).
- An app that is open keeps running the old code: say so and tell the user to reopen it instead of killing it.
- Mention in the final reply what was installed where.
