#!/bin/bash
# Builds uMeil for release and packs it into a DMG.
#
#   Scripts/make-release.sh [version]
#
# The version defaults to MARKETING_VERSION in the Xcode project. The build
# number (CFBundleVersion, which Sparkle compares) is the number of commits
# on the current branch, so every release has a higher one.
#
# Everything below is optional. Without it the app is ad-hoc signed, which
# runs on the Mac that built it but is blocked by Gatekeeper elsewhere
# until the user allows it in System Settings > Privacy & Security.
#
#   DEVELOPER_ID_APPLICATION  Signing identity, for example
#                             "Developer ID Application: Name (TEAMID)".
#   DEVELOPMENT_TEAM          The team ID in that identity.
#   NOTARY_PROFILE            A notarytool keychain profile
#                             (xcrun notarytool store-credentials), or:
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#                             An App Store Connect API key, as in CI.
#   SPARKLE_PUBLIC_ED_KEY     Turns on automatic updates in the build.
#   SPARKLE_PRIVATE_KEY       Signs the DMG for Sparkle (the key exported by
#                             generate_keys -x). Written to a private
#                             temporary file and deleted afterwards.
#
# Writes to dist/:
#   uMeil-<version>.dmg       The release.
#   uMeil.dmg                 The same file, for the website's
#                             "latest" download link.
#   release.env               VERSION, BUILD, SHA256, LENGTH, SIGNED,
#                             NOTARIZED and ED_SIGNATURE, for the appcast
#                             and the Homebrew cask.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
BUILD_DIR="$ROOT/build/release"
DIST="$ROOT/dist"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

run_xcodebuild() {
    local label=$1
    local log_file=$2
    shift 2
    if ! xcodebuild "$@" >"$log_file" 2>&1; then
        grep -E '^(\*\*|error:)|: error:' "$log_file" >&2 || true
        tail -n 40 "$log_file" >&2
        fail "$label failed (see $log_file)"
    fi
    grep -E '^(\*\*|error:)' "$log_file" || true
}

find_sign_update() {
    local search_roots=()
    local dir candidate
    [[ -d $ROOT/build ]] && search_roots+=("$ROOT/build")
    [[ -d $ROOT/DerivedData ]] && search_roots+=("$ROOT/DerivedData")
    for dir in "$HOME/Library/Developer/Xcode/DerivedData"/uMeil-*; do
        [[ -d $dir ]] && search_roots+=("$dir")
    done
    for dir in "${search_roots[@]+"${search_roots[@]}"}"; do
        while IFS= read -r candidate; do
            if [[ -x $candidate ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(find "$dir" -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null || true)
    done
    return 1
}

settings=$(xcodebuild -project uMeil.xcodeproj -scheme uMeil -configuration Release -showBuildSettings 2>/dev/null)
setting() { awk -v key="$1" '$1 == key && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }' <<<"$settings"; }

VERSION=${1:-$(setting MARKETING_VERSION)}
BUILD=$(git rev-list --count HEAD)
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "version '$VERSION' is not like 1.2.3"

SIGNED=no
NOTARIZED=no
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
    [[ -n ${DEVELOPMENT_TEAM:-} ]] || fail "DEVELOPMENT_TEAM must be set with DEVELOPER_ID_APPLICATION"
    [[ $DEVELOPMENT_TEAM =~ ^[A-Z0-9]{10}$ ]] || fail "DEVELOPMENT_TEAM '$DEVELOPMENT_TEAM' must be 10 uppercase alphanumeric characters"
    SIGNED=yes
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST"

log "Archiving uMeil $VERSION ($BUILD), signed with Developer ID: $SIGNED"
archive_settings=(
    ARCHS=arm64
    MARKETING_VERSION="$VERSION"
    CURRENT_PROJECT_VERSION="$BUILD"
    SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
)
if [[ $SIGNED == yes ]]; then
    archive_settings+=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
        ENABLE_HARDENED_RUNTIME=YES
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
else
    # Hardened runtime turns on library validation, which refuses to load
    # Sparkle.framework (signed by Sparkle's team) into an ad-hoc signed
    # app. It is only needed for notarization, so it stays off here.
    archive_settings+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO)
fi
run_xcodebuild "xcodebuild archive" "$BUILD_DIR/archive.log" \
    archive \
    -project uMeil.xcodeproj \
    -scheme uMeil \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -onlyUsePackageVersionsFromResolvedFile \
    -archivePath "$BUILD_DIR/uMeil.xcarchive" \
    "${archive_settings[@]}"
[[ -d $BUILD_DIR/uMeil.xcarchive/Products/Applications/uMeil.app ]] || fail "the archive has no uMeil.app"

APP="$BUILD_DIR/export/uMeil.app"
if [[ $SIGNED == yes ]]; then
    log "Exporting with Developer ID"
    # Export re-signs every nested piece of code, including Sparkle's
    # helpers, with the identity and a secure timestamp.
    cat >"$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
EOF
    run_xcodebuild "xcodebuild -exportArchive" "$BUILD_DIR/export.log" \
        -exportArchive \
        -archivePath "$BUILD_DIR/uMeil.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
        -exportPath "$BUILD_DIR/export"
else
    mkdir -p "$BUILD_DIR/export"
    ditto "$BUILD_DIR/uMeil.xcarchive/Products/Applications/uMeil.app" "$APP"
fi
[[ -d $APP ]] || fail "export produced no uMeil.app"

log "Checking the app"
plist="$APP/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") == "$VERSION" ]] || fail "wrong version in app"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist") == "$BUILD" ]] || fail "wrong build number in app"
[[ $(lipo -archs "$APP/Contents/MacOS/uMeil") == arm64 ]] || fail "the app is not Apple Silicon only"
[[ -d $APP/Contents/Frameworks/Sparkle.framework ]] || fail "Sparkle.framework is not embedded"
[[ -f $APP/Contents/Resources/TivaWare.bundle/TM4C1294NCPDT.svd ]] || fail "TivaWare.bundle is incomplete"
codesign --verify --deep --strict "$APP"
if [[ $SIGNED == yes ]]; then
    codesign --display --verbose=2 "$APP" 2>&1 | grep -q 'flags=0x10000(runtime)' || fail "hardened runtime is off"
fi

# A framework the system refuses to load only shows when the app starts.
log "Launching the app"
# An empty LastOpenedFolder keeps it from opening the user's last project,
# which could wait on a permission prompt.
"$APP/Contents/MacOS/uMeil" -ApplePersistenceIgnoreState YES -LastOpenedFolder "" >"$BUILD_DIR/launch.log" 2>&1 &
app_pid=$!
sleep 5
if ! kill -0 "$app_pid" 2>/dev/null; then
    cat "$BUILD_DIR/launch.log" >&2
    fail "the app quit within 5 seconds of starting"
fi
kill "$app_pid"
wait "$app_pid" 2>/dev/null || true

DMG="$DIST/uMeil-$VERSION.dmg"
log "Making $(basename "$DMG")"
staging="$BUILD_DIR/dmg"
mkdir -p "$staging"
ditto "$APP" "$staging/uMeil.app"
ln -s /Applications "$staging/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "uMeil $VERSION" -srcfolder "$staging" -fs APFS -format ULFO -ov "$DMG"
hdiutil verify -quiet "$DMG"

if [[ $SIGNED == yes ]]; then
    codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"

    notary=()
    if [[ -n ${NOTARY_PROFILE:-} ]]; then
        notary=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n ${NOTARY_KEY_PATH:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER:-} ]]; then
        notary=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    fi
    if ((${#notary[@]})); then
        log "Notarizing (this usually takes a few minutes)"
        xcrun notarytool submit "$DMG" "${notary[@]}" --wait --timeout 30m
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG"
        NOTARIZED=yes
    else
        echo "No notarization credentials: the DMG is signed but not notarized."
    fi
fi

ED_SIGNATURE=""
if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
    log "Signing the DMG for Sparkle"
    sign_update=$(find_sign_update || true)
    [[ -n $sign_update && -x $sign_update ]] || fail "Sparkle's sign_update was not found; build the project once to download it"
    key_file=$(mktemp)
    chmod 600 "$key_file"
    trap 'rm -f "$key_file"' EXIT
    printf '%s' "$SPARKLE_PRIVATE_KEY" >"$key_file"
    ED_SIGNATURE=$("$sign_update" --ed-key-file "$key_file" -p "$DMG")
    rm -f "$key_file"
fi

cp "$DMG" "$DIST/uMeil.dmg"
SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
LENGTH=$(stat -f %z "$DMG")
cat >"$DIST/release.env" <<EOF
VERSION=$VERSION
BUILD=$BUILD
SHA256=$SHA256
LENGTH=$LENGTH
SIGNED=$SIGNED
NOTARIZED=$NOTARIZED
ED_SIGNATURE=$ED_SIGNATURE
EOF

log "Done"
cat "$DIST/release.env"
echo "$DMG"
