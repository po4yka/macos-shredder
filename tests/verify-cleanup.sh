#!/usr/bin/env bash
#
# tests/verify-cleanup.sh — assert the post-cleaning (or untouched dry-run)
# state of a SHREDDER_ROOT sandbox built by tests/create-artifacts.sh.
#
# Usage: verify-cleanup.sh <SANDBOX_ROOT> [--phase force|dryrun] [--manifest <FILE>]
#
#   phase force  (default) — assert the cleaned-up end state:
#     histories emptied/gone for BOTH users, trash incl. hidden leak emptied,
#     Safari sidecars gone, quarantine/KnowledgeC marker rows absent,
#     wifi plists gone, brew caches and app traces gone, DiagnosticReports
#     gone, audit rotations gone while var/audit/current survives,
#     Volumes/BACKUP/.DS_Store survives.
#
#   phase dryrun — assert NOTHING changed: recompute the sha256 manifest
#     captured before the run and require byte-identical stability plus an
#     identical file set (no additions, no removals).
#
# Env: MANIFEST_FILE is honoured as the default for --manifest.
# Exit: 0 when every check passes, 1 when at least one check fails.

set -euo pipefail
export LC_ALL=C

PHASE='force'
SANDBOX_ROOT=''
MANIFEST_FILE="${MANIFEST_FILE:-}"

PASS_COUNT=0
FAIL_COUNT=0

die() { printf 'verify-cleanup: %s\n' "$1" >&2; exit "${2:-64}"; }

usage() {
  cat <<'EOF'
Usage: verify-cleanup.sh <SANDBOX_ROOT> [--phase force|dryrun] [--manifest <FILE>]

  --phase force    assert the post-cleaning end state (default)
  --phase dryrun   assert byte-identical stability against a manifest
  --manifest FILE  sha256 manifest written by create-artifacts.sh
                   (env MANIFEST_FILE is honoured as default)

Prints "[PASS] desc" or "[FAIL] desc expected=X got=Y" per check and finishes
with "PASSED_CHECKS=N" / "FAILED_CHECKS=M". Exits 1 if any check failed.
EOF
}

if command -v shasum >/dev/null 2>&1; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
else
  sha256_file() { die 'need shasum or sha256sum on PATH' 1; }
fi

file_size() { # file_size <path> -> byte count ('' when unstatable)
  local s
  s=$(stat -c%s "$1" 2>/dev/null) || s=$(stat -f%z "$1" 2>/dev/null) || s=''
  printf '%s\n' "$s"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s expected=%s got=%s\n' "$1" "$2" "$3"
}

exists() { [ -e "$1" ] || [ -L "$1" ]; }

check_gone() { # check_gone <desc> <path>
  if exists "$2"; then
    fail "$1" 'absent' "still present: $2"
  else
    pass "$1"
  fi
}

check_gone_or_empty() { # check_gone_or_empty <desc> <path>
  local desc="$1" path="$2" sz
  if ! exists "$path"; then
    pass "$desc"
    return
  fi
  if [ -f "$path" ]; then
    sz=$(file_size "$path")
    sz="${sz:-1}"
    if [ "$((sz))" -eq 0 ]; then
      pass "$desc"
      return
    fi
  fi
  fail "$desc" 'missing or empty file' "non-empty: $path"
}

check_dir_no_files() { # check_dir_no_files <desc> <dir>
  local desc="$1" dir="$2" count
  if ! exists "$dir"; then
    pass "$desc"
    return
  fi
  if [ ! -d "$dir" ]; then
    fail "$desc" 'absent directory' "non-directory present: $dir"
    return
  fi
  count=$(find "$dir" -type f -print | wc -l)
  count=$((count))
  if [ "$count" -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc" '0 remaining files' "$count remaining under $dir"
  fi
}

check_marker_absent() { # check_marker_absent <desc> <file> <marker>
  local desc="$1" path="$2" marker="$3"
  if ! exists "$path"; then
    pass "$desc"
    return
  fi
  if [ -f "$path" ] && ! grep -q -- "$marker" "$path"; then
    pass "$desc"
  else
    fail "$desc" "no '$marker'" "marker present in $path"
  fi
}

check_exists_file() { # check_exists_file <desc> <path>
  if [ -f "$2" ]; then
    pass "$1"
  else
    fail "$1" 'existing regular file' "missing: $2"
  fi
}

check_history_survives() { # check_history_survives <desc> <path>
  local desc="$1" path="$2" sz
  if [ -f "$path" ]; then
    sz=$(file_size "$path")
    sz="${sz:-0}"
    if [ "$((sz))" -gt 0 ]; then
      pass "$desc"
      return
    fi
  fi
  fail "$desc" 'non-empty preserved file' "missing or empty: $path"
}

check_quarantine_db() { # check_quarantine_db <desc> <db-path>
  local desc="$1" db="$2" n
  if ! exists "$db"; then
    pass "$desc"
    return
  fi
  if command -v sqlite3 >/dev/null 2>&1; then
    n=$(sqlite3 "$db" "SELECT COUNT(*) FROM LSQuarantineEvent WHERE LSQuarantineAgentName LIKE '%SHREDTEST%' OR LSQuarantineDataURLString LIKE '%SHREDTEST%';" 2>/dev/null) || n=0
    n="${n:-0}"
    if [ "$n" -eq 0 ] 2>/dev/null; then
      pass "$desc"
    else
      fail "$desc" '0 marker rows' "$n marker rows remain in $db"
    fi
  else
    # Degraded mode: text stand-ins carry the marker as plain text.
    if [ -f "$db" ] && ! grep -q 'SHREDTEST' "$db" 2>/dev/null; then
      pass "$desc"
    else
      fail "$desc" 'no marker' "marker possibly present in $db (install sqlite3 for exact check)"
    fi
  fi
}

check_knowledge_db() { # check_knowledge_db <desc> <db-path>
  local desc="$1" db="$2" n1 n2
  if ! exists "$db"; then
    pass "$desc"
    return
  fi
  if command -v sqlite3 >/dev/null 2>&1; then
    n1=$(sqlite3 "$db" "SELECT COUNT(*) FROM ZOBJECT WHERE ZVALUESTRING LIKE '%SHREDTEST%';" 2>/dev/null) || n1=0
    n2=$(sqlite3 "$db" "SELECT COUNT(*) FROM ZSTRUCTUREDMETADATA WHERE ZVALUE LIKE '%SHREDTEST%';" 2>/dev/null) || n2=0
    n1="${n1:-0}"
    n2="${n2:-0}"
    if [ "$n1" -eq 0 ] 2>/dev/null && [ "$n2" -eq 0 ] 2>/dev/null; then
      pass "$desc"
    else
      fail "$desc" '0 marker rows' "ZOBJECT=$n1 ZSTRUCTUREDMETADATA=$n2 in $db"
    fi
  else
    if [ -f "$db" ] && ! grep -q 'SHREDTEST' "$db" 2>/dev/null; then
      pass "$desc"
    else
      fail "$desc" 'no marker' "marker possibly present in $db (install sqlite3 for exact check)"
    fi
  fi
}

check_user_artifacts_cleaned() { # check_user_artifacts_cleaned <label> <home>
  local label="$1" home="$2"

  # shell histories — empty or gone; proves space-safe enumeration
  check_gone_or_empty "$label: .zsh_history emptied/gone" "$home/.zsh_history"
  check_gone_or_empty "$label: .bash_history emptied/gone" "$home/.bash_history"
  check_dir_no_files "$label: .bash_sessions emptied" "$home/.bash_sessions"
  check_gone_or_empty "$label: ipython history emptied/gone" "$home/.ipython/profile_default/history.sqlite"

  # trash, including the hidden leak
  check_gone "$label: trash file.txt gone" "$home/.Trash/file.txt"
  check_gone "$label: trash hidden leak (.hidden-leak) gone" "$home/.Trash/.hidden-leak"

  # browser sidecars
  check_gone "$label: Safari History.db-wal sidecar gone" "$home/Library/Safari/History.db-wal"
  check_gone "$label: Safari History.db-shm sidecar gone" "$home/Library/Safari/History.db-shm"

  # launch services quarantine markers
  check_quarantine_db "$label: quarantine marker rows gone" \
    "$home/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"

  # diagnostic reports
  check_gone "$label: DiagnosticReports crash report gone" "$home/Library/Logs/DiagnosticReports/crash-user.ips"

  # homebrew
  check_gone "$label: brew cache gone" "$home/Library/Caches/Homebrew/brew-cache.tar.gz"
  check_gone "$label: brew log gone" "$home/Library/Logs/Homebrew/brew.log"

  # application traces
  check_gone "$label: VS Code cache gone" "$home/Library/Application Support/Code/Cache/x"
  check_gone "$label: VS Code logs gone" "$home/Library/Application Support/Code/logs/y"
  check_gone "$label: JetBrains idea.log gone" "$home/Library/Logs/JetBrains/IntelliJIdea2024.1/idea.log"
  check_gone "$label: Terminal saved state gone" "$home/Library/Saved Application State/com.apple.Terminal.savedState/windows.plist"
  check_gone "$label: iTerm2 saved state gone" "$home/Library/Saved Application State/com.googlecode.iterm2.savedState/data"
}

check_audit() { # check_audit <root>
  local root="$1" leftovers
  leftovers=0
  if [ -d "$root/var/audit" ]; then
    leftovers=$(find "$root/var/audit" -type f -name '2*' -print | wc -l)
    leftovers=$((leftovers))
  fi
  if [ "$leftovers" -eq 0 ]; then
    pass 'audit: timestamped rotation files gone'
  else
    fail 'audit: timestamped rotation files gone' '0 remaining' "$leftovers remaining in var/audit"
  fi
  check_exists_file 'audit: var/audit/current preserved' "$root/var/audit/current"
}

run_force_checks() { # run_force_checks <root>
  local root="$1" u sub sp

  for u in 'alice' 'User Space'; do
    check_user_artifacts_cleaned "user[$u]" "$root/Users/$u"
  done

  # homes that enumerators must skip stay untouched
  for sp in 'Shared' 'Guest' '.hiddenuser'; do
    check_history_survives "skipped home untouched: Users/$sp" "$root/Users/$sp/.zsh_history"
  done

  # system logs
  check_marker_absent 'system.log: legacy NYXTEST marker scrubbed' "$root/var/log/system.log" 'NYXTEST'
  check_marker_absent 'system.log: own SHRED-TEST marker removed' "$root/var/log/system.log" 'SHRED-TEST'
  check_marker_absent 'wifi.log: marker removed' "$root/var/log/wifi.log" 'SHRED-TEST'
  check_gone 'DiagnosticReports: system crash report gone' "$root/Library/Logs/DiagnosticReports/crash-1.ips"

  # audit store
  check_audit "$root"

  # unified logging store
  check_dir_no_files 'unified diagnostics emptied' "$root/var/db/diagnostics"

  # wifi system preferences
  check_gone 'wifi: airport preferences plist gone' \
    "$root/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist"
  check_gone 'wifi: message tracer plist gone' \
    "$root/Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist"
  check_dir_no_files 'wifi: known-networks emptied' \
    "$root/Library/Preferences/SystemConfiguration/com.apple.wifi.known-networks"

  # var folders
  check_gone_or_empty 'notificationcenter db2 contents gone' \
    "$root/private/var/folders/xx/yy/C/com.apple.notificationcenter/db2/db.db"
  check_gone_or_empty 'quicklook thumbnailcache emptied' \
    "$root/private/var/folders/xx/yy/C/com.apple.QuickLook.thumbnailcache/thumb.jpg"

  # knowledge store (usage module)
  check_knowledge_db 'KnowledgeC markers absent' \
    "$root/private/var/db/CoreDuet/Knowledge/knowledgeC.db"

  # .DS_Store sweep across both trees + external volume pruning
  for u in 'alice' 'User Space'; do
    for sub in Desktop Documents Downloads; do
      check_gone ".DS_Store swept: Users/$u/$sub" "$root/Users/$u/$sub/.DS_Store"
      check_gone ".DS_Store swept: System/Volumes/Data/Users/$u/$sub" \
        "$root/System/Volumes/Data/Users/$u/$sub/.DS_Store"
    done
  done
  check_exists_file 'volume prune: Volumes/BACKUP/.DS_Store survives' "$root/Volumes/BACKUP/.DS_Store"
}

run_dryrun_checks() { # run_dryrun_checks <root> <manifest>
  local root="$1" manifest="$2"
  local kind rel abs actual mismatches=0 entries=0
  local expected_set current_set

  if [ -z "$manifest" ]; then
    die 'dryrun phase requires --manifest (or exported MANIFEST_FILE)' 1
  fi
  if [ ! -f "$manifest" ]; then
    die "manifest not found: $manifest" 1
  fi

  while IFS=$'\t' read -r kind rel; do
    [ -n "${kind:-}" ] || continue
    entries=$((entries + 1))
    abs="$root/$rel"
    if [ "$kind" = 'dir' ]; then
      if [ -d "$abs" ]; then
        continue
      fi
      fail 'dryrun: directory preserved' "$rel" 'directory missing'
      mismatches=$((mismatches + 1))
    else
      if [ -f "$abs" ]; then
        actual=$(sha256_file "$abs")
      else
        actual='<missing>'
      fi
      if [ "$actual" = "$kind" ]; then
        continue
      fi
      fail 'dryrun: file byte-identical' "$rel sha256=$kind" "sha256=$actual"
      mismatches=$((mismatches + 1))
    fi
  done < "$manifest"

  if [ "$mismatches" -eq 0 ]; then
    pass "dryrun: all $entries manifest entries unchanged (byte-identical)"
  fi

  expected_set=$(awk -F'\t' '$1 != "dir" { print "./" $2 }' "$manifest" | LC_ALL=C sort)
  current_set=$(cd "$root" && find . -type f -print | LC_ALL=C sort)
  if [ "$current_set" = "$expected_set" ]; then
    pass 'dryrun: no files added or removed'
  else
    fail 'dryrun: no files added or removed' 'identical file set' 'file set differs:'
    diff <(printf '%s\n' "$expected_set") <(printf '%s\n' "$current_set") | sed 's/^/[FAIL]   /' || true
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)
      [ $# -ge 2 ] || die '--phase requires a value'
      PHASE="$2"
      shift 2
      ;;
    --phase=*)
      PHASE="${1#*=}"
      shift
      ;;
    --manifest)
      [ $# -ge 2 ] || die '--manifest requires a value'
      MANIFEST_FILE="$2"
      shift 2
      ;;
    --manifest=*)
      MANIFEST_FILE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ -z "$SANDBOX_ROOT" ]; then
        SANDBOX_ROOT="$1"
      else
        die "unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$SANDBOX_ROOT" ]; then
  usage >&2
  die 'sandbox root argument is required'
fi
[ -d "$SANDBOX_ROOT" ] || die "sandbox root is not a directory: $SANDBOX_ROOT" 1

case "$PHASE" in
  force)
    run_force_checks "$SANDBOX_ROOT"
    ;;
  dryrun)
    run_dryrun_checks "$SANDBOX_ROOT" "$MANIFEST_FILE"
    ;;
  *)
    die "unknown phase: $PHASE (use force|dryrun)"
    ;;
esac

printf 'PASSED_CHECKS=%d\n' "$PASS_COUNT"
printf 'FAILED_CHECKS=%d\n' "$FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi
