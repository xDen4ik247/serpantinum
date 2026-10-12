"""Lyrics resolver: matching, write-once files, "wrong lyrics" -> next candidate (no network)."""
import os
import tempfile
import unittest

from glassmusic import lyrics, lyricsfetch

SYNCED_A = "[00:01.00]First line of the song\n[00:04.00]Second line here\n[00:08.00]Third one"
SYNCED_B = "[00:01.50]Another take on line one\n[00:04.50]And another second line"
PLAIN = "Only plain words\nwith no timing at all"
META = {"artist": "Northern Lamp", "title": "Paper Boats", "album": "Tides", "duration": 201.0}


class FakeResolver(lyricsfetch.Resolver):
    """Candidates come from a list instead of Yandex / LRCLIB."""
    cands = []

    def candidates(self, path, meta):
        yield from self.cands


class MatchTest(unittest.TestCase):
    def test_matches(self):
        m = lyricsfetch.matches
        self.assertTrue(m(META, "Paper Boats", "Northern Lamp", 202.5))
        self.assertTrue(m(META, "Paper Boats (feat. Someone)", "Northern Lamp, Someone", 200))
        self.assertTrue(m(META, "Paper Boats - 2020 Remaster", "northern lamp", 201))
        self.assertFalse(m(META, "Paper Boats", "Northern Lamp", 230))       # other version
        self.assertFalse(m(META, "Paper Planes", "Northern Lamp", 201))
        self.assertFalse(m(META, "Paper Boats", "Somebody Else", 201))
        ru = {"artist": "Северный Ветер", "title": "Ёлка", "duration": 180}
        self.assertTrue(m(ru, "Елка", "Северный ветер", 181))


class ResolverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lib = os.path.join(self.tmp.name, "lib")
        os.makedirs(os.path.join(self.lib, "A"))
        self.song = os.path.join(self.lib, "A", "1 - Song.m4a")
        open(self.song, "wb").close()
        self.r = FakeResolver(self.lib, os.path.join(self.tmp.name, "cache"))

    def tearDown(self):
        self.tmp.cleanup()

    def test_synced_written_next_to_song_once(self):
        self.r.cands = [("LRCLIB", PLAIN, False), ("LRCLIB", SYNCED_A, True)]
        self.assertTrue(self.r.due(self.song))
        self.assertTrue(self.r.resolve(self.song, META))
        lrc = self.song[:-4] + ".lrc"
        self.assertTrue(os.path.exists(lrc))
        got = self.r.load(self.song)
        self.assertTrue(got["synced"])
        self.assertEqual(got["origin"], "LRCLIB")
        self.assertFalse(self.r.due(self.song))                 # synced now: never asked again

    def test_plain_then_not_due_for_a_while(self):
        self.r.cands = [("Yandex Music", PLAIN, False)]
        self.r.resolve(self.song, META)
        self.assertTrue(os.path.exists(self.song[:-4] + ".txt"))
        got = self.r.load(self.song)
        self.assertFalse(got["synced"])
        self.assertEqual(len(got["lines"]), 2)
        self.assertFalse(self.r.due(self.song))

    def test_nothing_found(self):
        self.r.cands = []
        self.assertFalse(self.r.resolve(self.song, META))
        self.assertEqual(self.r.load(self.song)["lines"], [])
        self.assertFalse(self.r.due(self.song))                 # a miss is remembered

    def test_instrumental(self):
        self.r.cands = [("LRCLIB", "", None)]
        self.r.resolve(self.song, META)
        self.assertTrue(self.r.load(self.song)["instrumental"])

    def test_users_file_never_overwritten_and_wrong_goes_to_next(self):
        lrc = self.song[:-4] + ".lrc"
        with open(lrc, "w", encoding="utf-8") as fh:
            fh.write(SYNCED_A)
        self.assertFalse(self.r.due(self.song))
        self.r.cands = [("LRCLIB", SYNCED_A, True), ("LRCLIB", SYNCED_B, True)]
        self.r.q.put = lambda item: None                         # no background thread in tests
        self.assertTrue(self.r.reject(self.song, META))
        with open(lrc, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), SYNCED_A)                # the user's file is untouched
        self.assertEqual(self.r.load(self.song)["lines"], [])   # ...but no longer shown
        self.r.resolve(self.song, META)
        got = self.r.load(self.song)
        self.assertTrue(got["synced"])
        self.assertEqual(got["source"], "cache")
        self.assertEqual(got["lines"][0]["x"], "Another take on line one")

    def test_own_file_moved_away_when_wrong(self):
        self.r.cands = [("LRCLIB", SYNCED_A, True)]
        self.r.resolve(self.song, META)
        self.r.q.put = lambda item: None
        self.r.reject(self.song, META)
        self.assertFalse(os.path.exists(self.song[:-4] + ".lrc"))
        self.assertTrue(os.listdir(os.path.join(self.r.dir, "rejected")))
        self.r.cands = [("LRCLIB", SYNCED_A, True), ("LRCLIB", SYNCED_B, True)]
        self.r.resolve(self.song, META)
        self.assertEqual(lyrics.load_path(self.song)["lines"][0]["x"], "Another take on line one")


if __name__ == "__main__":
    unittest.main()
