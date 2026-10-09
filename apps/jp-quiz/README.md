# JP Quiz — endless adaptive Japanese quiz (N5 → N3)

A liquid-glass quickshell window (`qml/`) driven by a small Python engine (`jpquiz/`).
It quizzes **particles, conjugation and grammar, sentence meaning, 並べ替え word order,
kanji reading/writing in context and vocabulary in context**, built from ~37 000 items made from
real Tatoeba sentences, and picks every next question so that you succeed about 75 % of the time.

Open it with **Mod+J** or `jp-quiz` (focuses the open window if there is one, via the shared
`niri-focus-or-run` helper in `~/.local/bin`). Keys: `1–4` answer · `Space` skip · `Enter` next ·
`A` add the item to Anki · `F` furigana · `L` EN/RU · `Tab` stats (`S` sync with Anki, `K` auto-add
misses, `←→` target) · `Esc` close.

## How the matchmaking works (plain words)

* **Everything has a rating.** You have a global rating plus ratings per category (particles, grammar,
  kanji, vocab, reading), per question format and per skill tag (each particle, each grammar point,
  each kanji and word). Every item has a difficulty on the same scale (Elo-like: 1500 ≈ between N5 and N4).
* **Each rating knows how sure it is** (like Glicko's rating deviation). New skills move fast,
  well-known ones slowly. After every answer all ratings involved, and the item's difficulty,
  are updated together in one Bayesian step (an IRT/Rasch logistic model with a guessing floor for
  multiple choice).
* **Matchmaking:** for ~200 candidates the engine predicts your chance of success and prefers
  the ones closest to the **target (75 %)**. A small controller nudges the target up when you are
  struggling and down when you are cruising, so your real success rate stays near 75 %.
* **Spaced repetition:** every concept you meet becomes a card (a particle usage, a grammar
  point, a word's reading...). An FSRS memory model tracks when you are likely to forget it; misses
  come back after a few minutes, due cards get priority, and reviews use *new sentences* for
  the same concept.
* **Progression:** a 12-question placement burst (adaptive, like a computerized test) finds your
  level, then N4 and N3 content and new grammar points unlock as your ratings rise, each with a short
  teaching card.

## Layout

| Path | What |
|---|---|
| `jpquiz/model.py` | rating model (Bayesian Elo / IRT with uncertainty) |
| `jpquiz/memory.py` | FSRS-style memory model |
| `jpquiz/engine.py` | selection, unlocks, game layer (XP, levels, streaks, combo), persistence |
| `jpquiz/anki.py` | Anki: read-only sync via AnkiConnect (port 8770), adds via `~/.local/bin/anki-add` |
| `jpquiz/server.py` | JSON-lines bridge to the QML window |
| `qml/` | the window (quickshell `FloatingWindow`) |
| `build/` | content build: `fetch.sh` then `~/.venvs/jp-quiz/bin/python -m build.make_content` |
| `tests/` | `python -m unittest discover -s tests -t .` (includes simulated learners) |
| `tools/simulate.py` | simulation plot (`docs/simulation.png`) |

Install/update the runnable copy with `./install.sh` (progress in `~/.local/share/jp-quiz/progress.db`
is kept). The build needs `~/.venvs/jp-quiz` with `fugashi unidic-lite numpy`.

## Data and licenses

* **Tatoeba** sentences (Japanese, English, Russian), CC BY 2.0 FR — https://tatoeba.org.
  Each item keeps its sentence ids (`src`).
* **JMdict**, **KANJIDIC2**, **KRADFILE** — © EDRDG, CC BY-SA 4.0 (https://www.edrdg.org/edrdg/licence.html).
* **JLPT vocabulary/kanji lists** by Jonathan Waller (tanos.co.uk), CC BY; JMdict ids from
  stephenmk/yomitan-jlpt-vocab (CC BY-SA 4.0); JLPT kanji levels via davidluzgouveia/kanji-data.
* Tokenization at build time: fugashi + unidic-lite (BSD/MIT; UniDic BSD).
* Grammar explanations, distractor rules and code: written for this project.
