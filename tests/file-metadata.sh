#!/bin/bash
# Only synthetic files in a marked fixture are changed.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/User Space/files" "$WORK/bin"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# Linux CI uses a file-backed boundary double for macOS xattr.
if [ "$(uname -s)" != Darwin ]; then
    cat > "$WORK/bin/xattr" <<'MOCK'
#!/bin/sh
[ "$1" = -s ] || exit 1
shift
if [ "$1" = -d ]; then
    [ "$2" = com.apple.metadata:kMDItemWhereFroms ] || exit 1
    printf '' > "$3.attrs"
else
    cat "$1.attrs"
fi
MOCK
    chmod +x "$WORK/bin/xattr"
    export PATH="$WORK/bin:$PATH"
fi
# shellcheck source=shredder.sh
source "$SCRIPT_DIR/../shredder.sh"
TEST_MODE=1
SANDBOX="$SHREDDER_ROOT"
resolve_paths
if module_selected filemetadata; then exit 1; fi
parse_args --modules filemetadata --metadata-file '/Users/User Space/files/document'
FILE="$USERS_DIR/User Space/files/document"
printf 'preserve file content\n' > "$FILE"
cp "$FILE" "$WORK/content"
ATTR=com.apple.metadata:kMDItemWhereFroms
seed() {
    if [ "$(uname -s)" = Darwin ]; then
        /usr/bin/xattr -w "$ATTR" 'https://example.invalid/synthetic' "$1"
        /usr/bin/xattr -w org.example.preserve keep "$1"
    else
        printf '%s\n' "$ATTR" > "$1.attrs"
    fi
}
seed "$FILE"
DRY_RUN=1
module_filemetadata
[ "$CLEANED_COUNT" -eq 1 ] && [ "$FAILED_COUNT" -eq 0 ]
xattr -s "$FILE" | grep -Fx "$ATTR" >/dev/null
DRY_RUN=0
module_filemetadata
[ "$CLEANED_COUNT" -eq 2 ] && [ "$FAILED_COUNT" -eq 0 ]
if xattr -s "$FILE" | grep -Fx "$ATTR" >/dev/null; then exit 1; fi
cmp "$FILE" "$WORK/content"
if [ "$(uname -s)" = Darwin ]; then [ "$(/usr/bin/xattr -p org.example.preserve "$FILE")" = keep ]; fi
module_filemetadata
[ "$CLEANED_COUNT" -eq 2 ] && [ "$FAILED_COUNT" -eq 0 ]
printf 'PASS: selective origin removal, content and other metadata preserved, dry-run and repeat\n'
seed "$FILE"
ln "$FILE" "$USERS_DIR/User Space/files/hardlink"
clear_file_origin "$FILE"
[ "$FAILED_COUNT" -eq 1 ]
xattr -s "$FILE" | grep -Fx "$ATTR" >/dev/null
ln -s "$FILE" "$USERS_DIR/User Space/files/link"
clear_file_origin "$USERS_DIR/User Space/files/link"
clear_file_origin "$USERS_DIR/User Space/files"
[ "$FAILED_COUNT" -eq 3 ]
METADATA_FILES=(/Users/Missing/document)
module_filemetadata
[ "$FAILED_COUNT" -eq 4 ]
for bad in /etc/passwd /Users/Shared/document /Users/Alice/../Bob/document /Users/Alice//document /Users/Alice/doc/; do
    if (add_metadata_file "$bad") >/dev/null 2>&1; then exit 1; fi
done
if (METADATA_FILES=(); parse_args --modules filemetadata) >/dev/null 2>&1; then exit 1; fi
if (parse_args --modules shell) >/dev/null 2>&1; then exit 1; fi
printf 'PASS: links, directories, ineligible homes and invalid selections refused\n'
