"""Yandex Music helpers. The glassmusic.yandex tests need the venv (yandex-music-downloader +
mutagen) and are skipped without it:
  ~/.local/share/glass-music/yandex-venv/bin/python -m unittest discover -s tests -t .
No network, no MPD, no real ~/Music."""
import os
import shutil
import subprocess
import tempfile
import unittest

from glassmusic import lyrics, removal

try:
    from glassmusic import yandex
    from mutagen.mp4 import MP4
except ImportError:
    yandex = None


class LyricsPathTest(unittest.TestCase):
    def test_outside_library(self):
        d = tempfile.mkdtemp()
        try:
            with open(os.path.join(d, "a.lrc"), "w", encoding="utf-8") as fh:
                fh.write("[00:01.00] one\n[00:02.00] two\n")
            song = os.path.join(d, "a.m4a")
            for rel in (song, "file://" + song):      # MPD reports temp songs by plain path
                r = lyrics.load("/nonexistent-library", rel)
                self.assertTrue(r["synced"], rel)
                self.assertEqual([x["x"] for x in r["lines"]], ["one", "two"])
            self.assertEqual(lyrics.load("/x", "http://example.org/s.mp3")["lines"], [])
        finally:
            shutil.rmtree(d)


def _touch(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


class RemovalTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.lib = os.path.join(self.d, "lib")
        self.tmp = os.path.join(self.d, "tmp")

    def tearDown(self):
        shutil.rmtree(self.d)

    def test_album_and_artist_folders_go_when_empty(self):
        a = os.path.join(self.tmp, "Artist", "Album")
        for n in ("1 - a.m4a", "1 - a.lrc", "2 - b.m4a", "cover.jpg"):
            _touch(os.path.join(a, n))
        removed, failed, rescan = removal.remove([os.path.join(a, "1 - a.m4a")], [self.lib, self.tmp])
        self.assertEqual((len(removed), failed, rescan), (1, [], [a]))     # album still has 2 - b
        self.assertEqual(sorted(os.listdir(a)), ["2 - b.m4a", "cover.jpg"])
        removed, failed, rescan = removal.remove([os.path.join(a, "2 - b.m4a")], [self.lib, self.tmp])
        self.assertEqual(rescan, [os.path.join(self.tmp, "Artist")])
        self.assertEqual(os.listdir(self.tmp), [])

    def test_refuses_outside_roots_and_non_audio(self):
        outside = os.path.join(self.d, "elsewhere", "x.m4a")
        lrc = os.path.join(self.lib, "A", "x.lrc")
        _touch(outside)
        _touch(lrc)
        removed, failed, _ = removal.remove([outside, lrc, os.path.join(self.lib, "../elsewhere/x.m4a")],
                                            [self.lib, self.tmp])
        self.assertEqual(removed, [])
        self.assertEqual(len(failed), 3)
        self.assertTrue(os.path.exists(outside) and os.path.exists(lrc))


@unittest.skipIf(yandex is None, "needs the yandex venv")
class YandexTest(unittest.TestCase):
    def test_parse_token(self):
        self.assertEqual(yandex.parse_token("  abc123 \n"), "abc123")
        self.assertEqual(yandex.parse_token(
            "https://music.yandex.ru/#access_token=y0_TOKEN&token_type=bearer&expires_in=31536000"), "y0_TOKEN")

    def test_downloader_line(self):
        m = yandex._DL_LINE.match("[3/12] [FLAC] Загружается /m/Artist/Album/3 - Song.m4a")
        self.assertEqual((m.group(1), m.group(2), m.group(3)), ("3", "12", "/m/Artist/Album/3 - Song.m4a"))
        self.assertEqual(yandex._DL_LINE.match("[AAC 192kbps] Загружается x.m4a").group(3), "x.m4a")

    @unittest.skipIf(not shutil.which("ffmpeg"), "needs ffmpeg to make a test file")
    def test_embed_lrc_m4a(self):
        d = tempfile.mkdtemp()
        try:
            song = os.path.join(d, "1 - Song.m4a")
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                            "-t", "0.5", "-c:a", "aac", song], check=True)
            self.assertFalse(yandex.embed_lrc(song))            # no .lrc: nothing to do
            with open(os.path.join(d, "1 - Song.lrc"), "w", encoding="utf-8") as fh:
                fh.write("[00:00.10] hello\n")
            self.assertTrue(yandex.embed_lrc(song))
            self.assertEqual(MP4(song).tags["\xa9lyr"], ["[00:00.10] hello\n"])
            self.assertFalse(yandex.embed_lrc(song))            # already the same: untouched
            self.assertEqual(yandex.embed_tree(d), (1, 0, []))
            with open(os.path.join(d, "1 - Song.lrc"), "w", encoding="utf-8") as fh:
                fh.write("[00:00.20] changed\n")
            self.assertEqual(yandex.embed_tree(d)[1], 1)
        finally:
            shutil.rmtree(d)

    @unittest.skipIf(not shutil.which("ffmpeg"), "needs ffmpeg to make a test file")
    def test_remove_unlikes_by_link_tag(self):
        d = tempfile.mkdtemp()
        try:
            song = os.path.join(d, "lib", "A", "B", "1 - s.m4a")
            os.makedirs(os.path.dirname(song))
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                            "-t", "0.3", "-c:a", "aac", song], check=True)
            f = MP4(song)
            f["\xa9cmt"] = "https://music.yandex.ru/album/5/track/777"
            f.save()

            class FakeClient:
                unliked = []
                def users_likes_tracks_remove(self, ids):
                    FakeClient.unliked += ids
            w = yandex.Worker.__new__(yandex.Worker)
            w.ym = yandex.YM.__new__(yandex.YM)
            w.ym.lib, w.ym.likes, w.ym._client = os.path.join(d, "lib"), ["777", "1"], FakeClient()
            w.ym._liked_paths = {}
            out = []
            old_emit, yandex.emit = yandex.emit, out.append
            try:
                self.assertEqual(w.ym.track_id_of(song), "777")
                w.remove({"paths": [song], "unlike": True})
            finally:
                yandex.emit = old_emit
            self.assertEqual(FakeClient.unliked, ["777"])
            self.assertEqual(w.ym.likes, ["1"])
            done = [m for m in out if m["type"] == "ym-removed"][0]
            self.assertEqual((done["paths"], done["unliked"]), ([song], 1))
            self.assertFalse(os.path.exists(os.path.join(d, "lib", "A")))
        finally:
            shutil.rmtree(d)

    def test_settings_file_is_private(self):
        d = tempfile.mkdtemp()
        old = yandex.CONF
        try:
            yandex.CONF = os.path.join(d, "sub", "yandex.json")
            yandex.save_conf({"token": "secret", "storage": "temp"})
            self.assertEqual(os.stat(yandex.CONF).st_mode & 0o777, 0o600)
            c = yandex.load_conf()
            self.assertEqual((c["storage"], c["quality"]), ("temp", 2))
            self.assertNotIn("token", yandex.public_conf(c))
        finally:
            yandex.CONF = old
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main()
