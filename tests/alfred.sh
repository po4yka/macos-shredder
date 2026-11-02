#!/bin/bash
# Manual Alfred workflow: no fixture or host clipboard mutation.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/Test/Library/Application Support/Alfred"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
for name in clipboard.db snippets.db preferences.plist workflow credentials; do
    printf 'preserve %s\n' "$name" > "$SHREDDER_ROOT/Users/Test/Library/Application Support/Alfred/$name"
done
cp -R "$SHREDDER_ROOT" "$WORK/before"
/bin/bash "$SCRIPT_DIR/../shredder.sh" --modules alfred --dry-run > "$WORK/dry.log" 2>&1
grep -q 'Clear Alfred.*entire clipboard history' "$WORK/dry.log"
set +e
/bin/bash "$SCRIPT_DIR/../shredder.sh" --modules alfred --force > "$WORK/real.log" 2>&1
status=$?
set -e
[ "$status" -eq 2 ]
diff -r "$WORK/before" "$SHREDDER_ROOT"
(
    # shellcheck source=shredder.sh
    source "$SCRIPT_DIR/../shredder.sh"
    if module_selected alfred; then exit 1; fi
    DRY_RUN=0
    module_alfred
    [ "$CLEANED_COUNT" -eq 0 ]
    [ "$FAILED_COUNT" -eq 1 ]
    DRY_RUN=1
    module_alfred
    [ "$FAILED_COUNT" -eq 1 ]
)
printf 'PASS: Alfred explicit selection, manual instructions, exit status, zero cleaned count and fixture preservation\n'
