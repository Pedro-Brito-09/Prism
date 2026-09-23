#!/usr/bin/env bash
# Run the part of the suite that does not need Roblox.
#
# tests/Server.server.luau and tests/Client.client.luau need a DataModel and a
# player, so Studio is the only place they run. Varint, Handles and IdPool need
# neither, and they are the floor the storage format stands on -- so they are
# worth running on every push rather than once, by hand, when someone remembers.
#
# Fetches a pinned Luau CLI into .tooling/ (gitignored). Nothing to install.
set -euo pipefail

LUAU_VERSION="0.738"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLING="$ROOT/.tooling"
mkdir -p "$TOOLING"

case "$(uname -s)" in
    Linux*)   ASSET="luau-ubuntu.zip"; BIN="luau" ;;
    Darwin*)  ASSET="luau-macos.zip";  BIN="luau" ;;
    MINGW*|MSYS*|CYGWIN*) ASSET="luau-windows.zip"; BIN="luau.exe" ;;
    *) echo "Unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

if [ ! -x "$TOOLING/$BIN" ]; then
    echo "Fetching Luau $LUAU_VERSION..."
    curl -sSL -o "$TOOLING/luau.zip" \
        "https://github.com/luau-lang/luau/releases/download/$LUAU_VERSION/$ASSET"
    unzip -oq "$TOOLING/luau.zip" -d "$TOOLING"
    chmod +x "$TOOLING/$BIN" || true
fi

cd "$ROOT"
exec "$TOOLING/$BIN" tests/Pure.luau
