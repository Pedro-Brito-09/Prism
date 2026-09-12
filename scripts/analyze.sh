#!/usr/bin/env bash
# Type check every Luau file in the repo.
#
# The roadmap said for a long time that there is no Luau tooling on this
# machine and that nothing type checks the code. That was never a property of
# the code -- it is a property of what was installed. This fetches a pinned
# luau-lsp and the Roblox API definitions into .tooling/ (gitignored) and runs
# the analyser over src/ and tests/. Nothing has to be installed first.
#
# Usage: scripts/analyze.sh [extra luau-lsp arguments]
set -euo pipefail

LUAU_LSP_VERSION="1.69.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLING="$ROOT/.tooling"
mkdir -p "$TOOLING"

case "$(uname -s)" in
    Linux*)   ASSET="luau-lsp-linux-x86_64.zip"; BIN="luau-lsp" ;;
    Darwin*)  ASSET="luau-lsp-macos.zip";        BIN="luau-lsp" ;;
    MINGW*|MSYS*|CYGWIN*) ASSET="luau-lsp-win64.zip"; BIN="luau-lsp.exe" ;;
    *) echo "Unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

if [ ! -x "$TOOLING/$BIN" ]; then
    echo "Fetching luau-lsp $LUAU_LSP_VERSION..."
    curl -sSL -o "$TOOLING/luau-lsp.zip" \
        "https://github.com/JohnnyMorganz/luau-lsp/releases/download/$LUAU_LSP_VERSION/$ASSET"
    unzip -oq "$TOOLING/luau-lsp.zip" -d "$TOOLING"
    chmod +x "$TOOLING/$BIN" || true
fi

# Regenerated upstream as Roblox ships API changes, so it is not pinned: a
# stale copy would report members that exist as missing.
if [ ! -f "$TOOLING/globalTypes.d.luau" ]; then
    echo "Fetching Roblox API definitions..."
    curl -sSL -o "$TOOLING/globalTypes.d.luau" \
        "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
fi

cd "$ROOT"
exec "$TOOLING/$BIN" analyze \
    --defs="$TOOLING/globalTypes.d.luau" \
    --base-luaurc="$ROOT/.luaurc" \
    --platform=roblox \
    "$@" \
    $(find src tests -name '*.luau' | sort)
