# Releasing uMeil

A release is a DMG on [GitHub Releases](https://github.com/HadiAlk4/uMeil/releases), linked from the website at <https://hadialk4.github.io/uMeil/>, offered to existing installs through Sparkle, and installable with Homebrew.

| Piece | Where it lives |
|---|---|
| Build, sign, notarize, DMG | `Scripts/make-release.sh` |
| Release workflow (on a `v*` tag) | `.github/workflows/release.yml` |
| Website and Sparkle feed | `site/` (`index.html`, `style.css`, `screenshot.png`, `appcast.xml`), published by `.github/workflows/pages.yml` |
| Homebrew cask | `Casks/umeil.rb` (this repository is its own tap) |
| Feed and cask update after a release | `Scripts/update-release-files.py` |
| In-app updates | `uMeil/SoftwareUpdater.swift` (Sparkle 2.10.1) |

## One-time setup

### 1. Turn on GitHub Pages

Settings › Pages › Build and deployment › Source: **GitHub Actions**. Then run the **Website** workflow once (Actions › Website › Run workflow), or push a change under `site/`.

The release workflow pushes the updated feed and cask straight to `main`. If `main` is protected, allow GitHub Actions to push to it.

### 2. Make the Sparkle signing key

Sparkle installs only updates signed with the project's EdDSA key. Make it once, on your Mac, with the tools Xcode downloaded with Sparkle:

```sh
SPARKLE_BIN=$(dirname "$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin/generate_keys' | head -1)")
"$SPARKLE_BIN/generate_keys"            # Stores the private key in your login keychain and prints the public key.
"$SPARKLE_BIN/generate_keys" -x sparkle-private-key.txt   # Exports the private key for CI.
```

- Add the **public** key as the repository *variable* `SPARKLE_PUBLIC_ED_KEY` (Settings › Secrets and variables › Actions › Variables). It is built into the app; without it the app never checks for updates and has no Check for Updates menu item.
- Add the contents of `sparkle-private-key.txt` as the repository *secret* `SPARKLE_PRIVATE_KEY`, then delete the file. Keep the keychain copy: losing the key means existing installs can never be updated again.

### 3. Developer ID signing and notarization (needs an Apple Developer Program membership)

Until this is done, releases are ad-hoc signed and not notarized. They work, but macOS blocks them the first time they are opened (the website and release notes explain **Open Anyway**), and Homebrew shows the same warning.

1. In Xcode › Settings › Accounts, add the Apple ID and create a **Developer ID Application** certificate. Export it from Keychain Access as a `.p12` with a password.
2. In App Store Connect › Users and Access › Integrations › App Store Connect API, create a key with the **Developer** role. Download the `.p8` once, and note its key ID and the issuer ID.
3. Add these repository secrets:

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_CERTIFICATE_P12` | `base64 -i certificate.p12` |
   | `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The `.p12`'s password |
   | `DEVELOPER_ID_APPLICATION` | `Developer ID Application: Your Name (TEAMID)` |
   | `DEVELOPMENT_TEAM` | `TEAMID` |
   | `NOTARY_KEY_P8` | `base64 -i AuthKey_XXXXXXXXXX.p8` |
   | `NOTARY_KEY_ID` | The key ID |
   | `NOTARY_ISSUER` | The issuer ID |

To sign and notarize locally instead, install the certificate in your keychain, store notarization credentials with `xcrun notarytool store-credentials umeil-notary`, and run:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
DEVELOPMENT_TEAM=TEAMID NOTARY_PROFILE=umeil-notary \
Scripts/make-release.sh 0.2.0
```

## Making a release

1. Make sure `main` is green in CI. Its **Release build** job builds the DMG the same way a release does; download the artifact and try it if anything packaging-related changed.
2. Set `MARKETING_VERSION` in the Xcode project to the new version, and merge that to `main`.
3. Tag and push:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

   A tag with a suffix (`v0.2.0-beta.1`) is published as a pre-release. A fourth number (`v0.2.0.1`) is allowed for a small fix to a release.
4. The **Release** workflow builds the DMG with the build number set to the number of commits (Sparkle compares it), creates the GitHub release with `uMeil-0.2.0.dmg` and `uMeil.dmg`, then commits the new feed entry and cask checksum to `main` and republishes the website.

A release that is not signed for Sparkle (no `SPARKLE_PRIVATE_KEY`) is published and added to the cask, but not to the update feed, since Sparkle would refuse it.

## Release checklist

Before announcing a release:

- [ ] The Release workflow's log shows `spctl` accepting the DMG and `stapler validate` passing (signed releases only).
- [ ] Install from the DMG on a clean Apple Silicon Mac or a fresh macOS VM (for example with Tart: `tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest umeil-test`). The app opens without a Gatekeeper warning (signed releases), downloads the toolchain, makes a Blinky project, builds it, and, with a LaunchPad, flashes and debugs it.
- [ ] Update from the previous release: open the previous version, choose uMeil › Check for Updates…, install, and check that uMeil › About shows the new version.
- [ ] On <https://hadialk4.github.io/uMeil/>, the Download button fetches the new DMG, and <https://hadialk4.github.io/uMeil/appcast.xml> lists the new version first.
- [ ] `brew tap hadialk4/umeil https://github.com/HadiAlk4/uMeil && brew install --cask umeil` installs the new version (`brew audit --cask --online umeil` passes).

## The website's screenshot

`site/screenshot.png` is made on a real board, from the app's own window, by a test that only runs when asked:

```sh
TEST_RUNNER_UMEIL_HIL=1 TEST_RUNNER_UMEIL_SCREENSHOT="$PWD/site/screenshot.png" \
  xcodebuild test -project uMeil.xcodeproj -scheme uMeil \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:uMeilTests/WebsiteScreenshotTests
```
