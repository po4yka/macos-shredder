#!/bin/bash
# Never call a real dictionary mutation: HOME does not isolate spellcheckd.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/Fixture"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# shellcheck source=shredder.sh
source "$SCRIPT_DIR/../shredder.sh"
TEST_MODE=1; SANDBOX="$SHREDDER_ROOT"; resolve_paths
if module_selected spelling; then exit 1; fi
if spelling_native "$USERS_DIR/Fixture" 501 syntheticword 0; then exit 1; fi
if spelling_console_user; then exit 1; fi
parse_args --modules spelling --spelling-word syntheticword --spelling-word=anotherword
add_spelling_word syntheticword
[ "${#SPELLING_WORDS[@]}" -eq 2 ]
printf 'syntheticword\nanotherword\npreserveword\n' > "$WORK/dictionary"
cp "$WORK/dictionary" "$WORK/expected"
spelling_console_user() { printf 'Fixture\t%s\t501\n' "$USERS_DIR/Fixture"; }
spelling_native() {
    [ "$1" = "$USERS_DIR/Fixture" ] && [ "$2" = 501 ] || return 1
    grep -Fx -- "$3" "$WORK/dictionary" >/dev/null || { printf 'none\n'; return; }
    if [ "$4" = 1 ]; then printf 'planned\n'; return; fi
    grep -Fxv -- "$3" "$WORK/dictionary" > "$WORK/remainder" || true
    mv "$WORK/remainder" "$WORK/dictionary"
    printf 'cleaned\n'
}
DRY_RUN=1; DEBUG=1
module_spelling 2> "$WORK/output"
[ "$CLEANED_COUNT" -eq 2 ] && [ "$FAILED_COUNT" -eq 0 ]
cmp "$WORK/dictionary" "$WORK/expected"
DRY_RUN=0; module_spelling 2>> "$WORK/output"
[ "$CLEANED_COUNT" -eq 4 ] && [ "$FAILED_COUNT" -eq 0 ]
[ "$(cat "$WORK/dictionary")" = preserveword ]
module_spelling 2>> "$WORK/output"
[ "$CLEANED_COUNT" -eq 4 ] && [ "$FAILED_COUNT" -eq 0 ]
if grep -E 'syntheticword|anotherword|preserveword' "$WORK/output"; then exit 1; fi
for bad in '' 'two words' $'line\nbreak' $'tab\tword'; do
    if (add_spelling_word "$bad") >/dev/null 2>&1; then exit 1; fi
done
if (SPELLING_WORDS=(); parse_args --modules spelling) >/dev/null 2>&1; then exit 1; fi
if (parse_args --modules shell) >/dev/null 2>&1; then exit 1; fi
spelling_native() { return 1; }
module_spelling
[ "$FAILED_COUNT" -eq 2 ] && [ "$CLEANED_COUNT" -eq 4 ]
spelling_console_user() { return 1; }
module_spelling
[ "$FAILED_COUNT" -eq 3 ] && [ "$CLEANED_COUNT" -eq 4 ]
if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/osascript -l JavaScript <<'JXA' >/dev/null
ObjC.import('AppKit');
if (!$.NSSpellChecker.instancesRespondToSelector('unlearnWord:') ||
    !$.NSSpellChecker.instancesRespondToSelector('hasLearnedWord:')) throw Error('selectors unavailable');
JXA
else
    printf 'SKIP: native AppKit selector check requires macOS\n'
fi
printf 'PASS: selected words, dry-run, duplicates, private output, failures and native test-mode guard\n'
