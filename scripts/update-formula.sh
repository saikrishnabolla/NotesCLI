#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORMULA="$ROOT/packaging/homebrew/notescli.rb"
VERSION=""
ARCHIVE=""
URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --archive) ARCHIVE="$2"; shift 2 ;;
        --url) URL="$2"; shift 2 ;;
        --formula) FORMULA="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$VERSION" && -f "$ARCHIVE" ]] || {
    echo "Usage: scripts/update-formula.sh --version VERSION --archive TARBALL [--url URL] [--formula PATH]" >&2
    exit 2
}

SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ -z "$URL" ]]; then
    URL="https://github.com/saikrishnabolla/NotesCLI/releases/download/v$VERSION/notescli-$VERSION-macos-universal.tar.gz"
fi

ruby - "$FORMULA" "$VERSION" "$URL" "$SHA256" <<'RUBY'
path, version, url, sha = ARGV
text = File.read(path)
raise "missing url" unless text.sub!(/^  url ".*"$/, "  url #{url.dump}")
raise "missing version" unless text.sub!(/^  version ".*"$/, "  version #{version.dump}")
raise "missing sha256" unless text.sub!(/^  sha256 ".*"$/, "  sha256 #{sha.dump}")
File.write(path, text)
RUBY

echo "Updated $FORMULA for $VERSION ($SHA256)"
