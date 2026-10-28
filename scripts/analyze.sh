#!/usr/bin/env bash
# Type check every Luau file in the repo.
#
# The roadmap said for a long time that there is no Luau tooling on this
# machine and that nothing type checks the code. That was never a property of
# the code -- it is a property of what was installed. This fetches a pinned
# luau-lsp and the Roblox API definitions into .tooling/ (gitignored) and runs
# the analyser over src/ and tests/. Nothing has to be installed first.
#
#   scripts/analyze.sh                 ratchet against the baseline; CI runs this
#   scripts/analyze.sh --raw           print every diagnostic and exit 0
#   scripts/analyze.sh --update-baseline   rewrite the baseline from what is there now
#
# Checked under the new type solver, which is the one the code is written for:
# `type function`, `read` fields and the rest are new-solver features, and the
# default solver reports them as errors that are not.
#
# Why a ratchet rather than a clean bill of health. src/ is clean. What is left
# is the suites' `require("./Prism")`, which resolves inside the test model --
# build.js puts a copy of Prism beside the suites -- but names nothing on disk,
# so everything a suite gets from Prism reads as any. The baseline records how
# many diagnostics each file has and the build fails when a file grows a new
# one, so those three do not have to be pretended away for the check to hold.
set -euo pipefail

LUAU_LSP_VERSION="1.69.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLING="$ROOT/.tooling"
BASELINE="$ROOT/.analyze-baseline.txt"
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

# Every file is analysed on its own as well as through whatever requires it, so
# the same diagnostic is reported once per importer. Dedupe before counting or
# a file's number would depend on how many other files pull it in.
run() {
    "$TOOLING/$BIN" analyze \
        --defs="$TOOLING/globalTypes.d.luau" \
        --base-luaurc="$ROOT/.luaurc" \
        --platform=roblox \
        --flag:LuauSolverV2=true \
        $(find src tests -name '*.luau' | sort) 2>&1 \
    | grep -vE '^\[INFO\]' || true
}

RAW="$(run)"
DIAGS="$(printf '%s\n' "$RAW" | grep -E '^(src|tests)/[^ ]*\([0-9]+,[0-9]+\): ' | sort -u || true)"

if [ "${1:-}" = "--raw" ]; then
    printf '%s\n' "$RAW"
    exit 0
fi

# path -> count, one line each, sorted so the file diffs cleanly.
counts() {
    if [ -z "$DIAGS" ]; then return 0; fi
    printf '%s\n' "$DIAGS" | sed 's/(.*//' | sort | uniq -c | awk '{printf "%s\t%s\n", $2, $1}'
}

NOW="$(counts)"

if [ "${1:-}" = "--update-baseline" ]; then
    printf '%s\n' "$NOW" > "$BASELINE"
    echo "Baseline updated: $(printf '%s\n' "$NOW" | awk -F'\t' '{s+=$2} END {print s+0}') diagnostics across $(printf '%s\n' "$NOW" | grep -c . || true) files."
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "No baseline at $BASELINE. Create one with: scripts/analyze.sh --update-baseline" >&2
    exit 1
fi

FAILED=0
IMPROVED=0

while IFS=$'\t' read -r FILE COUNT; do
    [ -z "$FILE" ] && continue
    WAS="$(awk -F'\t' -v f="$FILE" '$1==f {print $2}' "$BASELINE")"
    WAS="${WAS:-0}"
    if [ "$COUNT" -gt "$WAS" ]; then
        echo "FAIL $FILE: $COUNT diagnostics, baseline $WAS"
        printf '%s\n' "$DIAGS" | grep -F "$FILE(" | sed 's/^/      /'
        FAILED=1
    elif [ "$COUNT" -lt "$WAS" ]; then
        echo "     $FILE: $COUNT diagnostics, down from $WAS"
        IMPROVED=1
    fi
done <<< "$NOW"

# A file that cleared entirely drops out of NOW, so walk the baseline too.
while IFS=$'\t' read -r FILE WAS; do
    [ -z "$FILE" ] && continue
    if ! printf '%s\n' "$NOW" | grep -qF "$FILE"$'\t'; then
        echo "     $FILE: clean, down from $WAS"
        IMPROVED=1
    fi
done < "$BASELINE"

TOTAL="$(printf '%s\n' "$NOW" | awk -F'\t' '{s+=$2} END {print s+0}')"
BASE_TOTAL="$(awk -F'\t' '{s+=$2} END {print s+0}' "$BASELINE")"

if [ "$FAILED" = "1" ]; then
    echo
    echo "New diagnostics above the baseline. Fix them, or if they are deliberate," >&2
    echo "run scripts/analyze.sh --update-baseline and say why in the commit." >&2
    exit 1
fi

echo "OK: $TOTAL diagnostics, baseline $BASE_TOTAL."
if [ "$IMPROVED" = "1" ]; then
    echo "Some files improved. Run scripts/analyze.sh --update-baseline to lock that in."
fi
