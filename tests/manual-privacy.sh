#!/bin/bash
# Manual workflows must never claim or perform an automatic deletion.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/Test/Library"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
printf 'private sentinel\n' > "$SHREDDER_ROOT/Users/Test/Library/data"
cp -R "$SHREDDER_ROOT" "$WORK/before"
MODULES=(mailhistory locationhistory callhistory messagehistory)
for module in "${MODULES[@]}"; do
    for mode in real preview; do
        rc=0; args=(--force --debug --modules "$module")
        [ "$mode" != preview ] || args+=(--dry-run)
        bash "$SHREDDER" "${args[@]}" > "$WORK/output" 2>&1 || rc=$?
        if [ "$mode" = real ]; then
            [ "$rc" = 2 ]; grep -q 'Total items cleaned: 0' "$WORK/output"
        else
            [ "$rc" = 0 ]; grep -q 'Total items that would be cleaned: 0' "$WORK/output"
        fi
        grep -q 'manual action required; no automatic cleanup was performed' "$WORK/output"
        grep -q 'official instructions: https://support.apple.com/' "$WORK/output"
        diff -r "$WORK/before" "$SHREDDER_ROOT"
    done
done
# Source only the definitions to verify default selection without host cleanup.
# shellcheck source=shredder.sh
source "$SHREDDER"
for module in "${MODULES[@]}"; do if module_selected "$module"; then exit 1; fi; done
printf 'PASS: manual workflows are explicit, preserve fixtures and report incomplete real cleanup\n'
