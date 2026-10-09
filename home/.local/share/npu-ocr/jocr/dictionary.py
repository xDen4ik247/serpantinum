"""JMdict lookup (EN + RU glosses) from ~/.local/share/npu-ocr/jmdict.db (built by build_jmdict.py)."""
import json
import os
import sqlite3
import threading

DB = os.path.expanduser("~/.local/share/npu-ocr/jmdict.db")
_local = threading.local()


def _con():
    if not hasattr(_local, "con"):
        _local.con = sqlite3.connect("file:" + DB + "?mode=ro", uri=True) if os.path.exists(DB) else None
    return _local.con


def lookup(*forms):
    """First matching entry for any of the forms -> {word, kanji, kana, en: [senses], ru: [senses]} or None."""
    con = _con()
    if con is None:
        return None
    for f in forms:
        if not f:
            continue
        r = con.execute("SELECT e.kanji, e.kana, e.en, e.ru FROM idx i JOIN entry e ON e.id = i.id "
                        "WHERE i.form = ? ORDER BY e.common DESC, i.prio LIMIT 1", (f,)).fetchone()
        if r:
            return {"word": f, "kanji": json.loads(r[0]), "kana": json.loads(r[1]),
                    "en": json.loads(r[2]), "ru": json.loads(r[3])}
    return None
