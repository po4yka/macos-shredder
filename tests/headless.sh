#!/bin/bash
# All files and destructive calls stay inside a marked temporary fixture.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/User Space"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
ROOT="$SHREDDER_ROOT/Users/User Space/Library/Application Support/Google/Chrome-headless"
profile() {
    mkdir -p "$ROOT/$1/Default"
    printf '{}\n' > "$ROOT/$1/Local State"
    printf 'history\n' > "$ROOT/$1/Default/History"
    find "$ROOT/$1" -exec touch -t 202001010000 {} +
}
run() {
    local expected="$1" rc=0
    shift
    bash "$SHREDDER" "$@" > "$WORK/run.log" 2>&1 || rc=$?
    if [ "$rc" != "$expected" ]; then cat "$WORK/run.log"; exit 1; fi
}
profile scoped_dirOld
profile scoped_dirRecent
touch "$ROOT/scoped_dirRecent/Default/History"
profile scoped_dirLocked
: > "$ROOT/scoped_dirLocked/SingletonLock"
touch -t 202001010000 "$ROOT/scoped_dirLocked"
mkdir -p "$ROOT/scoped_dirUnknown"
printf 'keep\n' > "$ROOT/scoped_dirUnknown/document"
find "$ROOT/scoped_dirUnknown" -exec touch -t 202001010000 {} +
mkdir -p "$WORK/outside"
printf 'keep\n' > "$WORK/outside/sentinel"
ln -s "$WORK/outside" "$ROOT/scoped_dirLink"

cp -R "$SHREDDER_ROOT" "$WORK/before"
run 2 --modules headless --dry-run --debug
diff -r "$WORK/before" "$SHREDDER_ROOT"
run 2 --modules headless --force
[ ! -e "$ROOT/scoped_dirOld" ]
for name in scoped_dirRecent scoped_dirLocked scoped_dirUnknown; do [ -d "$ROOT/$name" ]; done
[ -L "$ROOT/scoped_dirLink" ]
grep -q keep "$WORK/outside/sentinel"
run 2 --modules headless --force
printf 'PASS: old headless profiles removed; recent, locked and unknown data retained; dry-run stable\n'

for arg in 0 -1 01 100000 abc; do run 64 --modules headless --headless-days "$arg" --dry-run; done
run 64 --modules headless --headless-days
# Test selection directly so no unrelated cleanup module is invoked.
# shellcheck source=shredder.sh
source "$SHREDDER"
if module_selected headless || module_selected clipboard || module_selected slackexport; then exit 1; fi
TEST_MODE=0
ps() { printf '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n'; }
if headless_stopped; then exit 1; fi
ps() { printf 'node /tools/playwright/cli.js test\n'; }
if headless_stopped; then exit 1; fi
ps() { printf 'node /tools/node_modules/@playwright/mcp/cli.js\n'; }
if headless_stopped; then exit 1; fi
ps() { printf 'node /tools/node_modules/chrome-devtools-mcp/build/src/index.js\n'; }
if headless_stopped; then exit 1; fi
ps() { return 1; }
if headless_stopped; then exit 1; fi
ps() { printf '/usr/bin/unrelated\n'; }
headless_stopped
unset -f ps
printf 'PASS: explicit selection, age validation and fail-closed browser process guards\n'

# A parent replacement between the guard and owner command cannot redirect
# deletion to a different physical directory.
TEST_MODE=1
SANDBOX="$SHREDDER_ROOT"
resolve_paths
mkdir -p "$USERS_DIR/User Space/chosen/profile" "$WORK/escape/profile"
printf 'keep\n' > "$WORK/escape/profile/keep"
run_target_command() {
    shift
    mv "$USERS_DIR/User Space/chosen" "$USERS_DIR/User Space/original"
    ln -s "$WORK/escape" "$USERS_DIR/User Space/chosen"
    "$@"
}
selected_remove_path "$USERS_DIR/User Space/chosen/profile"
[ "$FAILED_COUNT" = 1 ]
[ -f "$WORK/escape/profile/keep" ]
[ -d "$USERS_DIR/User Space/original/profile" ]
printf 'PASS: selected-target removal rejects a replaced parent\n'
