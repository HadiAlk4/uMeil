"""Tests for update-release-files.py. Run with:

    python3 -m unittest discover -s Scripts -p 'test_*.py'
"""

import importlib.util
import re
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
        self.shipped_appcast = root / "site/appcast.xml"
        self.shipped_cask = root / "Casks/umeil.rb"
        self._undo_past_releases()

    def _undo_past_releases(self):
        """Puts the copies back as they were before the first release.

        Each release adds to the shipped feed and writes its checksum into the
        cask, so the tests start from a clean slate rather than whatever was
        released last.
        """
        appcast = re.sub(r"\s*<item>.*?</item>", "", self.appcast.read_text(), flags=re.S)
        self.appcast.write_text(appcast)
        cask = re.sub(r'^  version ".*"$', '  version "0.1.0"', self.cask.read_text(), count=1, flags=re.M)
        cask = re.sub(r"^  sha256 .*$", "  sha256 :no_check", cask, count=1, flags=re.M)
        self.cask.write_text(cask)

    def test_the_shipped_appcast_is_valid_and_offers_only_signed_releases(self):
        channel = ET.parse(self.shipped_appcast).getroot().find("channel")
        self.assertIsNotNone(channel)
        for item in channel.findall("item"):
            self.assertTrue(item.find("enclosure").get(f"{SPARKLE}edSignature"))

    def test_the_shipped_cask_has_a_real_checksum_or_none_yet(self):
        sha256 = re.search(r"^  sha256 (.*)$", self.shipped_cask.read_text(), flags=re.M).group(1)
        self.assertRegex(sha256, r'^(:no_check|"[0-9a-f]{64}")$')

    def test_a_cleared_appcast_has_no_releases(self):
        self.assertEqual(ET.parse(self.appcast).getroot().find("channel").findall("item"), [])

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
        # Before the first release the cask uses :no_check (never a fake digest),
        # and update_cask must always replace it with a validated 64-hex SHA-256.
        self.assertIn("  sha256 :no_check", self.cask.read_text())
        self.assertTrue(release_files.update_cask(self.cask, RELEASE))
        text = self.cask.read_text()
        self.assertIn('  version "0.2.0"\n', text)
        self.assertIn(f'  sha256 "{"ab" * 32}"\n', text)
        self.assertNotIn(":no_check", text)
        self.assertFalse(release_files.update_cask(self.cask, RELEASE))

    def test_a_four_part_version_is_accepted(self):
        release = dict(RELEASE, VERSION="0.2.0.1")
        self.assertTrue(release_files.update_cask(self.cask, release))
        self.assertIn('  version "0.2.0.1"\n', self.cask.read_text())
        self.assertTrue(release_files.update_appcast(self.appcast, release, PUBLISHED))
        self.assertIn("<sparkle:shortVersionString>0.2.0.1</sparkle:shortVersionString>", self.appcast.read_text())

    def test_update_cask_rejects_no_check_and_invalid_inputs(self):
        before = self.cask.read_text()
        for bad_release in (
            dict(RELEASE, SHA256=":no_check"),
            dict(RELEASE, SHA256="no_check"),
            dict(RELEASE, SHA256="AB" * 32),
            dict(RELEASE, SHA256="ab" * 31),
            dict(RELEASE, SHA256="zz" * 32),
            dict(RELEASE, SHA256=""),
            dict(RELEASE, VERSION='0.2.0"\n  system "id'),
            dict(RELEASE, VERSION="v0.2.0"),
            dict(RELEASE, VERSION="0.2.0.1.2"),
            dict(RELEASE, VERSION="0.2.0."),
        ):
            with self.subTest(bad_release=bad_release):
                with self.assertRaises(SystemExit):
                    release_files.update_cask(self.cask, bad_release)
                self.assertEqual(self.cask.read_text(), before)

    def test_the_unsigned_note_hides_only_once_notarized(self):
        self.assertFalse(release_files.update_site(self.site, dict(RELEASE, NOTARIZED="no")))
        self.assertTrue(release_files.update_site(self.site, RELEASE))
        self.assertIn('id="unsigned-note" hidden>', self.site.read_text())

    def test_release_env_is_checked(self):
        env = self.folder / "release.env"
        env.write_text("VERSION=1.0\nBUILD=1\nSHA256=" + "0" * 64 + "\nLENGTH=1\n")
        with self.assertRaises(SystemExit):
            release_files.read_release(env)
        env.write_text(
            "VERSION=1.0.0\nBUILD=1\nSHA256=" + "0" * 64 + "\nLENGTH=1\nSIGNED=yes\nNOTARIZED=no\nED_SIGNATURE=\n"
        )
        parsed = release_files.read_release(env)
        self.assertEqual(parsed["ED_SIGNATURE"], "")
        self.assertEqual(parsed["SIGNED"], "yes")
        self.assertEqual(parsed["NOTARIZED"], "no")

    def _write_env(self, **overrides):
        data = dict(RELEASE, **overrides)
        env = self.folder / "release.env"
        env.write_text("".join(f"{k}={v}\n" for k, v in data.items()))
        return env

    def test_read_release_rejects_malformed_fields(self):
        invalid_cases = [
            {"VERSION": "1.0"},
            {"VERSION": "v1.0.0"},
            {"VERSION": "1.0.0;id"},
            {"BUILD": "abc"},
            {"BUILD": "-1"},
            {"BUILD": "1.2"},
            {"BUILD": "\u0661"},
            {"BUILD": ""},
            {"LENGTH": "abc"},
            {"LENGTH": "-5"},
            {"LENGTH": "10MB"},
            {"LENGTH": "\u0662"},
            {"LENGTH": ""},
            {"SHA256": ":no_check"},
            {"SHA256": "AB" * 32},
            {"SHA256": "0" * 63},
            {"SHA256": "g" * 64},
            {"SIGNED": "true"},
            {"SIGNED": ""},
            {"NOTARIZED": "1"},
            {"NOTARIZED": ""},
            {"ED_SIGNATURE": "c2ln bmF0dXJl"},
            {"ED_SIGNATURE": " c2lnbmF0dXJl"},
            {"ED_SIGNATURE": "c2lnbmF0dXJl "},
            {"ED_SIGNATURE": "c2ln\tbmF0dXJl"},
            {"ED_SIGNATURE": "c2ln\x00bmF0dXJl"},
            {"ED_SIGNATURE": "c2ln\x0bbmF0dXJl"},
            {"ED_SIGNATURE": "not-valid-base64!"},
            {"ED_SIGNATURE": "abc"},
            {"ED_SIGNATURE": "===="},
        ]
        for overrides in invalid_cases:
            with self.subTest(overrides=overrides):
                env = self._write_env(**overrides)
                with self.assertRaises(SystemExit):
                    release_files.read_release(env)

    def test_read_release_accepts_valid_padded_ed_signature(self):
        env = self._write_env(ED_SIGNATURE="YWJjZA==")
        self.assertEqual(release_files.read_release(env)["ED_SIGNATURE"], "YWJjZA==")


if __name__ == "__main__":
    unittest.main()
