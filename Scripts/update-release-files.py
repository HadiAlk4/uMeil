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

import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/HadiAlk4/uMeil"
MINIMUM_MACOS = "14.0"


def read_release(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    for key in ("VERSION", "BUILD", "SHA256", "LENGTH"):
        if not values.get(key):
            raise SystemExit(f"{path} has no {key}")
    if not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", values["VERSION"]):
        raise SystemExit(f"{values['VERSION']} is not a version like 1.2.3")
    if not re.fullmatch(r"[0-9a-f]{64}", values["SHA256"]):
        raise SystemExit("SHA256 is not a SHA-256 checksum")
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
    text = path.read_text()
    updated = re.sub(r'^  version ".*"$', f'  version "{release["VERSION"]}"', text, count=1, flags=re.M)
    updated = re.sub(r"^  sha256 .*$", f'  sha256 "{release["SHA256"]}"', updated, count=1, flags=re.M)
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
