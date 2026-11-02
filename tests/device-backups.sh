#!/bin/bash
# Native plist/SQLite checks only operate on marked temporary fixtures.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/Alice"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# shellcheck source=shredder.sh
source "$SCRIPT_DIR/../shredder.sh"
TEST_MODE=1; SANDBOX="$SHREDDER_ROOT"; resolve_paths
if module_selected devicebackups; then exit 1; fi
# Linux CI has no native plutil. Keep production dispatch intact on Darwin;
# on Linux, use a plist parser at the native-command boundary for fixture tests.
fixture_plutil() {
    if [ "$(uname -s)" = Darwin ] && [ "${SHREDDER_TEST_PLUTIL_ADAPTER:-0}" != 1 ]; then
        /usr/bin/plutil "$@"; return
    fi
    python3 - "$@" <<'PYPLIST'
import plistlib, sys
from pathlib import Path
args=sys.argv[1:]; path=Path(args[-1]); data=plistlib.loads(path.read_bytes())
if args[0] == '-lint':
    pass
elif args[0] == '-extract':
    value=data[args[1]]; kind=args[args.index('-expect')+1]
    if (kind == 'bool' and type(value) is not bool) or (kind == 'string' and type(value) is not str):
        sys.exit(1)
    print(str(value).lower() if type(value) is bool else value)
elif args[0] == '-replace':
    data[args[1]]=(args[3] == 'YES') if args[2] == '-bool' else args[3]
    path.write_bytes(plistlib.dumps(data))
else:
    sys.exit(1)
PYPLIST
}
eval "$(declare -f run_target_command | sed '1s/run_target_command/original_run_target_command/')"
run_target_command() {
    if [ "$2" = /usr/bin/plutil ]; then shift 2; fixture_plutil "$@"; return; fi
    original_run_target_command "$@"
}
identifier=12345678-0123456789ABCDEF
requested="/Users/Alice/Library/Application Support/MobileSync/Backup/$identifier"
target="$SANDBOX$requested"
mkdir -p "$target"
# plistlib only builds fixtures; the shipped script uses native plutil.
python3 - "$target" "$identifier" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1])
for name,data in [('Info',{'Target Identifier':sys.argv[2]}),('Manifest',{'IsEncrypted':False}),('Status',{'SnapshotState':'finished'})]:
    (p/(name+'.plist')).write_bytes(plistlib.dumps(data))
PY
sqlite3 "$target/Manifest.db" 'CREATE TABLE Files(fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB);'
parse_args --modules devicebackups --device-backup "$requested"
cp -R "$target" "$WORK/original"
DRY_RUN=1; module_devicebackups
[ "$FAILED_COUNT" -eq 0 ]; diff -r "$target" "$WORK/original"
DRY_RUN=0; module_devicebackups
[ ! -e "$target" ]; [ "$CLEANED_COUNT" -eq 2 ]
cp -R "$WORK/original" "$target"
fixture_plutil -replace SnapshotState -string in_progress "$target/Status.plist"
module_devicebackups; [ -d "$target" ]; [ "$FAILED_COUNT" -eq 1 ]
fixture_plutil -replace SnapshotState -string finished "$target/Status.plist"
fixture_plutil -replace IsEncrypted -bool YES "$target/Manifest.plist"
module_devicebackups; [ -d "$target" ]; [ "$FAILED_COUNT" -eq 2 ]
fixture_plutil -replace IsEncrypted -bool NO "$target/Manifest.plist"
sqlite3 "$target/Manifest.db" 'ALTER TABLE Files RENAME TO Unknown;'
module_devicebackups; [ -d "$target" ]; [ "$FAILED_COUNT" -eq 3 ]
printf 'PASS: device backup identity, completion, encryption, schema and dry-run\n'
