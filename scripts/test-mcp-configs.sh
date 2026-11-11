#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${1:-$ROOT/.build/debug/notescli}"
[[ -x "$BINARY" ]] || { echo "Build notescli first: swift build" >&2; exit 1; }

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/notescli-home.XXXXXX")"
trap 'rm -rf -- "$TEST_HOME"' EXIT
mkdir -p "$TEST_HOME/.codex" "$TEST_HOME/.cursor" "$TEST_HOME/Library/Application Support/Claude" "$TEST_HOME/Library/Application Support/Code/User"

printf '[theme]\nname = "dark"\n' > "$TEST_HOME/.codex/config.toml"
printf '{"mcpServers":{"keep":{"command":"keep"}}}\n' > "$TEST_HOME/.cursor/mcp.json"
printf '{"mcpServers":{"keep":{"command":"keep"}}}\n' > "$TEST_HOME/Library/Application Support/Claude/claude_desktop_config.json"
printf '{"servers":{"keep":{"command":"keep"}}}\n' > "$TEST_HOME/Library/Application Support/Code/User/mcp.json"

HOME="$TEST_HOME" "$BINARY" mcp install --client all --read-only
FIRST_BACKUPS="$(find "$TEST_HOME" -type f -name '*.backup-*' | wc -l | tr -d ' ')"
HOME="$TEST_HOME" "$BINARY" mcp install --client all --read-only
SECOND_BACKUPS="$(find "$TEST_HOME" -type f -name '*.backup-*' | wc -l | tr -d ' ')"
[[ "$FIRST_BACKUPS" == "$SECOND_BACKUPS" ]] || { echo "Idempotent install created extra backups." >&2; exit 1; }

grep -q '^\[mcp_servers.notescli\]$' "$TEST_HOME/.codex/config.toml"
grep -q 'args = \["mcp", "--read-only"\]' "$TEST_HOME/.codex/config.toml"
grep -q '^\[theme\]$' "$TEST_HOME/.codex/config.toml"

python3 - "$TEST_HOME" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
checks = [
    (home / ".cursor/mcp.json", "mcpServers"),
    (home / "Library/Application Support/Claude/claude_desktop_config.json", "mcpServers"),
    (home / "Library/Application Support/Code/User/mcp.json", "servers"),
]
for path, key in checks:
    data = json.loads(path.read_text())
    assert "keep" in data[key]
    entry = data[key]["notescli"]
    assert pathlib.Path(entry["command"]).is_absolute()
    assert entry["args"] == ["mcp", "--read-only"]
PY

HOME="$TEST_HOME" "$BINARY" mcp status
HOME="$TEST_HOME" "$BINARY" mcp uninstall --client all
! grep -q '^\[mcp_servers.notescli\]$' "$TEST_HOME/.codex/config.toml"

python3 - "$TEST_HOME" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
for path, key in [
    (home / ".cursor/mcp.json", "mcpServers"),
    (home / "Library/Application Support/Claude/claude_desktop_config.json", "mcpServers"),
    (home / "Library/Application Support/Code/User/mcp.json", "servers"),
]:
    data = json.loads(path.read_text())
    assert "notescli" not in data[key]
    assert "keep" in data[key]
PY

echo "MCP config tests passed in an isolated HOME."
