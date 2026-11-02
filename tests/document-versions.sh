#!/bin/bash
# Native version operations target only this marked synthetic fixture.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/Fixture User/documents"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# shellcheck source=shredder.sh
source "$SCRIPT_DIR/../shredder.sh"
TEST_MODE=1; SANDBOX="$SHREDDER_ROOT"; resolve_paths
if module_selected documentversions; then exit 1; fi
parse_args --modules documentversions --version-file '/Users/Fixture User/documents/current.txt'
add_version_file '/Users/Fixture User/documents/current.txt'
[ "${#VERSION_FILES[@]}" -eq 1 ]
FILE="$USERS_DIR/Fixture User/documents/current.txt"
printf 'current content\n' > "$FILE"
printf 'old content\n' > "$WORK/old.txt"
cp "$FILE" "$WORK/expected.txt"
if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/osascript -l JavaScript - "$FILE" "$WORK/old.txt" <<'JXA' >/dev/null
ObjC.import('Foundation');
function run(argv) {
    const url = $.NSURL.fileURLWithPath(argv[0]);
    const coordinator = $.NSFileCoordinator.alloc.initWithFilePresenter($());
    let success = false;
    coordinator.coordinateWritingItemAtURLOptionsErrorByAccessor(url, 0, Ref(), function(item) {
        const version = $.NSFileVersion.addVersionOfItemAtURLWithContentsOfURLOptionsError(
            item, $.NSURL.fileURLWithPath(argv[1]), 0, Ref());
        success = !!version && !version.isNil();
    });
    if (!success) throw Error('cannot create synthetic version');
}
JXA
else
    # Behavioral double only. It does not claim native API coverage on Linux.
    document_versions_native() {
        [ -f "$1.versions" ] || { printf 'none\n'; return; }
        [ "$(stat -c %h "$1")" = 1 ] || return 1
        if [ "$2" = 1 ]; then printf 'planned\n'; else rm "$1.versions"; printf 'cleaned\n'; fi
    }
    : > "$FILE.versions"
    printf 'SKIP: native NSFileVersion check requires macOS\n'
fi
DRY_RUN=1; module_documentversions
[ "$CLEANED_COUNT" -eq 1 ] && [ "$FAILED_COUNT" -eq 0 ]
[ "$(document_versions_native "$FILE" 1)" = planned ]
cmp "$FILE" "$WORK/expected.txt"
DRY_RUN=0; module_documentversions
[ "$CLEANED_COUNT" -eq 2 ] && [ "$FAILED_COUNT" -eq 0 ]
[ "$(document_versions_native "$FILE" 1)" = none ]
cmp "$FILE" "$WORK/expected.txt"
module_documentversions
[ "$CLEANED_COUNT" -eq 2 ] && [ "$FAILED_COUNT" -eq 0 ]
printf 'PASS: selected versions removed, current content preserved, dry-run and repeat\n'
if [ "$(uname -s)" != Darwin ]; then : > "$FILE.versions"; fi
ln "$FILE" "$FILE.hardlink"
module_documentversions
[ "$FAILED_COUNT" -eq 1 ]
rm "$FILE.hardlink"
ln -s "$FILE" "$FILE.link"
VERSION_FILES=('/Users/Fixture User/documents/current.txt.link'); module_documentversions
VERSION_FILES=('/Users/Fixture User/documents/missing.txt'); module_documentversions
[ ! -e "$USERS_DIR/Fixture User/documents/missing.txt" ]
VERSION_FILES=('/Users/Fixture User/documents'); module_documentversions
VERSION_FILES=('/Users/Absent/file'); module_documentversions
[ "$FAILED_COUNT" -eq 5 ]
for bad in /etc/passwd /Users/Shared/file /Users/Guest/file /Users/.hidden/file /Users/User/../Other/file /Users/User//file /Users/User/file/; do
    if (add_version_file "$bad") >/dev/null 2>&1; then exit 1; fi
done
if (VERSION_FILES=(); parse_args --modules documentversions) >/dev/null 2>&1; then exit 1; fi
if (parse_args --modules shell) >/dev/null 2>&1; then exit 1; fi
# A native failure must not be counted as successful removal.
VERSION_FILES=('/Users/Fixture User/documents/current.txt')
document_versions_native() { return 1; }
module_documentversions
[ "$FAILED_COUNT" -eq 6 ] && [ "$CLEANED_COUNT" -eq 2 ]
printf 'PASS: missing, linked, invalid and failed targets refused\n'
