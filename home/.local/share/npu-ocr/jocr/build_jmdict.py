"""Build ~/.local/share/npu-ocr/jmdict.db (word -> reading, English / Russian glosses) from the
quiz worker's JMdict.gz (read-only source). Run once: python -m jocr.build_jmdict [JMdict.gz]"""
import gzip
import json
import os
import sqlite3
import sys
import xml.etree.ElementTree as ET

SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Projects/jp-quiz/data/raw/JMdict.gz")
DB = os.path.expanduser("~/.local/share/npu-ocr/jmdict.db")
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"


def main():
    tmp = DB + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    con = sqlite3.connect(tmp)
    con.execute("CREATE TABLE entry(id INTEGER PRIMARY KEY, kanji TEXT, kana TEXT, en TEXT, ru TEXT, common INTEGER)")
    con.execute("CREATE TABLE idx(form TEXT, id INTEGER, prio INTEGER)")
    n = 0
    with gzip.open(SRC) as f:
        for _, el in ET.iterparse(f, events=("end",)):
            if el.tag != "entry":
                continue
            eid = int(el.findtext("ent_seq"))
            kebs = [k.findtext("keb") for k in el.findall("k_ele")]
            rebs = [r.findtext("reb") for r in el.findall("r_ele")]
            common = int(any(p.text and (p.text.startswith(("news1", "ichi1", "spec", "gai1"))) for p in el.iter("ke_pri"))
                         or any(p.text and p.text.startswith(("news1", "ichi1", "spec", "gai1")) for p in el.iter("re_pri")))
            en, ru = [], []
            for s in el.findall("sense"):
                g_en = [g.text for g in s.findall("gloss") if g.get(XML_LANG, "eng") == "eng" and g.text]
                g_ru = [g.text for g in s.findall("gloss") if g.get(XML_LANG) == "rus" and g.text]
                if g_en:
                    en.append("; ".join(g_en[:4]))
                if g_ru:
                    ru.append("; ".join(g_ru[:4]))
            con.execute("INSERT INTO entry VALUES(?,?,?,?,?,?)",
                        (eid, json.dumps(kebs, ensure_ascii=False), json.dumps(rebs, ensure_ascii=False),
                         json.dumps(en[:5], ensure_ascii=False), json.dumps(ru[:5], ensure_ascii=False), common))
            for i, k in enumerate(kebs):
                con.execute("INSERT INTO idx VALUES(?,?,?)", (k, eid, i + (0 if common else 10)))
            for i, r in enumerate(rebs):
                con.execute("INSERT INTO idx VALUES(?,?,?)", (r, eid, i + (5 if kebs else 0) + (0 if common else 10)))
            n += 1
            el.clear()
    con.execute("CREATE INDEX idx_form ON idx(form)")
    con.commit()
    con.close()
    os.replace(tmp, DB)
    print(n, "entries ->", DB)


if __name__ == "__main__":
    main()
