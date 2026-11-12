#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${NOTESCLI_VERSION:-1.1.0}"
IDENTITY="${NOTESCLI_SIGNING_IDENTITY:-Developer ID Application: Sai Krishna Bolla (GXKRUPGJVF)}"
INFO_PLIST="$ROOT/packaging/macos/Info.plist"
HOST_INFO_PLIST="$ROOT/packaging/macos/CapabilityHost-Info.plist"
ENTITLEMENTS="$ROOT/packaging/macos/notescli.entitlements"
OUTPUT_DIR="${NOTESCLI_RELEASE_DIR:-$ROOT/dist}"
NOTARY_PROFILE="${NOTESCLI_NOTARY_PROFILE:-}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "build-release.sh requires macOS." >&2; exit 1; }
[[ -f "$INFO_PLIST" && -f "$HOST_INFO_PLIST" && -f "$ENTITLEMENTS" ]] || { echo "Release metadata is missing." >&2; exit 1; }
if [[ "$IDENTITY" != "-" && -z "$NOTARY_PROFILE" ]]; then
    echo "NOTESCLI_NOTARY_PROFILE is required for Developer ID releases." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d "$ROOT/.build/notescli-release.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
RELEASE_INFO_PLIST="$STAGING/Info.plist"
cp "$INFO_PLIST" "$RELEASE_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$RELEASE_INFO_PLIST"
HOST_APP="$STAGING/NotesCLI Capability Host.app"
mkdir -p "$HOST_APP/Contents/MacOS" "$HOST_APP/Contents/Helpers"
cp "$HOST_INFO_PLIST" "$HOST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$HOST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$HOST_APP/Contents/Info.plist"

echo "Building notescli $VERSION for arm64 and x86_64"
NOTESCLI_INFO_PLIST="$RELEASE_INFO_PLIST" swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64

BUILT="$ROOT/.build/apple/Products/Release/notescli"
BUILT_HOST="$ROOT/.build/apple/Products/Release/NotesCLI Capability Host"
if [[ ! -x "$BUILT" ]]; then
    BUILT="$ROOT/.build/release/notescli"
    BUILT_HOST="$ROOT/.build/release/NotesCLI Capability Host"
fi
[[ -x "$BUILT" ]] || { echo "Could not find the release executable." >&2; exit 1; }
[[ -x "$BUILT_HOST" ]] || { echo "Could not find the capability-host executable." >&2; exit 1; }

cp "$BUILT" "$STAGING/notescli"
cp "$BUILT_HOST" "$HOST_APP/Contents/MacOS/NotesCLI Capability Host"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Signing ad hoc because NOTESCLI_SIGNING_IDENTITY=-"
    codesign --force --sign - "$STAGING/notescli"
else
    echo "Signing with $IDENTITY"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGING/notescli"
fi
cp "$STAGING/notescli" "$HOST_APP/Contents/Helpers/notescli"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$HOST_APP/Contents/MacOS/NotesCLI Capability Host"
    codesign --force --sign - "$HOST_APP"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$HOST_APP/Contents/MacOS/NotesCLI Capability Host"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$HOST_APP"
fi

ARCHITECTURES="$(lipo -archs "$STAGING/notescli")"
[[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]] || {
    echo "Release binary is not universal: $ARCHITECTURES" >&2
    exit 1
}
echo "Architectures: $ARCHITECTURES"
for BINARY in "$HOST_APP/Contents/MacOS/NotesCLI Capability Host" "$HOST_APP/Contents/Helpers/notescli"; do
    INNER_ARCHITECTURES="$(lipo -archs "$BINARY")"
    [[ " $INNER_ARCHITECTURES " == *" arm64 "* && " $INNER_ARCHITECTURES " == *" x86_64 "* ]] || {
        echo "Release binary is not universal: $BINARY ($INNER_ARCHITECTURES)" >&2
        exit 1
    }
done
codesign --verify --strict --verbose=4 "$STAGING/notescli"
codesign --verify --deep --strict --verbose=4 "$HOST_APP"
[[ "$(codesign -d --verbose=4 "$STAGING/notescli" 2>&1 | awk -F= '$1 == "Identifier" { print $2 }')" == "com.saikrishnabolla.notescli" ]]
[[ "$(codesign -d --verbose=4 "$HOST_APP/Contents/Helpers/notescli" 2>&1 | awk -F= '$1 == "Identifier" { print $2 }')" == "com.saikrishnabolla.notescli" ]]
[[ "$(codesign -d --verbose=4 "$HOST_APP" 2>&1 | awk -F= '$1 == "Identifier" { print $2 }')" == "com.saikrishnabolla.notescli.capability-host" ]]
codesign -d --verbose=4 --entitlements - "$STAGING/notescli" 2>&1

lipo "$STAGING/notescli" -thin x86_64 -output "$STAGING/notescli-x86_64"
INFO_SECTION="$(otool -l "$STAGING/notescli-x86_64" | awk '$1 == "sectname" && $2 == "__info_plist" { capture = 1 } capture { print } capture && $1 == "reserved2" { exit }')"
INFO_OFFSET="$(printf '%s\n' "$INFO_SECTION" | awk '$1 == "offset" { print $2; exit }')"
INFO_SIZE="$(printf '%s\n' "$INFO_SECTION" | awk '$1 == "size" { print $2; exit }')"
[[ -n "$INFO_OFFSET" && -n "$INFO_SIZE" ]] || {
    echo "The release binary has no embedded __info_plist section." >&2
    exit 1
}
dd if="$STAGING/notescli-x86_64" of="$STAGING/embedded-Info.plist" bs=1 skip="$INFO_OFFSET" count="$((INFO_SIZE))" status=none
[[ "$(plutil -extract NSAppleEventsUsageDescription raw "$STAGING/embedded-Info.plist")" == "NotesCLI uses Apple Events to create and update notes through the Notes app." ]] || {
    echo "The embedded Info.plist is missing NSAppleEventsUsageDescription." >&2
    exit 1
}
echo "Embedded Info.plist: NSAppleEventsUsageDescription present"
[[ "$(plutil -extract NSSpeechRecognitionUsageDescription raw "$STAGING/embedded-Info.plist")" == "NotesCLI uses on-device speech recognition to transcribe audio recordings you add to Apple Notes." ]] || {
    echo "The embedded Info.plist is missing NSSpeechRecognitionUsageDescription." >&2
    exit 1
}
echo "Embedded Info.plist: NSSpeechRecognitionUsageDescription present"

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarizing and stapling NotesCLI Capability Host.app"
    ditto -c -k --keepParent "$HOST_APP" "$STAGING/NotesCLI-Capability-Host.zip"
    xcrun notarytool submit "$STAGING/NotesCLI-Capability-Host.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$HOST_APP"
    xcrun stapler validate "$HOST_APP"
    rm -f -- "$STAGING/NotesCLI-Capability-Host.zip"
fi

echo "Validating distributed artifacts with Gatekeeper"
spctl -a -t execute -vv "$STAGING/notescli"
spctl -a -t execute -vv "$HOST_APP"

ZIP="$OUTPUT_DIR/notescli-$VERSION-macos-universal.zip"
TARBALL="$OUTPUT_DIR/notescli-$VERSION-macos-universal.tar.gz"
CHECKSUMS="$OUTPUT_DIR/notescli-$VERSION-macos-universal.sha256"
rm -f -- "$ZIP" "$TARBALL" "$CHECKSUMS"
(cd "$STAGING" && zip -q -X -r "$ZIP" notescli "NotesCLI Capability Host.app")
COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$STAGING" notescli "NotesCLI Capability Host.app"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$TARBALL")") > "$CHECKSUMS"

"$ROOT/scripts/update-formula.sh" --version "$VERSION" --archive "$TARBALL"

echo "Created:"
printf '  %s\n  %s\n  %s\n' "$ZIP" "$TARBALL" "$CHECKSUMS"
