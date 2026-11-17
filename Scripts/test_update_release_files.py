"""Tests for update-release-files.py. Run with:

    python3 -m unittest discover -s Scripts -p 'test_*.py'
"""

import importlib.util
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("release_files", HERE / "update-release-files.py")
release_files = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_files)

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
RELEASE = {
    "VERSION": "0.2.0",
    "BUILD": "130",
    "SHA256": "ab" * 32,
    "LENGTH": "2623273",
    "SIGNED": "yes",
    "NOTARIZED": "yes",
    "ED_SIGNATURE": "c2lnbmF0dXJl",
}
PUBLISHED = datetime(2026, 11, 20, 9, 30, tzinfo=timezone.utc)


class UpdateReleaseFilesTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        root = HERE.parent
        for name in ("site/appcast.xml", "site/index.html", "Casks/umeil.rb"):
            target = self.folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(root / name, target)
        self.appcast = self.folder / "site/appcast.xml"
        self.cask = self.folder / "Casks/umeil.rb"
        self.site = self.folder / "site/index.html"

    def test_the_shipped_appcast_is_valid_and_empty(self):
        channel = ET.parse(self.appcast).getroot().find("channel")
        self.assertEqual(channel.findall("item"), [])

    def test_a_signed_release_is_added_to_the_feed_newest_first_once(self):
        self.assertTrue(release_files.update_appcast(self.appcast, RELEASE, PUBLISHED))
        newer = dict(RELEASE, VERSION="0.3.0", BUILD="140")
        self.assertTrue(release_files.update_appcast(self.appcast, newer, PUBLISHED))
        self.assertFalse(release_files.update_appcast(self.appcast, newer, PUBLISHED))

        items = ET.parse(self.appcast).getroot().find("channel").findall("item")
        self.assertEqual([i.find(f"{SPARKLE}shortVersionString").text for i in items], ["0.3.0", "0.2.0"])
        enclosure = items[1].find("enclosure")
        self.assertEqual(
            enclosure.get("url"), "https://github.com/HadiAlk4/uMeil/releases/download/v0.2.0/uMeil-0.2.0.dmg"
        )
        self.assertEqual(enclosure.get("length"), "2623273")
        self.assertEqual(enclosure.get(f"{SPARKLE}edSignature"), "c2lnbmF0dXJl")
        self.assertEqual(items[1].find(f"{SPARKLE}version").text, "130")
        self.assertEqual(items[1].find(f"{SPARKLE}minimumSystemVersion").text, "14.0")
        self.assertEqual(items[1].find("pubDate").text, "Fri, 20 Nov 2026 09:30:00 +0000")

    def test_an_unsigned_release_is_not_offered_as_an_update(self):
        unsigned = dict(RELEASE, ED_SIGNATURE="")
        self.assertFalse(release_files.update_appcast(self.appcast, unsigned, PUBLISHED))
        self.assertEqual(ET.parse(self.appcast).getroot().find("channel").findall("item"), [])

    def test_the_cask_gets_the_version_and_checksum(self):
        self.assertTrue(release_files.update_cask(self.cask, RELEASE))
        text = self.cask.read_text()
        self.assertIn('  version "0.2.0"\n', text)
        self.assertIn(f'  sha256 "{"ab" * 32}"\n', text)
        self.assertFalse(release_files.update_cask(self.cask, RELEASE))

    def test_the_unsigned_note_hides_only_once_notarized(self):
        self.assertFalse(release_files.update_site(self.site, dict(RELEASE, NOTARIZED="no")))
        self.assertTrue(release_files.update_site(self.site, RELEASE))
        self.assertIn('id="unsigned-note" hidden>', self.site.read_text())

    def test_release_env_is_checked(self):
        env = self.folder / "release.env"
        env.write_text("VERSION=1.0\nBUILD=1\nSHA256=" + "0" * 64 + "\nLENGTH=1\n")
        with self.assertRaises(SystemExit):
            release_files.read_release(env)
        env.write_text("VERSION=1.0.0\nBUILD=1\nSHA256=" + "0" * 64 + "\nLENGTH=1\nED_SIGNATURE=\n")
        self.assertEqual(release_files.read_release(env)["ED_SIGNATURE"], "")


if __name__ == "__main__":
    unittest.main()
