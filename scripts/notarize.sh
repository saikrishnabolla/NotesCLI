#!/bin/bash
set -euo pipefail

PROFILE="notescli-notary"
if [[ $# -ne 1 ]]; then
    echo "Usage: scripts/notarize.sh <signed.zip|pkg|dmg|app>" >&2
    echo "First store credentials with: xcrun notarytool store-credentials notescli-notary ..." >&2
    exit 2
fi

ARTIFACT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -e "$ARTIFACT" ]] || { echo "Artifact not found: $ARTIFACT" >&2; exit 1; }
SUBMISSION="$ARTIFACT"
TEMP_DIR=""
if [[ "$ARTIFACT" == *.app ]]; then
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notescli-notary.XXXXXX")"
    trap 'rm -rf -- "$TEMP_DIR"' EXIT
    SUBMISSION="$TEMP_DIR/$(basename "$ARTIFACT").zip"
    ditto -c -k --keepParent "$ARTIFACT" "$SUBMISSION"
fi

xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait

case "$ARTIFACT" in
    *.app|*.pkg|*.dmg)
        xcrun stapler staple "$ARTIFACT"
        xcrun stapler validate "$ARTIFACT"
        ;;
    *)
        echo "Notarization accepted. Apple does not staple tickets to zip archives."
        ;;
esac
