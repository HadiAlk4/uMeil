#!/usr/bin/env python3
"""Updates the files that point at the latest release, after
Scripts/make-release.sh has built it:

  site/appcast.xml   Adds the release to Sparkle's update feed, newest
                     first. Only when the DMG has a Sparkle signature
                     (ED_SIGNATURE): Sparkle refuses an update without one.
  Casks/umeil.rb     Sets the Homebrew cask's version and checksum.
  site/index.html    Hides the "not notarized" note once a release is.

Usage:
    Scripts/update-release-files.py [dist/release.env]

Running it twice for the same release changes nothing the second time.
"""

import base64
import binascii
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/HadiAlk4/uMeil"
MINIMUM_MACOS = "14.0"

VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.]+)?")
UINT_RE = re.compile(r"[0-9]+")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
YES_NO_RE = re.compile(r"(yes|no)")
BASE64_RE = re.compile(r"[A-Za-z0-9+/]+={0,2}")


def _validate_version(version):
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"{version} is not a version like 1.2.3 or 1.2.3.4")


def _validate_sha256(sha256):
    if sha256 == ":no_check" or not SHA256_RE.fullmatch(sha256):
        raise SystemExit("SHA256 is not a 64-character lowercase SHA-256 checksum")


def _validate_ed_signature(signature):
    if not signature:
        return
    if any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in signature):
        raise SystemExit("ED_SIGNATURE must not contain whitespace or control characters")
    if not BASE64_RE.fullmatch(signature):
        raise SystemExit("ED_SIGNATURE is not valid base64")
    try:
        base64.b64decode(signature.encode("ascii"), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SystemExit("ED_SIGNATURE is not valid base64") from exc


def read_release(path):
    values = {}
    for raw_line in Path(path).read_text(encoding="utf-8").split("\n"):
        line = raw_line[:-1] if raw_line.endswith("\r") else raw_line
        if "=" in line:
            key, value = line.split("=", 1)
            key = key.strip()
            values[key] = value if key == "ED_SIGNATURE" else value.strip()
    for key in ("VERSION", "BUILD", "SHA256", "LENGTH"):
        if not values.get(key):
            raise SystemExit(f"{path} has no {key}")
    _validate_version(values["VERSION"])
    if not UINT_RE.fullmatch(values["BUILD"]):
        raise SystemExit("BUILD is not an integer")
    _validate_sha256(values["SHA256"])
    if not UINT_RE.fullmatch(values["LENGTH"]):
        raise SystemExit("LENGTH is not an integer")
    for flag in ("SIGNED", "NOTARIZED"):
        if flag in values and not YES_NO_RE.fullmatch(values[flag]):
            raise SystemExit(f"{flag} must be 'yes' or 'no'")
    if "ED_SIGNATURE" in values:
        _validate_ed_signature(values["ED_SIGNATURE"])
    return values


def appcast_item(release, published):
    version = release["VERSION"]
    url = f"{REPOSITORY}/releases/download/v{version}/uMeil-{version}.dmg"
    return "\n".join([
        "    <item>",
        f"      <title>Version {escape(version)}</title>",
        f"      <pubDate>{format_datetime(published)}</pubDate>",
        f"      <link>{REPOSITORY}/releases/tag/v{escape(version)}</link>",
        f"      <sparkle:version>{escape(release['BUILD'])}</sparkle:version>",
        f"      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>",
        f"      <sparkle:minimumSystemVersion>{MINIMUM_MACOS}</sparkle:minimumSystemVersion>",
        f"      <sparkle:releaseNotesLink>{REPOSITORY}/releases/tag/v{escape(version)}</sparkle:releaseNotesLink>",
        f"      <enclosure url={quoteattr(url)} length={quoteattr(release['LENGTH'])}"
        f" type=\"application/octet-stream\" sparkle:edSignature={quoteattr(release['ED_SIGNATURE'])}/>",
        "    </item>",
    ])


def update_appcast(path, release, published):
    """Returns True if the feed changed."""
    if not release.get("ED_SIGNATURE"):
        print("No Sparkle signature: the update feed is left as it is.", file=sys.stderr)
        return False
    _validate_version(release["VERSION"])
    if not UINT_RE.fullmatch(release["BUILD"]):
        raise SystemExit("BUILD is not an integer")
    if not UINT_RE.fullmatch(release["LENGTH"]):
        raise SystemExit("LENGTH is not an integer")
    _validate_ed_signature(release["ED_SIGNATURE"])
    text = path.read_text()
    marker = f"<sparkle:shortVersionString>{escape(release['VERSION'])}</sparkle:shortVersionString>"
    if marker in text:
        return False
    # Newest first: right after the channel's own description.
    anchor = "    <language>en</language>\n"
    if anchor not in text:
        raise SystemExit(f"{path} does not look like uMeil's appcast")
    path.write_text(text.replace(anchor, anchor + appcast_item(release, published) + "\n", 1))
    return True


def update_cask(path, release):
    _validate_version(release.get("VERSION", ""))
    sha256 = release.get("SHA256", "")
    _validate_sha256(sha256)
    text = path.read_text()
    updated, version_count = re.subn(
        r'^  version ".*"$', f'  version "{release["VERSION"]}"', text, count=1, flags=re.M
    )
    if version_count != 1:
        raise SystemExit(f"{path} does not have a single version stanza")
    updated, sha_count = re.subn(
        r"^  sha256 .*$", f'  sha256 "{sha256}"', updated, count=1, flags=re.M
    )
    if sha_count != 1 or re.search(r"^\s*sha256\s+:no_check\b", updated, flags=re.M):
        raise SystemExit(f"{path} does not have a valid sha256 stanza")
    if updated != text:
        path.write_text(updated)
    return updated != text


def update_site(path, release):
    if release.get("NOTARIZED") != "yes":
        return False
    text = path.read_text()
    updated = text.replace('<p class="note" id="unsigned-note">', '<p class="note" id="unsigned-note" hidden>')
    if updated != text:
        path.write_text(updated)
    return updated != text


def main(argv):
    env = Path(argv[1]) if len(argv) > 1 else ROOT / "dist/release.env"
    release = read_release(env)
    published = datetime.now(timezone.utc).replace(microsecond=0)
    changed = [
        name for name, did_change in (
            ("site/appcast.xml", update_appcast(ROOT / "site/appcast.xml", release, published)),
            ("Casks/umeil.rb", update_cask(ROOT / "Casks/umeil.rb", release)),
            ("site/index.html", update_site(ROOT / "site/index.html", release)),
        ) if did_change
    ]
    print("Updated: " + (", ".join(changed) if changed else "nothing"))


if __name__ == "__main__":
    main(sys.argv)
