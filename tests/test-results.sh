#!/bin/bash
# Mutations use only marked temporary fixtures. A native-tool double tests the
# owner-command boundary; it is not evidence of native xcresult acceptance.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/Alice/results.xcresult/Data"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# shellcheck source=shredder.sh
source "$SCRIPT_DIR/../shredder.sh"
TEST_MODE=1; SANDBOX="$SHREDDER_ROOT"; resolve_paths
target="$USERS_DIR/Alice/results.xcresult"
printf 'not a real result\n' > "$target/Info.plist"
if module_selected testresults; then exit 1; fi
parse_args --modules testresults --test-result /Users/Alice/results.xcresult
# Real native invocation must refuse the malformed fixture, whether installed
# xcresulttool rejects it or the toolchain is unavailable.
module_testresults; [ "$FAILED_COUNT" -eq 1 ]; [ -d "$target" ]
eval "$(declare -f run_target_command | sed '1s/run_target_command/original_run_target_command/')"
run_target_command() {
    if [ "$2" = /usr/bin/xcrun ]; then
        [ "$3" = xcresulttool ] && [ "$4" = get ] && [ "$5" = content-availability ] &&
        [ "$6" = --path ] && [ "$7" = "$target" ] && [ "$8" = --compact ] || return 1
        return 0
    fi
    original_run_target_command "$@"
}
DRY_RUN=1; module_testresults; [ -d "$target" ]; [ "$CLEANED_COUNT" -eq 1 ]
DRY_RUN=0; module_testresults; [ ! -e "$target" ]; [ "$CLEANED_COUNT" -eq 2 ]
mkdir -p "$USERS_DIR/Alice/keep.xcarchive/Data"
printf keep > "$USERS_DIR/Alice/keep.xcarchive/Info.plist"
TEST_RESULTS=(/Users/Alice/keep.xcarchive)
module_testresults; [ -d "$USERS_DIR/Alice/keep.xcarchive" ]; [ "$FAILED_COUNT" -eq 2 ]
printf 'PASS: test result selection, native refusal, command boundary and archive retention\n'
