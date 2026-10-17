# JP Quiz — endless adaptive Japanese quiz (N5 → N3, plus everyday words)

A liquid-glass quickshell window (`qml/`) driven by a Rust engine (`engine/`, `jp-quiz-engine`).
It quizzes **particles, conjugation and grammar, sentence meaning, 並べ替え word order,
kanji reading/writing in context and vocabulary in context**, built from ~50 000 items made from
real Tatoeba sentences, and picks every next question so that you succeed about 75 % of the time.
About 14 700 of them teach **everyday words beyond the JLPT lists** (slang, tech, brands, cars, food,
daily life); a new one comes up about every sixth question, even while reviews are due.

After each answer the sentence's words are glossed from JMdict **in the sense they have in that
sentence** (the sense whose glosses match the sentence's own translation; set phrases like その通り
are glossed as one unit). Conjugation questions only offer real forms of the verb.

Open it with **Mod+J** or `jp-quiz` (focuses the open window if there is one, via the shared
`niri-focus-or-run` helper in `~/.local/bin`). Keys: `1–4` answer · `Space` skip · `Enter` next ·
`A` add to Anki (right or wrong; during the next question it adds the one you just passed) · `W` hold
the result · `F` furigana · `L` EN/RU · `R` rank tab (`←→` words / kanji / grammar, `T` placement test) ·
`G` grammar tab (`↑↓` choose, `Enter` drill only that point, `X` drill off) · `Tab` cycles
Stats → Rank → Details → Grammar → quiz (Stats: `S` sync with Anki, `K` auto-add misses, `V` Anki reviews,
`←→` target) · `Esc` back.

**Anki reviews** (off by default; `V` in Stats). While Anki is open, every third question is a due card
from your own decks (learning cards first, then the most overdue), asked as multiple choice inside its
example sentence: the kana reading of the highlighted word (`Anki · reading`) or what it means
(`Anki · meaning`). Your answer goes back to Anki as a real review through AnkiConnect `answerCards`:
right → Pass (ease 3), wrong → Fail (ease 1), so Anki/FSRS reschedules the card as if you had reviewed it
there. `Space` skips without grading (the card stays due). A card already reviewed elsewhere is not asked
(checked with `areDue` right before). If Anki is closed the quiz carries on without them (one toast), and
answers given while it was gone are sent when it is back. Reviews earn XP and count for the day, move the
quiz's own estimate of that word a little, and don't touch your quiz rating. Not yet: audio, new cards,
grammar-deck cards (skipped: there is nothing fair to ask). The write path is the only one: `anki.rs`
allows `answerCards` and nothing else that changes Anki.

**Safety net.** A held or bumped key can't burn through questions: key auto-repeat never answers, skips or
moves on; a question ignores input for its first moment; and the engine refuses any answer or skip faster
than 0.4 s (the question just stays). `U` undoes the last answer — rating, memory, day count and all — up to
50 in a row.

**Thinking time.** Each question has a generous budget (about 20–60 s by type, plus sentence length),
shown as a bar with the seconds left. It pauses while a stats/grammar view is open. Speed earns
nothing extra; only going past the budget trims the XP (×0.6) and counts the answer as "hard".

## Rank: how much of real Japanese you know

The Rank tab measures you against **full lists**, not against what the quiz happens to contain:

| Tier | Words (JLPT) | Everyday words | Kanji | Grammar |
|---|---|---|---|---|
| N5 | 667 | 400 | 79 | 64 |
| N4 | 630 | 600 | 166 | 79 |
| N3 | 1 651 | 1 400 | 367 | 88 |
| N2 | 1 738 | 1 800 | 367 | 101 |
| N1 | 3 061 | 2 800 | 1 232 | 109 |
| 常用 | — | 3 000 | 172 (the rest of the 2 136 常用漢字) | — |

* A tier is **reached** at 80 % of *every* part of it and of all tiers below it. Known = remembered for
  three weeks or more (memory stability ≥ 21 days from the quiz's cards, or an Anki card with an
  interval ≥ 21 days — sync with `S` in Stats so your Anki words count).
* **Placement test** (`T` in the Rank tab, ~3 min): a few words and grammar points per tier from N5 up,
  "don't know" allowed, guesses corrected for; it estimates what you already know so the ladder starts
  where you are. Real review data replaces the estimate as soon as it shows more.
* The HUD badge (top left) shows the same rank: last tier reached → next tier and how far. Reaching a
  tier gets one quiet toast; nothing loops.
* What is left in the tier you are on: the next words to learn (the quiz's own first), a kanji grid,
  the grammar list. ◌ marks what the quiz does not teach yet — learn those in Anki.
* **Daily goal, automatic:** the questions per day (the ring in the HUD) are chosen from your own pace
  (seconds per question, accuracy, reviews a new item needs, upkeep of what you know): the time that reaches
  the next tier in about three months, kept between 15 and 45 minutes, with the date it gets you there.
* Everyday words: ranked by real use (wordfreq: web, subtitles, social media), checked against JMdict;
  90 % written with 常用 kanji, 7.5 % kana only, 2.5 % with other kanji people actually see. The JLPT has
  had no official grammar list since 2010; `assets/jlpt/grammar.tsv` is the grammar commonly taught per level.

## How the matchmaking works (plain words)

* **Everything has a rating.** You have a global rating plus ratings per category (particles, grammar,
  kanji, vocab, reading), per question format and per skill tag (each particle, each grammar point,
  each kanji and word). Every item has a difficulty on the same scale (Elo-like: 1500 ≈ between N5 and N4).
* **Each rating knows how sure it is** (like Glicko's rating deviation). New skills move fast,
  well-known ones slowly. After every answer all ratings involved, and the item's difficulty,
  are updated together in one Bayesian step (an IRT/Rasch logistic model with a guessing floor for
  multiple choice).
* **The rating you see is protected from streaky drops.** Missing a question you had an 87 % chance at
  costs the model ~25 points, a hit earns ~4: honest for choosing questions, harsh to look at. So the
  shown rating moves with every answer: gains in full, drops at 35 %, the gap above the model shrinks 10 %
  per answer and never exceeds 60, and it never falls more than 60 below the model's own best of the
  last 7 days (a real decline still shows once those peaks expire). Matchmaking keeps using the model.
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
| `engine/src/` | the engine (`jp-quiz-engine`): `model.rs` ratings, `memory.rs` FSRS, `engine.rs` selection/game/persistence, `rank.rs` the Rank tab, `anki.rs` AnkiConnect (reads; `answerCards` for reviews) + `anki-add`, `review.rs` Anki review questions, `main.rs` JSON-lines bridge (tests: `engine/tests/anki_reviews.rs`, a fake AnkiConnect) |
| `engine/src/bin/jlpt-syllabus.rs` | builds `assets/jlpt/{vocab,kanji,everyday}.tsv` from `data/raw/` (compiled into the engine) |
| `engine/src/bin/everyday-pack.rs` | adds the everyday-word questions to `data/content.db` (run by `install.sh`) |
| `assets/jlpt/` | the lists: JLPT words, kanji + 常用, grammar (hand-written), everyday words, hand-picked extras |
| `qml/` | the window (quickshell `FloatingWindow`); `Rank.qml` + `Medal.qml` the Rank tab |
| `build/`, `jpquiz/`, `tests/` | the original Python content build and engine: frozen legacy (the project is Rust-only now), kept until the content build is ported |

Install/update the runnable copy with `./install.sh` (needs `cargo`; progress in
`~/.local/share/jp-quiz/progress.db` is kept). It needs `data/content.db` (the content build output) and runs
the everyday pack when `data/raw/` is there (`build/fetch.sh` downloads it; wordfreq goes in `data/raw/wordfreq/`).
Rebuild the lists: `cargo run --release --bin jlpt-syllabus -- data/raw assets/jlpt`.

## Data and licenses

* **Tatoeba** sentences (Japanese, English, Russian), CC BY 2.0 FR — https://tatoeba.org.
  Each item keeps its sentence ids (`src`).
* **JMdict**, **KANJIDIC2**, **KRADFILE** — © EDRDG, CC BY-SA 4.0 (https://www.edrdg.org/edrdg/licence.html).
* **JLPT vocabulary/kanji lists** by Jonathan Waller (tanos.co.uk), CC BY; JMdict ids from
  stephenmk/yomitan-jlpt-vocab (CC BY-SA 4.0); JLPT kanji levels via davidluzgouveia/kanji-data.
* **wordfreq** (Robyn Speer et al.), CC BY-SA 4.0 — word frequencies for the everyday list.
* Tokenization at build time (legacy content build): fugashi + unidic-lite (BSD/MIT; UniDic BSD).
* Grammar list and explanations, distractor rules and code: written for this project.
