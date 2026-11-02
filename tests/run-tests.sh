#!/usr/bin/env bash
#
# tests/run-tests.sh — orchestrator for the macos-shredder integration suite.
#
# Phases:
#   A  usage validation   unknown --modules value -> exit 64 + valid ids listed
#   B  module listing     --list -> exit 0 + all registered module ids present
#   C  forced clean       artifacts -> --force --debug -> post-state verified
#   D  dry-run safety     artifacts+manifest -> -n -f -> byte-identical state
#   E  sandbox guard      unmarked SHREDDER_ROOT -> fatal refusal
#   F  confirmation       non-interactive real run -> refusal + unchanged data
#   G  host isolation     sandbox mode -> no defaults/qlmanage execution
#   H  least privilege    user-home mutations -> owner UID command wrapper
#   I  symlink refusal     adversarial fixture -> exact expected failures
#   J  sandbox boundary    system-path symlink -> no sandbox escape
#   K  trusted PATH        real mode ignores caller-provided commands
#   L  SQLite discovery    KnowledgeC inspection errors fail closed
#   M  Spotlight result    native dry-run reports its requested operation
#   N  cache parent race   a replaced cache parent cannot redirect deletion
#   O  Firefox failures    database errors cannot delete bookmarks
#
# After phases A-O: regressions, AI sessions, AI editors, browser stores,
# shell stores, editor history and mounted-volume Trash suites.
# Exit codes: 0 all checks passed; 1 a phase failed; a later suite can also
# return its own nonzero status; 77 shredder.sh is missing.
#
# Each suite uses a temporary work directory removed on exit. A phase A-O
# failure copies that phase runner's logs, manifests and sandbox trees to
# <repo>/tests-last-run/. Later suites report failures through their output;
# their temporary data is not copied by this runner.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHREDDER="$REPO_ROOT/shredder.sh"
CREATE_ARTIFACTS="$SCRIPT_DIR/create-artifacts.sh"
VERIFY_CLEANUP="$SCRIPT_DIR/verify-cleanup.sh"

readonly MODULE_IDS=(
  shell systemlogs audit browser unified fileevents fsevents usage spotlight
  quicklook trash dsstore wifi brew apps editors ai clipboard headless slackexport terminal finderhistory filemetadata documentversions notifications activity siri mailhistory locationhistory callhistory messagehistory photometadata
)

WORK=''

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

info() { printf '[run-tests] %s\n' "$1"; }

if [ ! -f "$SHREDDER" ]; then
  info "shredder.sh not built yet (expected at $SHREDDER)"
  exit 77
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  info 'sqlite3 is required to verify Firefox bookmark preservation'
  exit 1
fi

WORK="$(mktemp -d)"
info "work dir: $WORK"

RES_A='FAIL'
RES_B='FAIL'
RES_C='FAIL'
RES_D='FAIL'
RES_E='FAIL'
RES_F='FAIL'
RES_G='FAIL'
RES_H='FAIL'
RES_I='FAIL'
RES_J='FAIL'
RES_K='FAIL'
RES_L='FAIL'
RES_M='FAIL'
RES_N='FAIL'
RES_O='FAIL'

phase_a_usage_validation() {
  local sb="$WORK/sandbox-a" log="$WORK/phase-a.log" rc=0 ok=1
  local option value
  mkdir -p "$sb"
  info 'running: SHREDDER_ROOT=<sandbox> bash shredder.sh --modules bogus_definitely_invalid'
  SHREDDER_ROOT="$sb" bash "$SHREDDER" --modules bogus_definitely_invalid >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 64)"
  if [ "$rc" -ne 64 ]; then
    ok=0
  fi
  if grep -q 'trash' "$log"; then
    info 'output mentions a valid module id (trash): yes'
  else
    info 'output mentions a valid module id (trash): NO'
    ok=0
  fi
  # An explicitly empty selection must never fall back to all modules.
  : > "$sb/.macos-shredder-test-root"
  mkdir -p "$sb/Users/alice/.Trash"
  printf 'preserve history\n' > "$sb/Users/alice/.zsh_history"
  printf 'preserve trash\n' > "$sb/Users/alice/.Trash/sentinel"
  for option in -m --modules; do
    for value in '' '   '; do
      rc=0
      SHREDDER_ROOT="$sb" bash "$SHREDDER" --force "$option" "$value" >"$log" 2>&1 || rc=$?
      [ "$rc" -eq 64 ] || ok=0
      grep -q '^preserve history$' "$sb/Users/alice/.zsh_history" || ok=0
      grep -q '^preserve trash$' "$sb/Users/alice/.Trash/sentinel" || ok=0
    done
  done
  rc=0
  SHREDDER_ROOT="$sb" bash "$SHREDDER" --force --modules= >"$log" 2>&1 || rc=$?
  [ "$rc" -eq 64 ] || ok=0
  [ "$ok" -eq 1 ]
}

phase_b_list_modules() {
  local sb="$WORK/sandbox-b" log="$WORK/phase-b.log" rc=0 ok=1 id
  mkdir -p "$sb"
  info 'running: SHREDDER_ROOT=<sandbox> bash shredder.sh --list'
  SHREDDER_ROOT="$sb" bash "$SHREDDER" --list >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 0)"
  if [ "$rc" -ne 0 ]; then
    ok=0
  fi
  for id in "${MODULE_IDS[@]}"; do
    if grep -qw -- "$id" "$log"; then
      info "module listed: $id"
    else
      info "module MISSING from --list output: $id"
      ok=0
    fi
  done
  [ "$ok" -eq 1 ]
}

phase_c_force_clean() {
  local sb="$WORK/sandbox-c" log="$WORK/phase-c.log" negative="$WORK/phase-c-negative.log"
  local rc=0 ok=1 num='' qdb
  info "creating artifacts: $sb"
  bash "$CREATE_ARTIFACTS" "$sb" >"$WORK/phase-c-create.log"
  rm -f -- "$sb/Users/mallory" \
    "$sb/Users/alice/Library/Application Support/Chromium/Default"
  info 'running: SHREDDER_ROOT=<sandbox> bash shredder.sh --force --debug'
  SHREDDER_ROOT="$sb" bash "$SHREDDER" --force --debug >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 0)"
  [ "$rc" -eq 0 ] || ok=0
  if grep -q 'Total items cleaned:' "$log"; then
    num=$(sed -n 's/.*Total items cleaned:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log" | head -n 1)
    if [ -n "$num" ] && [ "$num" -gt 0 ]; then
      info "summary counter: Total items cleaned: $num (> 0)"
    else
      info "summary counter unparsable or zero: '$num'"
      ok=0
    fi
  else
    info "summary line 'Total items cleaned:' missing from output"
    ok=0
  fi
  if grep -q 'Failed operations: 0' "$log"; then
    info "summary reports zero failed operations"
  else
    info "summary line 'Failed operations:' missing from output"
    ok=0
  fi
  info 'verifying post-clean sandbox state'
  if bash "$VERIFY_CLEANUP" "$sb" --phase force; then
    info 'post-clean verification: PASS'
  else
    info 'post-clean verification: FAIL'
    ok=0
  fi
  if command -v sqlite3 >/dev/null 2>&1; then
    qdb="$sb/Users/alice/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
    printf 'not a SQLite database\n' >"$qdb"
    if bash "$VERIFY_CLEANUP" "$sb" --phase force >"$negative" 2>&1; then
      info 'corrupt SQLite verification unexpectedly passed'
      ok=0
    elif grep -q 'query failed:' "$negative"; then
      info 'corrupt SQLite verification: correctly failed closed'
    else
      info 'corrupt SQLite verification failed for an unexpected reason'
      ok=0
    fi
  fi
  [ "$ok" -eq 1 ]
}

phase_d_dryrun_safety() {
  local sb="$WORK/sandbox-d" manifest="$WORK/manifest.tsv" log="$WORK/phase-d.log"
  local negative="$WORK/phase-d-negative.log" rc=0 ok=1
  info "creating artifacts: $sb"
  bash "$CREATE_ARTIFACTS" "$sb" --manifest "$manifest" >"$WORK/phase-d-create.log"
  info 'running: SHREDDER_ROOT=<sandbox> bash shredder.sh -n -f --debug (dry run)'
  SHREDDER_ROOT="$sb" bash "$SHREDDER" -n -f --debug >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 0)"
  if [ "$rc" -ne 0 ]; then
    ok=0
  fi
  info 'verifying byte-identical dry-run stability'
  if bash "$VERIFY_CLEANUP" "$sb" --manifest "$manifest" --phase dryrun; then
    info 'dry-run stability: PASS'
  else
    info 'dry-run stability: FAIL'
    ok=0
  fi
  ln -sfn 'changed-target' "$sb/var/audit/current"
  if bash "$VERIFY_CLEANUP" "$sb" --manifest "$manifest" --phase dryrun >"$negative" 2>&1; then
    info 'changed symlink unexpectedly passed dry-run verification'
    ok=0
  elif grep -q 'symlink unchanged' "$negative"; then
    info 'changed symlink: correctly detected'
  else
    info 'changed symlink failed verification for an unexpected reason'
    ok=0
  fi
  [ "$ok" -eq 1 ]
}

phase_e_sandbox_guard() {
  local sb="$WORK/sandbox-e" log="$WORK/phase-e.log" rc=0
  mkdir -p "$sb"
  info 'running: unmarked SHREDDER_ROOT must be rejected'
  SHREDDER_ROOT="$sb" bash "$SHREDDER" --dry-run --force --modules shell >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 1)"
  [ "$rc" -eq 1 ] && grep -q '.macos-shredder-test-root' "$log"
}

phase_f_confirmation_guard() {
  local sb="$WORK/sandbox-f" log="$WORK/phase-f.log" rc=0
  bash "$CREATE_ARTIFACTS" "$sb" >"$WORK/phase-f-create.log"
  info 'running: non-interactive cleanup without --force must be rejected'
  SHREDDER_ROOT="$sb" bash "$SHREDDER" --modules shell </dev/null >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 1)"
  [ "$rc" -eq 1 ] \
    && grep -q 'aborted by user' "$log" \
    && grep -q 'SHREDTEST-HIST' "$sb/Users/alice/.zsh_history"
}

phase_g_host_command_isolation() {
  local sb="$WORK/sandbox-g" bin="$WORK/sandbox-g-bin" calls="$WORK/phase-g-host-calls.log"
  local log="$WORK/phase-g.log" rc=0 cmd
  bash "$CREATE_ARTIFACTS" "$sb" >"$WORK/phase-g-create.log"
  mkdir -p "$bin"
  for cmd in defaults qlmanage; do
    # shellcheck disable=SC2016 # variables expand when the generated stub runs
    printf '#!/bin/sh\nprintf "%%s\\n" "$0" >> "$SHREDDER_HOST_COMMAND_LOG"\n' >"$bin/$cmd"
    chmod +x "$bin/$cmd"
  done
  info 'running: sandbox mode must not execute defaults or qlmanage'
  PATH="$bin:$PATH" SHREDDER_HOST_COMMAND_LOG="$calls" SHREDDER_ROOT="$sb" \
    bash "$SHREDDER" --force --modules usage,quicklook >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 0)"
  [ "$rc" -eq 0 ] && [ ! -e "$calls" ]
}

phase_h_user_owner_commands() {
  local sb="$WORK/sandbox-h" bin="$WORK/sandbox-h-bin" calls="$WORK/phase-h-sudo.log"
  local sqlite_calls="$WORK/phase-h-sqlite.log" log="$WORK/phase-h.log" rc=0 real_sqlite
  real_sqlite="$(command -v sqlite3)"
  bash "$CREATE_ARTIFACTS" "$sb" >"$WORK/phase-h-create.log"
  mkdir -p "$bin"
  # shellcheck disable=SC2016 # $1 expands when the generated stub runs
  printf '#!/bin/sh\ncase "$2" in %%l|%%h) printf "1\\n"; exit ;; esac\ncase "$1" in\n  -f) printf "?\\n" ;;\n  -c) printf "4242\\n" ;;\nesac\n' >"$bin/stat"
  printf '#!/bin/sh\nprintf "999\\n"\n' >"$bin/id"
  # shellcheck disable=SC2016 # variables expand when the generated stub runs
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SHREDDER_TARGET_COMMAND_LOG"\nshift 3\nSHREDDER_VIA_SUDO=1 exec "$@"\n' >"$bin/sudo"
  # shellcheck disable=SC2016 # variables expand when the generated stub runs
  printf '#!/bin/sh\nprintf "%%s:%%s\\n" "${SHREDDER_VIA_SUDO:-direct}" "$PWD/$*" >> "$SHREDDER_SQLITE_CALL_LOG"\nexec "$SHREDDER_REAL_SQLITE" "$@"\n' >"$bin/sqlite3"
  chmod +x "$bin/stat" "$bin/id" "$bin/sudo" "$bin/sqlite3"
  info 'running: user-home mutations must use the owner UID command wrapper'
  PATH="$bin:$PATH" SHREDDER_TARGET_COMMAND_LOG="$calls" \
    SHREDDER_SQLITE_CALL_LOG="$sqlite_calls" SHREDDER_REAL_SQLITE="$real_sqlite" SHREDDER_ROOT="$sb" \
    bash "$SHREDDER" --force --modules shell,usage >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 0)"
  [ "$rc" -eq 0 ] \
    && grep -q -- '-u #4242 --' "$calls" \
    && grep -q -- '-u #4242 -- .*private/var/folders/' "$calls" \
    && ! grep -q '^direct:.*Users/' "$sqlite_calls" \
    && [ ! -s "$sb/Users/alice/.zsh_history" ]
}

phase_i_symlink_refusal() {
  local sb="$WORK/sandbox-i" log="$WORK/phase-i.log" rc=0
  bash "$CREATE_ARTIFACTS" "$sb" >"$WORK/phase-i-create.log"
  info 'running: adversarial symlinks must be refused with the exact failure count'
  SHREDDER_ROOT="$sb" bash "$SHREDDER" --force --modules browser >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 2)"
  [ "$rc" -eq 2 ] \
    && grep -q 'Failed operations: 38' "$log" \
    && grep -q 'must survive symlink escape test' "$sb/escape-target/chromium-profile/History" \
    && grep -q 'must survive linked-home test' "$sb/escape-target/mallory-home/.zsh_history"
}

phase_j_sandbox_boundary() {
  local sb="$WORK/sandbox-j" outside="$WORK/sandbox-j-outside"
  local log="$WORK/phase-j.log" rc=0
  mkdir -p "$sb/Library/Preferences" "$sb/var/log" \
    "$outside/SystemConfiguration/com.apple.wifi.known-networks"
  : > "$sb/.macos-shredder-test-root"
  printf 'airport sentinel\n' > "$outside/SystemConfiguration/com.apple.airport.preferences.plist"
  printf 'tracer sentinel\n' > "$outside/SystemConfiguration/com.apple.wifi.message-tracer.plist"
  printf 'network sentinel\n' > "$outside/SystemConfiguration/com.apple.wifi.known-networks/network.plist"
  ln -s "$outside/SystemConfiguration" "$sb/Library/Preferences/SystemConfiguration"
  info 'running: sandbox system-path symlinks must be refused'
  SHREDDER_ROOT="$sb" bash "$SHREDDER" --force --modules wifi >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 2)"
  [ "$rc" -eq 2 ] \
    && grep -q 'Failed operations: 3' "$log" \
    && grep -q 'airport sentinel' "$outside/SystemConfiguration/com.apple.airport.preferences.plist" \
    && grep -q 'tracer sentinel' "$outside/SystemConfiguration/com.apple.wifi.message-tracer.plist" \
    && grep -q 'network sentinel' "$outside/SystemConfiguration/com.apple.wifi.known-networks/network.plist"
}

phase_k_trusted_path() {
  local bin="$WORK/phase-k-bin" calls="$WORK/phase-k-calls.log"
  local log="$WORK/phase-k.log" rc=0
  mkdir -p "$bin"
  # shellcheck disable=SC2016 # variables expand when the generated stub runs
  printf '#!/bin/sh\nprintf "%%s\\n" "$0" >> "$SHREDDER_PATH_CALL_LOG"\nexec /usr/bin/tr "$@"\n' > "$bin/tr"
  chmod +x "$bin/tr"
  info 'running: real mode must ignore caller-provided PATH commands'
  PATH="$bin:$PATH" SHREDDER_PATH_CALL_LOG="$calls" \
    /bin/bash "$SHREDDER" --modules bogus_definitely_invalid >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 64)"
  [ "$rc" -eq 64 ] && [ ! -e "$calls" ]
}

phase_l_sqlite_discovery() {
  local sb="$WORK/sandbox-l" bin="$WORK/phase-l-bin" log="$WORK/phase-l.log" rc=0
  bash "$CREATE_ARTIFACTS" "$sb" >"$WORK/phase-l-create.log"
  mkdir -p "$bin"
  # Fail table discovery but accept every later SQL statement. Before the fix,
  # the script hid this error and reported a successful cleanup.
  printf '#!/bin/sh\ncase "$*" in *"SELECT name FROM sqlite_master"*) exit 1 ;; *) exit 0 ;; esac\n' >"$bin/sqlite3"
  chmod +x "$bin/sqlite3"
  info 'running: KnowledgeC table discovery errors must fail closed'
  PATH="$bin:$PATH" SHREDDER_ROOT="$sb" \
    bash "$SHREDDER" --force --modules usage >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 2)"
  [ "$rc" -eq 2 ] && grep -q 'Failed operations: 3' "$log"
}

phase_m_spotlight_result() {
  local log="$WORK/phase-m.log" rc=0
  if [ "$(uname -s)" != 'Darwin' ]; then
    info 'Spotlight result check skipped on non-Darwin host'
    return 0
  fi
  info 'running: native Spotlight dry-run must count its requested operation'
  /bin/bash "$SHREDDER" --dry-run --force --modules spotlight >"$log" 2>&1 || rc=$?
  info "exit code: $rc (expected 0)"
  [ "$rc" -eq 0 ] && grep -q 'Total items that would be cleaned: 1' "$log"
}

phase_n_cache_parent_race() {
  local sb="$WORK/sandbox-n" bin="$WORK/phase-n-bin" log="$WORK/phase-n.log" rc=0
  local cache="$sb/private/var/folders/xx/yy/C/com.apple.QuickLook.thumbnailcache"
  local outside="$WORK/phase-n-outside" real_stat
  real_stat="$(command -v stat)"
  mkdir -p "$cache" "$outside" "$bin"
  sb="$(cd "$sb" && pwd -P)"
  cache="$sb/private/var/folders/xx/yy/C/com.apple.QuickLook.thumbnailcache"
  : > "$sb/.macos-shredder-test-root"
  printf 'cache entry\n' > "$cache/sentinel"
  printf 'preserve outside file\n' > "$outside/sentinel"
  # Replace the parent after the path guard, during the owner lookup. The
  # actual removal must refuse the new parent, even for the same owner UID.
  cat > "$bin/stat" <<'STUB'
#!/bin/sh
if [ "$3" = "$SHREDDER_CACHE_OWNER" ] && [ ! -e "$SHREDDER_RACE_DONE" ]; then
  /bin/mv "$SHREDDER_CACHE_DIR" "$SHREDDER_CACHE_DIR.original" || exit 1
  /bin/ln -s "$SHREDDER_OUTSIDE" "$SHREDDER_CACHE_DIR" || exit 1
  : > "$SHREDDER_RACE_DONE"
fi
exec "$SHREDDER_REAL_STAT" "$@"
STUB
  chmod +x "$bin/stat"
  PATH="$bin:$PATH" SHREDDER_ROOT="$sb" SHREDDER_REAL_STAT="$real_stat" \
    SHREDDER_CACHE_OWNER="$sb/private/var/folders/xx/yy" \
    SHREDDER_CACHE_DIR="$cache" SHREDDER_OUTSIDE="$outside" \
    SHREDDER_RACE_DONE="$WORK/phase-n-race-done" \
    bash "$SHREDDER" --force --modules quicklook >"$log" 2>&1 || rc=$?
  info "cache parent race exit: $rc (expected 2)"
  [ "$rc" -eq 2 ] \
    && [ -f "$WORK/phase-n-race-done" ] \
    && grep -q '^preserve outside file$' "$outside/sentinel" \
    && grep -q '^cache entry$' "$cache.original/sentinel" \
    && grep -q 'Failed operations: 1' "$log"
}

phase_o_firefox_failures() {
  local sb="$WORK/sandbox-o" bin="$WORK/phase-o-bin" log="$WORK/phase-o.log"
  local db original="$WORK/phase-o-original.db" scenario cmd rc ok=1
  local before="$WORK/phase-o-before.sql" after="$WORK/phase-o-after.sql"
  bash "$CREATE_ARTIFACTS" "$sb" >"$WORK/phase-o-create.log" || return 1
  rm -f -- "$sb/Users/alice/Library/Application Support/Chromium/Default"
  db="$sb/Users/alice/Library/Application Support/Firefox/Profiles/abcd1234.work/places.sqlite"
  cp "$db" "$original" || return 1
  for scenario in schema transaction; do
    cp "$original" "$db" || return 1
    if [ "$scenario" = schema ]; then
      sqlite3 "$db" 'DROP TABLE moz_inputhistory;' || return 1
    else
      # This error occurs after visit deletion. The transaction must roll back.
      sqlite3 "$db" "CREATE TRIGGER deny_delete BEFORE DELETE ON moz_places
        BEGIN SELECT RAISE(ABORT, 'test transaction failure'); END;" || return 1
    fi
    sqlite3 "$db" .dump > "$before" || return 1
    rc=0
    SHREDDER_ROOT="$sb" bash "$SHREDDER" --force --modules browser >"$log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || ok=0
    sqlite3 "$db" .dump > "$after" || return 1
    cmp -s "$before" "$after" || ok=0
    info "Firefox $scenario failure exit: $rc (expected 2); database must be unchanged"
  done
  # Use real tools on a PATH without sqlite3. There must be no delete fallback.
  cp "$original" "$db" || return 1
  mkdir -p "$bin"
  for cmd in tr find stat id; do
    ln -s "$(command -v "$cmd")" "$bin/$cmd" || return 1
  done
  rc=0
  PATH="$bin" SHREDDER_ROOT="$sb" \
    /bin/bash "$SHREDDER" --force --modules browser >"$log" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || ok=0
  cmp -s "$original" "$db" || ok=0
  grep -q 'sqlite3 unavailable; preserving Firefox Places database' "$log" || ok=0
  info "Firefox without SQLite exit: $rc (expected 2); database must be unchanged"
  [ "$ok" -eq 1 ]
}

preserve_failure_artifacts() {
  local dest="$REPO_ROOT/tests-last-run"
  mkdir -p "$dest"
  cp -R "$WORK/." "$dest/" 2>/dev/null || true
  info "failing-run logs, manifests and sandboxes copied to: $dest"
}

info '=== PHASE A: usage validation ==='
if phase_a_usage_validation; then RES_A='PASS'; fi
info "PHASE A result: $RES_A"

info '=== PHASE B: module listing ==='
if phase_b_list_modules; then RES_B='PASS'; fi
info "PHASE B result: $RES_B"

info '=== PHASE C: forced clean ==='
if phase_c_force_clean; then RES_C='PASS'; fi
info "PHASE C result: $RES_C"

info '=== PHASE D: dry-run safety ==='
if phase_d_dryrun_safety; then RES_D='PASS'; fi
info "PHASE D result: $RES_D"

info '=== PHASE E: sandbox guard ==='
if phase_e_sandbox_guard; then RES_E='PASS'; fi
info "PHASE E result: $RES_E"

info '=== PHASE F: confirmation guard ==='
if phase_f_confirmation_guard; then RES_F='PASS'; fi
info "PHASE F result: $RES_F"

info '=== PHASE G: host-command isolation ==='
if phase_g_host_command_isolation; then RES_G='PASS'; fi
info "PHASE G result: $RES_G"

info '=== PHASE H: least-privilege user commands ==='
if phase_h_user_owner_commands; then RES_H='PASS'; fi
info "PHASE H result: $RES_H"

info '=== PHASE I: symlink refusal ==='
if phase_i_symlink_refusal; then RES_I='PASS'; fi
info "PHASE I result: $RES_I"

info '=== PHASE J: sandbox boundary ==='
if phase_j_sandbox_boundary; then RES_J='PASS'; fi
info "PHASE J result: $RES_J"

info '=== PHASE K: trusted PATH ==='
if phase_k_trusted_path; then RES_K='PASS'; fi
info "PHASE K result: $RES_K"

info '=== PHASE L: SQLite discovery ==='
if phase_l_sqlite_discovery; then RES_L='PASS'; fi
info "PHASE L result: $RES_L"

info '=== PHASE M: Spotlight result ==='
if phase_m_spotlight_result; then RES_M='PASS'; fi
info "PHASE M result: $RES_M"

info '=== PHASE N: cache parent race ==='
if phase_n_cache_parent_race; then RES_N='PASS'; fi
info "PHASE N result: $RES_N"

info '=== PHASE O: Firefox failure safety ==='
if phase_o_firefox_failures; then RES_O='PASS'; fi
info "PHASE O result: $RES_O"

info '================ SUMMARY ================'
info "A usage-validation : $RES_A"
info "B module-listing   : $RES_B"
info "C force-clean      : $RES_C"
info "D dry-run-safety   : $RES_D"
info "E sandbox-guard   : $RES_E"
info "F confirmation    : $RES_F"
info "G host-isolation  : $RES_G"
info "H least-privilege : $RES_H"
info "I symlink-refusal : $RES_I"
info "J sandbox-boundary: $RES_J"
info "K trusted-path    : $RES_K"
info "L sqlite-discovery: $RES_L"
info "M spotlight-result: $RES_M"
info "N cache-parent-race: $RES_N"
info "O firefox-failures: $RES_O"

overall=0
for r in "$RES_A" "$RES_B" "$RES_C" "$RES_D" "$RES_E" "$RES_F" "$RES_G" "$RES_H" "$RES_I" "$RES_J" "$RES_K" "$RES_L" "$RES_M" "$RES_N" "$RES_O"; do
  [ "$r" = 'PASS' ] || overall=1
done
if [ "$overall" -ne 0 ]; then
  preserve_failure_artifacts
  exit 1
fi
bash "$SCRIPT_DIR/regressions.sh"
bash "$SCRIPT_DIR/ai-sessions.sh"
bash "$SCRIPT_DIR/ai-editors.sh"
bash "$SCRIPT_DIR/browser-stores.sh"
bash "$SCRIPT_DIR/shell-stores.sh"
bash "$SCRIPT_DIR/editor-history.sh"
bash "$SCRIPT_DIR/volume-trash.sh"
bash "$SCRIPT_DIR/clipboard.sh"
bash "$SCRIPT_DIR/terminal-usage.sh"
bash "$SCRIPT_DIR/ai-extended.sh"
bash "$SCRIPT_DIR/headless.sh"
bash "$SCRIPT_DIR/slack-export.sh"
bash "$SCRIPT_DIR/terminal-output.sh"
bash "$SCRIPT_DIR/finder-history.sh"
bash "$SCRIPT_DIR/system-traces.sh"
bash "$SCRIPT_DIR/file-metadata.sh"
bash "$SCRIPT_DIR/document-versions.sh"
bash "$SCRIPT_DIR/activity-stores.sh"
bash "$SCRIPT_DIR/manual-privacy.sh"
info 'all phases and regressions passed'
