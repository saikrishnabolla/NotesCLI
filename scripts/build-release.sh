#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${NOTESCLI_VERSION:-1.1.13}"
IDENTITY="${NOTESCLI_SIGNING_IDENTITY:-Developer ID Application: Sai Krishna Bolla (GXKRUPGJVF)}"
INFO_PLIST="$ROOT/packaging/macos/Info.plist"
HOST_INFO_PLIST="$ROOT/packaging/macos/CapabilityHost-Info.plist"
ENTITLEMENTS="$ROOT/packaging/macos/notescli.entitlements"
ICON_SOURCE="$ROOT/packaging/macos/AppIcon.icon"
OUTPUT_DIR="${NOTESCLI_RELEASE_DIR:-$ROOT/dist}"
NOTARY_PROFILE="${NOTESCLI_NOTARY_PROFILE:-}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "build-release.sh requires macOS." >&2; exit 1; }
[[ -f "$INFO_PLIST" && -f "$HOST_INFO_PLIST" && -f "$ENTITLEMENTS" && -f "$ICON_SOURCE/icon.json" ]] || { echo "Release metadata is missing." >&2; exit 1; }
if [[ "$IDENTITY" != "-" && -z "$NOTARY_PROFILE" ]]; then
    echo "NOTESCLI_NOTARY_PROFILE is required for Developer ID releases." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR" "$ROOT/.build"
STAGING="$(mktemp -d "$ROOT/.build/notescli-release.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
RELEASE_INFO_PLIST="$STAGING/Info.plist"
cp "$INFO_PLIST" "$RELEASE_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$RELEASE_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$RELEASE_INFO_PLIST"
HOST_APP="$STAGING/Notes CLI.app"
mkdir -p "$HOST_APP/Contents/MacOS" "$HOST_APP/Contents/Helpers" "$HOST_APP/Contents/Resources"
cp "$HOST_INFO_PLIST" "$HOST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$HOST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$HOST_APP/Contents/Info.plist"
ICON_PLIST="$STAGING/AppIcon-Info.plist"
xcrun actool --compile "$HOST_APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target "$(plutil -extract LSMinimumSystemVersion raw "$HOST_INFO_PLIST")" \
    --app-icon AppIcon --output-partial-info-plist "$ICON_PLIST" "$ICON_SOURCE"
plutil -insert CFBundleIconName -string "$(plutil -extract CFBundleIconName raw "$ICON_PLIST")" "$HOST_APP/Contents/Info.plist"
[[ -s "$HOST_APP/Contents/Resources/Assets.car" && -s "$HOST_APP/Contents/Resources/AppIcon.icns" ]] || {
    echo "Could not compile the layered icon and its macOS fallback." >&2; exit 1;
}

echo "Building notescli $VERSION for arm64 and x86_64"
NOTESCLI_INFO_PLIST="$RELEASE_INFO_PLIST" swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64

BUILT="$ROOT/.build/apple/Products/Release/notescli"
BUILT_HOST="$ROOT/.build/apple/Products/Release/Notes CLI"
if [[ ! -x "$BUILT" ]]; then
    BUILT="$ROOT/.build/release/notescli"
    BUILT_HOST="$ROOT/.build/release/Notes CLI"
fi
[[ -x "$BUILT" ]] || { echo "Could not find the release executable." >&2; exit 1; }
[[ -x "$BUILT_HOST" ]] || { echo "Could not find the Notes CLI app executable." >&2; exit 1; }

cp "$BUILT" "$STAGING/notescli"
cp "$BUILT_HOST" "$HOST_APP/Contents/MacOS/Notes CLI"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Signing ad hoc because NOTESCLI_SIGNING_IDENTITY=-"
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$STAGING/notescli"
else
    echo "Signing with $IDENTITY"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGING/notescli"
fi
cp "$STAGING/notescli" "$HOST_APP/Contents/Helpers/notescli"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$HOST_APP/Contents/MacOS/Notes CLI"
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$HOST_APP"
else
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$HOST_APP/Contents/MacOS/Notes CLI"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$HOST_APP"
fi

ARCHITECTURES="$(lipo -archs "$STAGING/notescli")"
[[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]] || {
    echo "Release binary is not universal: $ARCHITECTURES" >&2
    exit 1
}
echo "Architectures: $ARCHITECTURES"
[[ "$("$STAGING/notescli" --version)" == "$VERSION" ]] || {
    echo "The release executable version does not match $VERSION." >&2
    exit 1
}
[[ "$("$HOST_APP/Contents/Helpers/notescli" --version)" == "$VERSION" ]] || {
    echo "The Notes CLI app contains the wrong CLI version; expected $VERSION." >&2
    exit 1
}
for BINARY in "$HOST_APP/Contents/MacOS/Notes CLI" "$HOST_APP/Contents/Helpers/notescli"; do
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
for BINARY in "$STAGING/notescli" "$HOST_APP/Contents/MacOS/Notes CLI"; do
    CAMERA_ENTITLEMENT="$(codesign -d --entitlements - --xml "$BINARY" 2>&1 | sed -n '/^<?xml/,$p' | plutil -extract 'com\.apple\.security\.device\.camera' raw - 2>/dev/null || true)"
    [[ "$CAMERA_ENTITLEMENT" == "true" ]] || {
        echo "The signed binary is missing the camera entitlement: $BINARY" >&2
        exit 1
    }
done

lipo "$STAGING/notescli" -thin x86_64 -output "$STAGING/notescli-x86_64"
INFO_SECTION="$(otool -l "$STAGING/notescli-x86_64" | awk '$1 == "sectname" && $2 == "__info_plist" { capture = 1 } capture { print } capture && $1 == "reserved2" { exit }')"
INFO_OFFSET="$(printf '%s\n' "$INFO_SECTION" | awk '$1 == "offset" { print $2; exit }')"
INFO_SIZE="$(printf '%s\n' "$INFO_SECTION" | awk '$1 == "size" { print $2; exit }')"
[[ -n "$INFO_OFFSET" && -n "$INFO_SIZE" ]] || {
    echo "The release binary has no embedded __info_plist section." >&2
    exit 1
}
dd if="$STAGING/notescli-x86_64" of="$STAGING/embedded-Info.plist" bs=1 skip="$INFO_OFFSET" count="$((INFO_SIZE))" status=none
[[ "$(plutil -extract NSAppleEventsUsageDescription raw "$STAGING/embedded-Info.plist")" == "Notes CLI uses Apple Events to create and update notes through the Notes app." ]] || {
    echo "The embedded Info.plist is missing NSAppleEventsUsageDescription." >&2
    exit 1
}
echo "Embedded Info.plist: NSAppleEventsUsageDescription present"
[[ "$(plutil -extract NSSpeechRecognitionUsageDescription raw "$STAGING/embedded-Info.plist")" == "Notes CLI uses on-device speech recognition to transcribe audio recordings you add to Apple Notes." ]] || {
    echo "The embedded Info.plist is missing NSSpeechRecognitionUsageDescription." >&2
    exit 1
}
echo "Embedded Info.plist: NSSpeechRecognitionUsageDescription present"
[[ "$(plutil -extract NSCameraUsageDescription raw "$STAGING/embedded-Info.plist")" == "Notes CLI captures photos you ask it to add to Apple Notes." ]] || {
    echo "The embedded Info.plist is missing NSCameraUsageDescription." >&2
    exit 1
}
[[ "$(plutil -extract NSCameraUseContinuityCameraDeviceType raw "$STAGING/embedded-Info.plist")" == "true" ]] || {
    echo "The embedded Info.plist does not opt into Continuity Camera devices." >&2
    exit 1
}
[[ "$(plutil -extract NSCameraUsageDescription raw "$HOST_APP/Contents/Info.plist")" == "Notes CLI captures photos you ask it to add to Apple Notes." ]] || {
    echo "Notes CLI.app is missing NSCameraUsageDescription." >&2
    exit 1
}
echo "Camera usage descriptions present"
[[ "$(plutil -extract CFBundleShortVersionString raw "$STAGING/embedded-Info.plist")" == "$VERSION" ]] || {
    echo "The embedded CLI short version does not match $VERSION." >&2; exit 1;
}
[[ "$(plutil -extract CFBundleVersion raw "$STAGING/embedded-Info.plist")" == "$VERSION" ]] || {
    echo "The embedded CLI build version does not match $VERSION." >&2; exit 1;
}
[[ "$(plutil -extract CFBundleShortVersionString raw "$HOST_APP/Contents/Info.plist")" == "$VERSION" ]] || {
    echo "The Notes CLI app short version does not match $VERSION." >&2; exit 1;
}
[[ "$(plutil -extract CFBundleVersion raw "$HOST_APP/Contents/Info.plist")" == "$VERSION" ]] || {
    echo "The Notes CLI app build version does not match $VERSION." >&2; exit 1;
}
[[ "$(plutil -extract CFBundleDisplayName raw "$HOST_APP/Contents/Info.plist")" == "Notes CLI" ]]
[[ "$(plutil -extract CFBundleName raw "$HOST_APP/Contents/Info.plist")" == "Notes CLI" ]]
[[ "$(plutil -extract CFBundleExecutable raw "$HOST_APP/Contents/Info.plist")" == "Notes CLI" ]]
[[ "$(plutil -extract CFBundleIconFile raw "$HOST_APP/Contents/Info.plist")" == "AppIcon" ]]
[[ "$(plutil -extract CFBundleIconName raw "$HOST_APP/Contents/Info.plist")" == "AppIcon" ]]
iconutil -c iconset "$HOST_APP/Contents/Resources/AppIcon.icns" -o "$STAGING/verified-AppIcon.iconset"
[[ -s "$STAGING/verified-AppIcon.iconset/icon_16x16.png" ]] || {
    echo "AppIcon.icns does not contain a small fallback icon." >&2; exit 1;
}

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarizing and stapling Notes CLI.app"
    ditto -c -k --keepParent "$HOST_APP" "$STAGING/Notes-CLI.zip"
    xcrun notarytool submit "$STAGING/Notes-CLI.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$HOST_APP"
    xcrun stapler validate "$HOST_APP"
    rm -f -- "$STAGING/Notes-CLI.zip"
fi

echo "Validating distributed artifacts with Gatekeeper"
codesign --verify --strict --verbose=4 "$STAGING/notescli"
if [[ "$IDENTITY" != "-" ]]; then spctl -a -t execute -vv "$HOST_APP"; fi

ZIP="$OUTPUT_DIR/notescli-$VERSION-macos-universal.zip"
TARBALL="$OUTPUT_DIR/notescli-$VERSION-macos-universal.tar.gz"
CHECKSUMS="$OUTPUT_DIR/notescli-$VERSION-macos-universal.sha256"
rm -f -- "$ZIP" "$TARBALL" "$CHECKSUMS"
(cd "$STAGING" && zip -q -X -r "$ZIP" notescli "Notes CLI.app")
COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$STAGING" notescli "Notes CLI.app"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$TARBALL")") > "$CHECKSUMS"

ZIP_VERIFY="$STAGING/verify-zip"
TAR_VERIFY="$STAGING/verify-tar"
mkdir -p "$ZIP_VERIFY" "$TAR_VERIFY"
ditto -x -k "$ZIP" "$ZIP_VERIFY"
tar -xzf "$TARBALL" -C "$TAR_VERIFY"
for EXTRACTED in "$ZIP_VERIFY" "$TAR_VERIFY"; do
    [[ "$("$EXTRACTED/notescli" --version)" == "$VERSION" ]]
    [[ "$("$EXTRACTED/Notes CLI.app/Contents/Helpers/notescli" --version)" == "$VERSION" ]] || {
        echo "An extracted Notes CLI app contains the wrong CLI version." >&2; exit 1;
    }
    codesign --verify --strict --verbose=4 "$EXTRACTED/notescli"
    codesign --verify --deep --strict --verbose=4 "$EXTRACTED/Notes CLI.app"
    [[ "$(plutil -extract CFBundleIconFile raw "$EXTRACTED/Notes CLI.app/Contents/Info.plist")" == "AppIcon" ]]
    [[ "$(plutil -extract CFBundleIconName raw "$EXTRACTED/Notes CLI.app/Contents/Info.plist")" == "AppIcon" ]]
    [[ -s "$EXTRACTED/Notes CLI.app/Contents/Resources/AppIcon.icns" ]]
    [[ -s "$EXTRACTED/Notes CLI.app/Contents/Resources/Assets.car" ]]
    if [[ -n "$NOTARY_PROFILE" ]]; then xcrun stapler validate "$EXTRACTED/Notes CLI.app"; fi
    if [[ "$IDENTITY" != "-" ]]; then spctl -a -t execute -vv "$EXTRACTED/Notes CLI.app"; fi
done

if [[ "$IDENTITY" == "-" ]]; then
    echo "Skipping the Homebrew checksum update for an ad hoc build"
elif [[ "${NOTESCLI_SKIP_FORMULA_UPDATE:-0}" == "1" ]]; then
    echo "Skipping the Homebrew checksum update for a local build"
else
    "$ROOT/scripts/update-formula.sh" --version "$VERSION" --archive "$TARBALL"
fi

echo "Created:"
printf '  %s\n  %s\n  %s\n' "$ZIP" "$TARBALL" "$CHECKSUMS"
