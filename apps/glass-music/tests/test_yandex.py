"""Yandex Music helpers. The glassmusic.yandex tests need the venv (yandex-music-downloader +
mutagen) and are skipped without it:
  ~/.local/share/glass-music/yandex-venv/bin/python -m unittest discover -s tests -t .
No network, no MPD, no real ~/Music."""
import os
import shutil
import subprocess
import tempfile
import unittest

from glassmusic import lyrics

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
