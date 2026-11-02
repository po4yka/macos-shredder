#!/bin/bash
# Only marked temporary fixture homes are changed.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/User Space/Downloads"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# shellcheck source=shredder.sh
source "$SCRIPT_DIR/../shredder.sh"
TEST_MODE=1; SANDBOX="$SHREDDER_ROOT"; resolve_paths
if module_selected diagnosticexports; then exit 1; fi
parse_args --modules diagnosticexports --diagnostic-export '/Users/User Space/Downloads/sysdiagnose_fixture.tar.gz'
target="$USERS_DIR/User Space/Downloads/sysdiagnose_fixture.tar.gz"
mkdir -p "$WORK/archive/sysdiagnose_fixture/system_logs.logarchive"
printf 'fixture\n' > "$WORK/archive/sysdiagnose_fixture/sysdiagnose.log"
printf 'fixture\n' > "$WORK/archive/sysdiagnose_fixture/system_logs.logarchive/Info.plist"
tar -czf "$target" -C "$WORK/archive" sysdiagnose_fixture
cp "$target" "$WORK/original"
DRY_RUN=1; module_diagnosticexports
cmp "$target" "$WORK/original"
[ "$CLEANED_COUNT" -eq 1 ]; [ "$FAILED_COUNT" -eq 0 ]
DRY_RUN=0; module_diagnosticexports
[ ! -e "$target" ]
# Unknown archives, incomplete archives, links and hard links stay intact.
printf 'not gzip\n' > "$target"
module_diagnosticexports; [ -f "$target" ]; [ "$FAILED_COUNT" -eq 1 ]
cp "$WORK/original" "$target"
ln "$target" "$WORK/hardlink"
module_diagnosticexports; [ -f "$target" ]; [ "$FAILED_COUNT" -eq 2 ]
rm "$WORK/hardlink" "$target"
ln -s "$WORK/original" "$target"
module_diagnosticexports; [ -L "$target" ]
# Tree guard rejects nested links, hard links and special files.
mkdir "$WORK/tree"; printf keep > "$WORK/tree/file"
mkdir "$USERS_DIR/User Space/Downloads/log.logarchive"
ln -s "$WORK/tree/file" "$USERS_DIR/User Space/Downloads/log.logarchive/link"
if selected_artifact_safe "$USERS_DIR/User Space/Downloads/log.logarchive"; then exit 1; fi
for bad in /tmp/report /Users/Shared/report /Users/User/../report; do
    if (add_selected_artifact diagnosticexports "$bad") >/dev/null 2>&1; then exit 1; fi
done
if (parse_args --modules shell) >/dev/null 2>&1; then exit 1; fi
# Process and lsof failures must fail closed, including dry-run.
TEST_MODE=0
ps() { return 2; }
if selected_artifact_idle "$target" sysdiagnose; then exit 1; fi
ps() { printf '/usr/bin/sysdiagnose\n'; }
if selected_artifact_idle "$target" sysdiagnose; then exit 1; fi
ps() { printf '/bin/other\n'; }
lsof() { return 1; }
selected_artifact_idle "$target" sysdiagnose
lsof() { printf 'incomplete process visibility\n'; return 1; }
if selected_artifact_idle "$target" sysdiagnose; then exit 1; fi
printf 'PASS: diagnostic exports, dry-run, identity and safety boundaries\n'
