"""Grammar-point catalog (JLPT N5 -> N3) and detectors over UniDic tokens.

Each point knows
  * how to find itself in a tokenized sentence,
  * which verb form its slot requires ("conj" items: 写真を＿もいいですか -> te-form),
  * which other forms would ALSO be grammatical in that slot (never offered
    as distractors, e.g. 行くことがある is fine too, so the dictionary form is
    excluded for 〜たことがある),
  * which meaning family it belongs to, with English keyword checks used to make
    "pick the ending that matches the translation" items unambiguous.

Explanations are written for this app (no third-party text).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from jpquiz.conjugate import conjugate_verb, conjugate_adj, uni_ctype_to_class


@dataclass
class GP:
    id: str
    level: int                 # JLPT 5 (N5) .. 3 (N3)
    order: int                 # curriculum order (unlock order)
    name: str                  # pattern as shown to the learner
    en: str                    # short meaning
    ru: str
    explain_en: str
    explain_ru: str
    diff: float = 0.0          # seed difficulty offset (logits)
    slot_form: str | None = None
    exclude: tuple = ()
    family: str | None = None
    kw: str | None = None      # regex the English translation must match


GPS: list[GP] = [
    # ---------------- N5 ----------------
    GP("polite", 5, 1, "〜ます / 〜ません / 〜ました", "polite verb endings", "вежливые окончания глагола",
       "Polite form: masu-stem + ます (now/future), ません (not), ました (did), ませんでした (didn't).",
       "Вежливая форма: основа на -и + ます (наст./буд.), ません (не), ました (прош.), ませんでした (не ... в прошлом).", -0.6),
    GP("plain-past-neg", 5, 2, "〜た / 〜ない / 〜なかった", "plain past & negative", "простое прошедшее и отрицание",
       "Plain forms: た-form = past, ない-form = negative, なかった = past negative.",
       "Простые формы: た — прошедшее, ない — отрицание, なかった — прошедшее отрицание.", -0.4),
    GP("adj-forms", 5, 3, "〜かった / 〜くない", "adjective tense & negation", "время и отрицание прилагательных",
       "い-adjectives: 高い -> 高かった (was), 高くない (isn't), 高くなかった (wasn't). な-adjectives use だった / じゃない like nouns.",
       "い-прилагательные: 高い -> 高かった, 高くない, 高くなかった. な-прилагательные — как существительные: だった / じゃない.", -0.3),
    GP("te-iru", 5, 4, "〜ている", "is doing / state", "длительное действие / состояние",
       "te-form + いる: an action in progress (読んでいる 'is reading') or a resulting state (結婚している 'is married').",
       "て-форма + いる: действие в процессе (読んでいる «читает») или состояние-результат (結婚している «женат»).",
       -0.2, "te", ("naide", "nakute")),
    GP("te-kudasai", 5, 5, "〜てください", "please do", "пожалуйста, сделайте",
       "te-form + ください: a polite request (見てください 'please look').",
       "て-форма + ください: вежливая просьба (見てください «посмотрите, пожалуйста»).",
       -0.3, "te", ("naide",)),
    GP("tai", 5, 6, "〜たい", "want to", "хотеть",
       "masu-stem + たい: 'want to do' (食べたい 'I want to eat'). It conjugates like an い-adjective: たくない, たかった.",
       "основа на -и + たい: «хочу» (食べたい). Спрягается как い-прилагательное: たくない, たかった.",
       -0.3, "stem", ("te",), "MODAL",
       r"\b(want|wants|wanted|wanna|would like|'d like|wish|wishes|feel like)\b"),
    GP("mashou", 5, 7, "〜ましょう", "let's", "давайте",
       "masu-stem + ましょう: 'let's' (行きましょう). ましょうか offers: 'shall I/we?'.",
       "основа на -и + ましょう: «давайте» (行きましょう). ましょうか — предложение «может, я…?».",
       -0.4, "stem", ()),
    GP("ni-iku", 5, 8, "〜に行く", "go to do", "идти, чтобы…",
       "masu-stem + に + 行く/来る/帰る: the purpose of going (買いに行く 'go to buy').",
       "основа на -и + に + 行く/来る: цель движения (買いに行く «пойти купить»).",
       -0.1, "stem", ()),
    GP("naide-kudasai", 5, 9, "〜ないでください", "please don't", "пожалуйста, не…",
       "ない-form + でください: a polite negative request (触らないでください 'please don't touch').",
       "ない-форма + でください: вежливая просьба не делать (触らないでください).",
       0.0, "naide", ("te",)),
    GP("mae-ni", 5, 10, "〜前に", "before doing", "перед тем как",
       "dictionary form + 前に: 'before doing' (寝る前に 'before sleeping'). The verb stays in the dictionary form even for past events.",
       "словарная форма + 前に: «перед тем как» (寝る前に). Глагол всегда в словарной форме.",
       0.0, "dict", ("nai",), "CONN", r"\bbefore\b"),
    GP("ato-de", 5, 11, "〜た後で", "after doing", "после того как",
       "た-form + 後で: 'after doing' (食べた後で 'after eating').",
       "た-форма + 後で: «после того как» (食べた後で).",
       0.1, "ta", (), "CONN", r"\bafter\b"),
    GP("te-kara", 5, 12, "〜てから", "after doing / since", "после того как",
       "te-form + から: 'after doing X, (then)…' (食べてから出かける 'go out after eating').",
       "て-форма + から: «сделав X, потом…» (食べてから出かける).",
       0.1, None, (), "CONN", r"\bafter\b"),
    GP("kara-reason", 5, 13, "〜から", "because", "потому что",
       "plain/polite form + から: gives a reason (寒いから 'because it's cold').",
       "форма + から: причина (寒いから «потому что холодно»).",
       0.0, None, (), "CONN", r"\b(because|since|so)\b"),
    GP("kedo", 5, 14, "〜けど / 〜が", "but", "но",
       "clause + けど (casual) / が (polite): 'but, although' (高いけど買う 'it's expensive, but I'll buy it').",
       "предложение + けど / が: «но, хотя» (高いけど買う).",
       0.0, None, (), "CONN", r"\b(but|although|though|however)\b"),
    # ---------------- N4 ----------------
    GP("te-mo-ii", 4, 20, "〜てもいい", "may / it's OK to", "можно",
       "te-form + もいい: permission (座ってもいいですか 'may I sit?').",
       "て-форма + もいい: разрешение (座ってもいいですか «можно сесть?»).",
       0.2, "te", ("nakute",), "MODAL",
       r"\b(may|can|could|allowed|ok|okay|all right|alright|mind if|permitted)\b"),
    GP("te-wa-ikenai", 4, 21, "〜てはいけない", "must not", "нельзя",
       "te-form + はいけない: prohibition (吸ってはいけません 'you must not smoke').",
       "て-форма + はいけない: запрет (吸ってはいけません «курить нельзя»).",
       0.3, "te", ("nakute",), "MODAL",
       r"\b(must not|mustn't|not allowed|shouldn't|should not|can't|cannot|may not|forbidden|prohibited|don't|not supposed)\b"),
    GP("nakereba", 4, 22, "〜なければならない", "must / have to", "должен",
       "ない-stem + なければならない (or なければなりません): obligation (行かなければならない 'I have to go').",
       "ない-основа + なければならない: обязанность (行かなければならない «нужно идти»).",
       0.4, "a_stem", (), "MODAL",
       r"\b(must(?! not| n't)|have to|has to|had to|need to|needs to|needed to|got to|gotta|obliged)\b"),
    GP("nakute-mo-ii", 4, 23, "〜なくてもいい", "don't have to", "не обязательно",
       "ない-form → なくてもいい: no obligation (来なくてもいい 'you don't have to come').",
       "なくてもいい: нет необходимости (来なくてもいい «можно не приходить»).",
       0.4, "nakute", ("te",)),
    GP("ta-koto-ga-aru", 4, 24, "〜たことがある", "have done (experience)", "опыт: доводилось",
       "た-form + ことがある: life experience (行ったことがある 'I have been there').",
       "た-форма + ことがある: жизненный опыт (行ったことがある «бывал»).",
       0.2, "ta", ("dict", "nai", "nakatta")),
    GP("koto-ga-dekiru", 4, 25, "〜ことができる", "can (ability)", "мочь, уметь",
       "dictionary form + ことができる: ability or possibility (泳ぐことができる 'can swim').",
       "словарная форма + ことができる: умение или возможность (泳ぐことができる).",
       0.2, "dict", ("nai", "ta")),
    GP("hou-ga-ii", 4, 26, "〜たほうがいい", "had better / should", "лучше бы",
       "た-form + ほうがいい: advice (休んだほうがいい 'you should rest'). Negative advice: ないほうがいい.",
       "た-форма + ほうがいい: совет (休んだほうがいい «тебе лучше отдохнуть»).",
       0.3, "ta", ("dict", "nai"), "MODAL",
       r"\b(should|had better|'d better|ought|advisable|better)\b"),
    GP("tsumori", 4, 27, "〜つもり", "intend to", "собираюсь",
       "dictionary form + つもり: intention (行くつもりです 'I intend to go').",
       "словарная форма + つもり: намерение (行くつもりです «собираюсь пойти»).",
       0.2, "dict", ("nai", "ta"), "MODAL",
       r"\b(intend|intends|intended|plan|plans|planning|planned|going to|gonna|mean to)\b"),
    GP("nagara", 4, 28, "〜ながら", "while doing", "одновременно",
       "masu-stem + ながら: two actions at once (歩きながら 'while walking').",
       "основа на -и + ながら: два действия одновременно (歩きながら «на ходу»).",
       0.1, "stem", (), "CONN", r"\bwhile\b"),
    GP("sugiru", 4, 29, "〜すぎる", "too much", "слишком",
       "masu-stem / adjective stem + すぎる: excess (食べすぎた 'ate too much', 高すぎる 'too expensive').",
       "основа + すぎる: чрезмерность (食べすぎた «переел», 高すぎる «слишком дорого»).",
       0.2, "stem", ()),
    GP("yasui-nikui", 4, 30, "〜やすい / 〜にくい", "easy / hard to do", "легко / трудно делать",
       "masu-stem + やすい (easy to) / にくい (hard to): 読みやすい 'easy to read'.",
       "основа на -и + やすい / にくい: 読みやすい «легко читать».",
       0.2, "stem", ()),
    GP("te-shimau", 4, 31, "〜てしまう", "end up / completely", "закончить; к сожалению",
       "te-form + しまう: completion or regret (忘れてしまった 'I (accidentally) forgot').",
       "て-форма + しまう: завершённость или сожаление (忘れてしまった).",
       0.3, "te", ("naide", "nakute")),
    GP("te-oku", 4, 32, "〜ておく", "do in advance", "сделать заранее",
       "te-form + おく: do something in advance / leave it so (買っておく 'buy beforehand').",
       "て-форма + おく: сделать заранее / оставить (買っておく).",
       0.3, "te", ("naide", "nakute"), "ASPECT", r"\b(beforehand|in advance|ahead|prepare|leave)\b"),
    GP("te-aru", 4, 33, "〜てある", "has been done", "сделано (кем-то)",
       "transitive te-form + ある: a state left by someone's action (窓が開けてある 'the window has been opened').",
       "переходный глагол в て-форме + ある: состояние после чьего-то действия.",
       0.4, "te", ("naide", "nakute")),
    GP("te-miru", 4, 34, "〜てみる", "try doing", "попробовать",
       "te-form + みる: try something to see (食べてみる 'try eating').",
       "て-форма + みる: попробовать (食べてみる).",
       0.2, "te", ("naide", "nakute"), "ASPECT", r"\btry|tried|tries|trying\b"),
    GP("te-give", 4, 35, "〜てあげる / くれる / もらう", "doing favors", "делать одолжение",
       "te-form + あげる (I do for someone), くれる (someone does for me), もらう (I get someone to do).",
       "て-форма + あげる (для кого-то), くれる (для меня), もらう (получить услугу).",
       0.4, "te", ("naide", "nakute")),
    GP("te-iku-kuru", 4, 36, "〜ていく / 〜てくる", "go / come doing", "уходить / приходить делая",
       "te-form + いく/くる: direction or change over time (持っていく 'take (along)', 寒くなってきた 'it's getting cold').",
       "て-форма + いく/くる: направление или изменение во времени.",
       0.4, "te", ("naide", "nakute")),
    GP("te-hoshii", 4, 37, "〜てほしい", "want someone to", "хочу, чтобы (кто-то)",
       "te-form + ほしい: want someone else to do it (来てほしい 'I want you to come').",
       "て-форма + ほしい: хотеть, чтобы другой сделал (来てほしい).",
       0.4, "te", ("naide", "nakute")),
    GP("volitional", 4, 38, "〜よう / 〜おう", "let's / I'll (plain)", "давай; решу-ка",
       "Volitional: godan う→おう (行こう), ichidan る→よう (食べよう). With と思う: 'I'm thinking of doing'.",
       "Волевая форма: 行こう, 食べよう. С と思う — «думаю сделать».",
       0.4, "volitional", ("dict", "ta", "nai", "masu")),
    GP("potential", 4, 39, "可能形 (〜える / 〜られる)", "can do", "мочь (потенциал)",
       "Potential: godan う→える (話せる), ichidan る→られる (食べられる), する→できる, 来る→来られる.",
       "Потенциальная форма: 話せる, 食べられる, できる, 来られる.",
       0.5, None, (), "VOICE", r"\b(can|could|able|can't|cannot|couldn't)\b"),
    GP("tara", 4, 40, "〜たら", "if / when", "если / когда",
       "た-form + ら: 'if / when' (雨が降ったら 'if it rains').",
       "た-форма + ら: «если / когда» (雨が降ったら).",
       0.4, None, (), "CONN", r"\b(if|when|whenever|once)\b"),
    GP("ba", 4, 41, "〜ば", "if (conditional)", "если",
       "ば-form: godan う→えば (行けば), ichidan る→れば (食べれば), い-adj い→ければ.",
       "ば-форма: 行けば, 食べれば, 高ければ — «если».",
       0.5, "e_stem", (), "CONN", r"\b(if|when|whenever|unless)\b"),
    GP("to-cond", 4, 42, "〜と (条件)", "whenever / if (natural result)", "если (закономерно)",
       "dictionary form + と: a natural or habitual result (押すと開く 'if you push it, it opens').",
       "словарная форма + と: закономерный результат (押すと開く).",
       0.5, None, (), "CONN", r"\b(if|when|whenever|as soon as)\b"),
    GP("node", 4, 43, "〜ので", "because (softer)", "так как",
       "plain form + ので (な-adj/noun + なので): a softer, more objective 'because'.",
       "простая форма + ので: мягкое «так как».",
       0.3, None, (), "CONN", r"\b(because|since|so)\b"),
    GP("noni", 4, 44, "〜のに", "although / despite", "хотя; несмотря на",
       "plain form + のに: contrary to expectation, often with frustration (勉強したのに 'even though I studied').",
       "простая форма + のに: вопреки ожиданию (勉強したのに «хотя я учил»).",
       0.6, None, (), "CONN", r"\b(although|though|even though|despite|in spite)\b"),
    GP("temo", 4, 45, "〜ても", "even if", "даже если",
       "te-form + も: 'even if' (雨が降っても行く 'I'll go even if it rains').",
       "て-форма + も: «даже если» (雨が降っても行く).",
       0.5, None, (), "CONN", r"\b(even if|no matter|even when|whether)\b"),
    GP("sou-looks", 4, 46, "〜そうだ (様態)", "looks like", "похоже, вот-вот",
       "masu-stem / adjective stem + そうだ: it looks like (雨が降りそうだ 'it looks like rain').",
       "основа + そうだ: выглядит так, будто (降りそうだ «вот-вот пойдёт дождь»).",
       0.5, None, (), "SOU", r"\b(look|looks|looked|seem|seems|seemed|appear|appears|about to|likely)\b"),
    GP("sou-hearsay", 4, 47, "〜そうだ (伝聞)", "I hear that", "говорят, что",
       "plain form + そうだ: hearsay (来るそうだ 'I hear he's coming').",
       "простая форма + そうだ: передача слухов (来るそうだ «говорят, придёт»).",
       0.6, None, (), "SOU", r"\b(hear|heard|say|says|said|told|according|apparently|reportedly)\b"),
    GP("hazu", 4, 48, "〜はずだ", "should be (expected)", "должно быть",
       "plain form + はずだ: strong expectation (来るはずだ 'he should come').",
       "простая форма + はずだ: уверенное ожидание (来るはずだ).",
       0.6, "dict", ("nai", "ta", "nakatta")),
    GP("kamoshirenai", 4, 49, "〜かもしれない", "might", "может быть",
       "plain form + かもしれない: possibility (雨かもしれない 'it might rain').",
       "простая форма + かもしれない: возможность (雨かもしれない).",
       0.3, "dict", ("nai", "ta", "nakatta"), "MODAL",
       r"\b(might|maybe|perhaps|possibly|possible)\b"),
    GP("nasai", 4, 50, "〜なさい", "do it! (command)", "сделай! (указание)",
       "masu-stem + なさい: a firm instruction, e.g. from parents or teachers (早く寝なさい 'go to bed').",
       "основа на -и + なさい: строгое указание (早く寝なさい «ложись спать»).",
       0.2, "stem", ()),
    GP("passive", 4, 51, "受身 (〜れる / 〜られる)", "passive", "страдательный залог",
       "Passive: godan う→われる (書かれる), ichidan る→られる (食べられる). The agent takes に.",
       "Страдательный залог: 書かれる, 食べられる. Деятель с に.",
       0.7, None, (), "VOICE", r"\b(was|were|is|are|be|been|being|get|gets|got)\b(\s+\w+ly)?\s+(\w+ed|\w+en|made|told|sent|built|kept|left|lost|paid|sold|taught|caught|bought|brought|thought|found|held|hit|hurt|put|read|set|shut|spent|struck|worn|born|stung|bitten|said|heard|met|fed|led)\b(?! (out|up|in|away|home))"),
    GP("causative", 3, 60, "使役 (〜せる / 〜させる)", "make / let someone do", "заставить / позволить",
       "Causative: godan う→わせる (書かせる), ichidan る→させる (食べさせる): make or let someone do.",
       "Каузатив: 書かせる, 食べさせる — заставить или позволить.",
       0.9, None, (), "VOICE", r"\b(made|make|makes|making|let|lets|letting|had|have|has|forced|allowed)\b\s+\w+\s+\w+"),
    GP("you-ni-naru", 3, 61, "〜ようになる", "come to / become able", "стать (способным)",
       "dictionary / potential form + ようになる: a change in ability or habit (泳げるようになった 'I became able to swim').",
       "словарная/потенциальная форма + ようになる: изменение (泳げるようになった «научился плавать»).",
       0.8, "dict", ("nai",)),
    GP("tame-ni", 3, 62, "〜ために", "in order to", "для того чтобы",
       "dictionary form + ために: purpose (日本へ行くために 'in order to go to Japan').",
       "словарная форма + ために: цель (行くために «чтобы поехать»).",
       0.7, "dict", ("nai",)),
    GP("caus-passive", 3, 63, "使役受身 (〜させられる)", "be made to do", "быть вынужденным",
       "Causative-passive: 食べさせられる / 書かされる 'be made to do'.",
       "Каузативно-страдательная форма: 食べさせられる «заставили съесть».",
       1.1, None, (), "VOICE", r"\b(was|were|am|is|are|be|been|get|got)\s+(forced|made)\s+to\b"),
]
GP_BY_ID = {g.id: g for g in GPS}

# Pairs that must never be contrasted in meaning items (their English overlaps).
NEVER = {frozenset(p) for p in [
    ("tara", "ba"), ("tara", "to-cond"), ("ba", "to-cond"), ("kara-reason", "node"),
    ("noni", "kedo"), ("te-kara", "ato-de"), ("temo", "noni"), ("te-mo-ii", "kamoshirenai"),
    ("nakereba", "hou-ga-ii"), ("hou-ga-ii", "te-wa-ikenai"), ("tsumori", "tai"),
    ("temo", "tara"), ("temo", "ba"), ("tara", "te-kara"), ("tara", "ato-de"), ("to-cond", "te-kara"),
    ("ba", "te-kara"), ("to-cond", "ato-de"), ("tara", "mae-ni"),
]}


def never_contrast(a: str, b: str) -> bool:
    return frozenset((a, b)) in NEVER


# --------------------------------------------------------------------------
# Token helpers
# --------------------------------------------------------------------------

def _is_te(t) -> bool:
    return t.p1 == "助詞" and t.p2 == "接続助詞" and t.l == "て"


def _is(t, lemma=None, p1=None, surf=None, base=None) -> bool:
    if t is None:
        return False
    if lemma is not None and t.l not in (lemma if isinstance(lemma, tuple) else (lemma,)):
        return False
    if p1 is not None and t.p1 != p1:
        return False
    if surf is not None and t.s not in (surf if isinstance(surf, tuple) else (surf,)):
        return False
    if base is not None and t.b not in (base if isinstance(base, tuple) else (base,)):
        return False
    return True


@dataclass
class Unit:
    start: int      # first token (the noun of a suru-verb, else == head)
    head: int       # the conjugating token
    base: str       # written dictionary form, e.g. 食べる / 勉強する / 高い
    cls: str        # conjugation class (v5k, v1, vs-i, adj-i ...)
    pos: str        # "v" or "adj"
    potential: bool = False


def verb_units(toks) -> dict[int, Unit]:
    """Head-index -> Unit for every main verb / i-adjective."""
    out = {}
    for i, t in enumerate(toks):
        if t.p1 == "動詞":
            prev = toks[i - 1] if i > 0 else None
            if prev is not None and _is_te(prev):
                continue           # auxiliary after te (いる, しまう, ...)
            if prev is not None and prev.p1 == "動詞" and t.p2 == "非自立可能" and t.l in ("過ぎる", "出す", "始める", "続ける", "終わる", "合う", "込む"):
                continue
            lemma_base = t.l.split("-")[0]
            base = t.b
            cls = uni_ctype_to_class(t.ct, base)
            potential = False
            if cls == "v1" and t.ct.startswith("下一段") and lemma_base != base and lemma_base and lemma_base[-1] in "うくぐすつぬぶむる":
                # potential verb (話せる from 話す): UniDic keeps the godan lemma
                if base.endswith("る") and lemma_base[:-1] and base.startswith(lemma_base[:-1]):
                    potential = True
            if cls is None:
                continue
            start = i
            if cls == "vs-i":
                if t.b not in ("する",):
                    continue
                if prev is not None and prev.p1 == "名詞" and prev.p3 == "サ変可能":
                    start = i - 1
                    base = prev.s + "する"
                else:
                    base = "する"
            out[i] = Unit(start, i, base, cls, "v", potential)
        elif t.p1 == "形容詞" and t.p2 == "一般":
            cls = uni_ctype_to_class(t.ct, t.b)
            if cls:
                out[i] = Unit(i, i, t.b, cls, "adj")
    return out


@dataclass
class Match:
    gp: str
    unit: Unit
    slot: tuple | None = None     # token span blanked in "conj" items (a, b)
    chunk: tuple | None = None    # token span replaced in meaning items (a, b)
    info: dict = field(default_factory=dict)


FINAL_PARTS = {"か", "よ", "ね", "な", "わ", "の", "ぞ", "さ", "かな", "よね"}


def _pred_end(toks, k) -> int | None:
    """If tokens from k to the end are only final particles/punctuation, return k."""
    j = k
    while j < len(toks):
        t = toks[j]
        if t.p1 == "補助記号":
            j += 1
            continue
        if t.p1 == "助詞" and t.p2 == "終助詞" and t.s in FINAL_PARTS:
            j += 1
            continue
        return None
    return k


def _register_tense(toks, a, b) -> tuple[str, str, bool]:
    lem = [t.l for t in toks[a:b]]
    polite = "ます" in lem or "です" in lem
    past = "た" in lem
    neg = "ない" in lem or "ず" in lem or "ぬ" in lem
    return ("polite" if polite else "plain"), ("past" if past else "nonpast"), neg


def detect(toks) -> list[Match]:
    units = verb_units(toks)
    n = len(toks)
    out: list[Match] = []

    def T(i):
        return toks[i] if 0 <= i < n else None

    for h, u in units.items():
        t = toks[h]
        a = u.start
        nx = T(h + 1)
        if u.pos == "v":
            # ---- te-form constructions
            if nx is not None and _is_te(nx):
                k = h + 2
                after = T(k)
                if after is None:
                    continue
                slot = (a, h + 2)
                if (after.l == "居る" and after.p1 == "動詞") or after.l == "てる":
                    out.append(Match("te-iru", u, slot))
                elif after.l == "下さる" and after.s in ("ください", "下さい"):
                    out.append(Match("te-kudasai", u, slot))
                elif after.s == "も" and _is(T(k + 1), lemma=("良い", "構う")):
                    out.append(Match("te-mo-ii", u, slot))
                elif after.s == "も":
                    out.append(Match("temo", u, None, (a, k + 1)))
                elif after.s == "は" and (_is(T(k + 1), base=("いける",)) or _is(T(k + 1), lemma=("駄目",)) or _is(T(k + 1), lemma=("成る",))):
                    out.append(Match("te-wa-ikenai", u, slot))
                elif after.l == "仕舞う" or after.l in ("ちゃう", "じゃう"):
                    out.append(Match("te-shimau", u, slot))
                elif after.l == "置く" and after.p2 == "非自立可能":
                    out.append(Match("te-oku", u, slot))
                elif after.l == "有る" and after.p2 == "非自立可能":
                    out.append(Match("te-aru", u, slot))
                elif after.l == "見る" and after.p2 == "非自立可能":
                    out.append(Match("te-miru", u, slot))
                elif after.l in ("上げる", "呉れる", "貰う", "頂く", "差し上げる") and after.p2 == "非自立可能":
                    out.append(Match("te-give", u, slot))
                elif after.l in ("行く", "来る") and after.p2 == "非自立可能":
                    out.append(Match("te-iku-kuru", u, slot))
                elif after.l == "欲しい":
                    out.append(Match("te-hoshii", u, slot))
                elif after.s == "から" and after.p1 == "助詞":
                    out.append(Match("te-kara", u, None, (a, k + 1)))
                continue
            if nx is None:
                continue
            # ---- masu-stem constructions
            if nx.l == "たい" and nx.p1 == "助動詞":
                out.append(Match("tai", u, (a, h + 1)))
            elif nx.l == "ます" and nx.cf.startswith("意志推量形"):
                out.append(Match("mashou", u, (a, h + 1)))
            elif nx.s == "に" and nx.p1 == "助詞" and t.cf.startswith("連用形") and _is(T(h + 2), lemma=("行く", "来る", "帰る", "出掛ける")):
                out.append(Match("ni-iku", u, (a, h + 1)))
            elif nx.s == "ながら" and nx.p1 == "助詞":
                out.append(Match("nagara", u, (a, h + 1), (a, h + 2)))
            elif nx.l == "過ぎる":
                out.append(Match("sugiru", u, (a, h + 1)))
            elif nx.l in ("易い", "難い") and nx.p1 == "接尾辞":
                out.append(Match("yasui-nikui", u, (a, h + 1)))
            elif nx.l == "為さる" and nx.s == "なさい":
                out.append(Match("nasai", u, (a, h + 1)))
            # ---- negative constructions
            elif nx.l == "ない" and nx.p1 == "助動詞":
                n2, n3 = T(h + 2), T(h + 3)
                if n2 is not None and _is_te(n2) and n2.s == "で" and _is(n3, lemma="下さる"):
                    out.append(Match("naide-kudasai", u, (a, h + 3)))
                elif nx.s == "なく" and n2 is not None and _is_te(n2) and _is(n3, surf="も") and _is(T(h + 4), lemma=("良い", "構う")):
                    out.append(Match("nakute-mo-ii", u, (a, h + 3)))
                elif nx.s == "なけれ" and _is(n2, surf="ば") and (_is(n3, lemma="成る") or _is(n3, base="いける")):
                    out.append(Match("nakereba", u, (a, h + 1)))
            # ---- ta-form constructions
            elif nx.l == "た" and nx.p1 == "助動詞":
                n2, n3, n4 = T(h + 2), T(h + 3), T(h + 4)
                if nx.s in ("たら", "だら"):
                    out.append(Match("tara", u, None, (a, h + 2)))
                elif _is(n2, lemma="事") and _is(n3, surf="が") and _is(n4, lemma="有る"):
                    out.append(Match("ta-koto-ga-aru", u, (a, h + 2)))
                elif _is(n2, lemma="方") and _is(n3, surf="が") and _is(n4, lemma="良い"):
                    out.append(Match("hou-ga-ii", u, (a, h + 2)))
                elif _is(n2, lemma="後") and _is(n3, surf=("で", "に")):
                    out.append(Match("ato-de", u, (a, h + 2), (a, h + 4)))
            # ---- dictionary-form constructions
            elif t.cf.startswith("終止形") or t.cf.startswith("連体形"):
                n2, n3 = T(h + 2), T(h + 3)
                if _is(nx, lemma="前") and _is(n2, surf="に"):
                    out.append(Match("mae-ni", u, (a, h + 1), (a, h + 3)))
                elif _is(nx, lemma="事") and _is(n2, surf="が") and _is(n3, lemma="出来る"):
                    out.append(Match("koto-ga-dekiru", u, (a, h + 1)))
                elif _is(nx, lemma="積り"):
                    out.append(Match("tsumori", u, (a, h + 1)))
                elif _is(nx, lemma="筈"):
                    out.append(Match("hazu", u, (a, h + 1)))
                elif _is(nx, surf="か") and _is(n2, surf="も") and _is(n3, lemma="知れる"):
                    out.append(Match("kamoshirenai", u, (a, h + 1)))
                elif _is(nx, lemma="様") and _is(n2, surf="に") and _is(n3, lemma="成る"):
                    out.append(Match("you-ni-naru", u, (a, h + 1)))
                elif _is(nx, lemma="為") and _is(n2, surf="に"):
                    out.append(Match("tame-ni", u, (a, h + 1)))
                elif nx.p1 == "助詞" and nx.p2 == "接続助詞" and nx.s == "と":
                    out.append(Match("to-cond", u, None, (a, h + 2)))
                elif nx.p1 == "助詞" and nx.p2 == "接続助詞" and nx.s == "から":
                    out.append(Match("kara-reason", u, None, (a, h + 2)))
                elif nx.p1 == "助詞" and nx.p2 == "接続助詞" and nx.l == "けれど":
                    out.append(Match("kedo", u, None, (a, h + 2)))
                elif nx.s == "の" and nx.p2 == "準体助詞" and _is(n2, surf="で") and n2.p1 == "助動詞":
                    out.append(Match("node", u, None, (a, h + 3)))
                elif nx.s == "の" and nx.p2 == "準体助詞" and _is(n2, surf="に") and _is(n3, surf="、"):
                    out.append(Match("noni", u, None, (a, h + 3)))
                elif nx.l == "そう-伝聞":
                    out.append(Match("sou-hearsay", u, None, (a, h + 2)))
            if t.cf.startswith("仮定形") and _is(nx, surf="ば"):
                out.append(Match("ba", u, (a, h + 1), (a, h + 2)))
            if t.cf.startswith("意志推量形") and _is(nx, surf="と") and _is(T(h + 2), lemma="思う"):
                out.append(Match("volitional", u, (a, h + 1)))
            if t.cf.startswith("連用形") and nx.l == "そう-様態":
                out.append(Match("sou-looks", u, None, (a, h + 2)))
        else:
            # i-adjective heads
            if nx is not None and nx.l == "過ぎる":
                pass
    return out


def has_gp(matches, gid):
    return any(m.gp == gid for m in matches)


def voice_of(toks, h, unit) -> str:
    """active / passive / causative / potential / caus-passive for a verb head."""
    j = h + 1
    seq = []
    while j < len(toks) and toks[j].p1 == "助動詞" and toks[j].l in ("れる", "られる", "せる", "させる"):
        seq.append(toks[j].l)
        j += 1
    if unit.potential:
        return "potential"
    if seq[:2] in (["せる", "られる"], ["させる", "られる"]):
        return "caus-passive"
    if seq[:1] in (["せる"], ["させる"]):
        return "causative"
    if seq[:1] in (["れる"], ["られる"]):
        return "passive"
    return "active"


def keyword_ok(en: str, target: str, alts: list[str]) -> bool:
    """English must contain the target meaning cue and none of the alternatives' cues."""
    g = GP_BY_ID[target]
    if not g.kw or not re.search(g.kw, en, re.I):
        return False
    for a in alts:
        ga = GP_BY_ID.get(a)
        if ga and ga.kw and re.search(ga.kw, en, re.I):
            return False
    return True
