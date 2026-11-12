#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${NOTESCLI_VERSION:-1.0.0}"
IDENTITY="${NOTESCLI_SIGNING_IDENTITY:-Developer ID Application: Sai Krishna Bolla (GXKRUPGJVF)}"
INFO_PLIST="$ROOT/packaging/macos/Info.plist"
ENTITLEMENTS="$ROOT/packaging/macos/notescli.entitlements"
OUTPUT_DIR="${NOTESCLI_RELEASE_DIR:-$ROOT/dist}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "build-release.sh requires macOS." >&2; exit 1; }
[[ -f "$INFO_PLIST" && -f "$ENTITLEMENTS" ]] || { echo "Release metadata is missing." >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d "$ROOT/.build/notescli-release.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
RELEASE_INFO_PLIST="$STAGING/Info.plist"
cp "$INFO_PLIST" "$RELEASE_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$RELEASE_INFO_PLIST"

echo "Building notescli $VERSION for arm64 and x86_64"
NOTESCLI_INFO_PLIST="$RELEASE_INFO_PLIST" swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64

BUILT="$ROOT/.build/apple/Products/Release/notescli"
if [[ ! -x "$BUILT" ]]; then
    BUILT="$ROOT/.build/release/notescli"
fi
[[ -x "$BUILT" ]] || { echo "Could not find the release executable." >&2; exit 1; }

cp "$BUILT" "$STAGING/notescli"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Signing ad hoc because NOTESCLI_SIGNING_IDENTITY=-"
    codesign --force --sign - "$STAGING/notescli"
else
    echo "Signing with $IDENTITY"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGING/notescli"
fi

ARCHITECTURES="$(lipo -archs "$STAGING/notescli")"
[[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]] || {
    echo "Release binary is not universal: $ARCHITECTURES" >&2
    exit 1
}
echo "Architectures: $ARCHITECTURES"
codesign --verify --strict --verbose=4 "$STAGING/notescli"
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

set +e
SPCTL_OUTPUT="$(spctl -a -t install -vv "$STAGING/notescli" 2>&1)"
SPCTL_STATUS=$?
set -e
printf 'Gatekeeper assessment (exit %s):\n%s\n' "$SPCTL_STATUS" "$SPCTL_OUTPUT"

ZIP="$OUTPUT_DIR/notescli-$VERSION-macos-universal.zip"
TARBALL="$OUTPUT_DIR/notescli-$VERSION-macos-universal.tar.gz"
CHECKSUMS="$OUTPUT_DIR/notescli-$VERSION-macos-universal.sha256"
rm -f -- "$ZIP" "$TARBALL" "$CHECKSUMS"
(cd "$STAGING" && zip -q -X "$ZIP" notescli)
COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$STAGING" notescli
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$TARBALL")") > "$CHECKSUMS"

"$ROOT/scripts/update-formula.sh" --version "$VERSION" --archive "$TARBALL"

echo "Created:"
printf '  %s\n  %s\n  %s\n' "$ZIP" "$TARBALL" "$CHECKSUMS"
