#!/bin/bash
# JSON parsing and deletion only use marked temporary fixture homes.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/Alice/Report's folder"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# shellcheck source=shredder.sh
source "$SCRIPT_DIR/../shredder.sh"
TEST_MODE=1; SANDBOX="$SHREDDER_ROOT"; resolve_paths
if module_selected aiexports; then exit 1; fi
requested="/Users/Alice/Report's folder/Apple_Intelligence_Report.json"
target="$SANDBOX$requested"
printf '{"modelRequests":[],"privateCloudComputeRequests":[]}\n' > "$target"
parse_args --modules aiexports --ai-export "$requested"
cp "$target" "$WORK/original"
DRY_RUN=1; module_aiexports
[ "$FAILED_COUNT" -eq 0 ]; cmp "$target" "$WORK/original"
DRY_RUN=0; module_aiexports; [ ! -e "$target" ]
printf '{"modelRequests":[],"privateCloudComputeRequests":{}}\n' > "$target"
module_aiexports; [ -f "$target" ]; [ "$FAILED_COUNT" -eq 1 ]
printf '{"unrelated":true}\n' > "$target"
module_aiexports; [ -f "$target" ]; [ "$FAILED_COUNT" -eq 2 ]
printf 'invalid json\n' > "$target"
module_aiexports; [ -f "$target" ]; [ "$FAILED_COUNT" -eq 3 ]
printf 'opaque encrypted export\n' > "$USERS_DIR/Alice/keep.rayconfig"
AI_EXPORTS=(/Users/Alice/keep.rayconfig)
module_aiexports; [ -f "$USERS_DIR/Alice/keep.rayconfig" ]; [ "$FAILED_COUNT" -eq 4 ]
printf 'PASS: AI report identity, JSON structure, dry-run and opaque export retention\n'
