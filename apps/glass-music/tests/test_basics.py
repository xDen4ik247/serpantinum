"""Run: python -m unittest discover -s tests -t .   (no MPD needed)"""
import unittest

from glassmusic import search
from glassmusic.server import parse_lrc

LIB = {
    "tracks": [
        {"t": "Static", "a": "nebula", "al": "Afterglow"},
        {"t": "Статика-полночь", "a": "nebula", "al": "Afterglow"},
        {"t": "夜に歩く", "a": "SORAMIMI", "al": "FIRST LIGHT"},
        {"t": "Ёлка", "a": "Северный Ветер", "al": "Акустический альбом"},
    ],
    "albums": [{"k": "nebula/Afterglow", "n": "Afterglow", "ar": "nebula"},
               {"k": "SORAMIMI/FIRST LIGHT", "n": "FIRST LIGHT", "ar": "SORAMIMI"}],
    "artists": [{"n": "nebula"}, {"n": "SORAMIMI"}, {"n": "Северный Ветер"}],
}


class SearchTest(unittest.TestCase):
    def setUp(self):
        self.ix = search.Index(LIB)

    def test_plain(self):
        r = self.ix.search("nebu")
        self.assertEqual(r["artists"], ["nebula"])
        self.assertEqual(r["top"], {"kind": "artist", "ref": "nebula"})

    def test_cyrillic_translit_and_layout(self):
        self.assertEqual(self.ix.search("небула")["artists"], ["nebula"])   # transliterated
        self.assertEqual(self.ix.search("туигдф")["artists"], ["nebula"])   # typed on the RU layout
        self.assertIn(1, self.ix.search("статика")["tracks"])
        self.assertEqual(self.ix.search("ctdthysq")["artists"], ["Северный Ветер"])  # US layout for "северный"

    def test_yo_and_japanese(self):
        self.assertIn(3, self.ix.search("елка")["tracks"])
        self.assertIn(2, self.ix.search("夜に")["tracks"])

    def test_kana_folding(self):
        self.assertEqual(search.norm("ソラミミ"), search.norm("そらみみ"))

    def test_empty(self):
        self.assertIsNone(self.ix.search("   ")["top"])


class LrcTest(unittest.TestCase):
    def test_parse(self):
        lines = parse_lrc("[ar:x]\n[00:00.00]\n[00:01.50]Hello\n[00:03.00][00:10.00]Twice\n[00:05.00]\n[00:06.00]\n[00:07.25]<00:07.25>word <00:07.80>level")
        self.assertEqual([l["x"] for l in lines], ["Hello", "Twice", "", "word level", "Twice"])
        self.assertAlmostEqual(lines[0]["t"], 1.5)

    def test_offset(self):
        self.assertAlmostEqual(parse_lrc("[offset:+500]\n[00:02.00]a")[0]["t"], 1.5)


if __name__ == "__main__":
    unittest.main()
