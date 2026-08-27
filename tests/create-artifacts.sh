#!/usr/bin/env bash
#
# tests/create-artifacts.sh — deterministic SHREDDER_ROOT fixture builder for
# the macos-shredder integration suite.
#
# Usage: create-artifacts.sh <SANDBOX_ROOT> [--manifest <FILE>]
#
# Builds the full sandbox layout described in tests/README.md. Idempotent:
# safe to re-run over an existing sandbox. SQLite-backed fixtures are only
# produced when sqlite3 is available; otherwise plain-text stand-ins carrying
# the same markers are written.

set -euo pipefail
export LC_ALL=C

readonly MARK_LEGACY='NYXTEST'      # legacy branding that must be scrubbed
readonly MARK_OWN='SHRED-TEST'      # current branding used across fixtures
readonly MARK_HIST='SHREDTEST-HIST' # per-user history/trash fixtures
readonly MARK_QT='SHREDTEST-QT'     # quarantine database marker
readonly MARK_KC='SHREDTEST-KC'     # knowledge store marker

readonly ZSH_HISTORY='# shred-test shell history
ls -la /Users
echo SHREDTEST-HIST zsh-entry
curl -s https://downloads.example.invalid/payload-SHREDTEST-HIST'

readonly BASH_HISTORY='# shred-test bash history
brew update
echo SHREDTEST-HIST bash-entry'

SANDBOX_ROOT=''
MANIFEST_FILE=''

die() { printf 'create-artifacts: %s\n' "$1" >&2; exit "${2:-64}"; }

usage() {
  cat <<'EOF'
Usage: create-artifacts.sh <SANDBOX_ROOT> [--manifest <FILE>]

Builds the deterministic sandbox fixture tree under <SANDBOX_ROOT>.

  --manifest <FILE>  write a stability manifest for every directory, regular
                     file, and symbolic link (consumed by verify-cleanup.sh
                     --phase dryrun)
EOF
}

if command -v shasum >/dev/null 2>&1; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
else
  sha256_file() { die 'need shasum or sha256sum on PATH' 1; }
fi

put() { # put <path> <single-line-content>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

HAVE_SQLITE3=0
if command -v sqlite3 >/dev/null 2>&1; then
  HAVE_SQLITE3=1
fi

reset_db_sidecars() { # reset_db_sidecars <db-path>
  rm -f "$1" "$1-wal" "$1-shm" "$1-journal"
}

make_quarantine_db() { # make_quarantine_db <db-path>
  local db="$1"
  reset_db_sidecars "$db"
  mkdir -p "$(dirname "$db")"
  if [ "$HAVE_SQLITE3" -eq 1 ]; then
    sqlite3 "$db" <<'SQL'
CREATE TABLE LSQuarantineEvent (LSQuarantineTimeStamp REAL, LSQuarantineAgentName TEXT, LSQuarantineDataURLString TEXT, LSQuarantineSenderName TEXT);
INSERT INTO LSQuarantineEvent VALUES (700000000.0, 'ShredTestInstaller', 'https://downloads.example.invalid/SHREDTEST-QT-marker.dmg', 'ShredTester');
SQL
  else
    printf 'quarantine-db placeholder\n%s downloaded-file row\n' "$MARK_QT" > "$db"
  fi
}

make_knowledge_db() { # make_knowledge_db <db-path>
  local db="$1"
  reset_db_sidecars "$db"
  mkdir -p "$(dirname "$db")"
  if [ "$HAVE_SQLITE3" -eq 1 ]; then
    sqlite3 "$db" <<'SQL'
CREATE TABLE ZOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZVALUESTRING TEXT);
INSERT INTO ZOBJECT VALUES (1, 1, 'SHREDTEST-KC-zobject-row');
CREATE TABLE ZSTRUCTUREDMETADATA (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZVALUE TEXT);
INSERT INTO ZSTRUCTUREDMETADATA VALUES (1, 1, 'SHREDTEST-KC-metadata-row');
SQL
  else
    printf 'knowledgeC placeholder\n%s\n' "$MARK_KC" > "$db"
  fi
}

build_user_home() { # build_user_home <home-dir>
  local home="$1"

  # --- shell histories -------------------------------------------------------
  mkdir -p "$home/.bash_sessions" "$home/.ipython/profile_default"
  printf '%s\n' "$ZSH_HISTORY" > "$home/.zsh_history"
  printf '%s\n' "$BASH_HISTORY" > "$home/.bash_history"
  printf 'session 1 %s\n' "$MARK_HIST" > "$home/.bash_sessions/session_001.history"
  printf 'session 2 %s\n' "$MARK_HIST" > "$home/.bash_sessions/session_002.history"
  printf 'ipython history placeholder %s\n' "$MARK_HIST" > "$home/.ipython/profile_default/history.sqlite"
  printf 'ipython wal %s\n' "$MARK_HIST" > "$home/.ipython/profile_default/history.sqlite-wal"
  printf 'ipython shm %s\n' "$MARK_HIST" > "$home/.ipython/profile_default/history.sqlite-shm"
  printf 'ipython journal %s\n' "$MARK_HIST" > "$home/.ipython/profile_default/history.sqlite-journal"

  # --- browser (Safari) ------------------------------------------------------
  local safari="$home/Library/Safari"
  mkdir -p "$safari" "$home/Library/Caches/com.apple.Safari" \
    "$home/Library/Containers/com.apple.Safari/Data/Library/Cookies" \
    "$home/Library/Cookies"
  printf 'safari history placeholder %s\n' "$MARK_HIST" > "$safari/History.db"
  printf 'wal sidecar %s\n' "$MARK_HIST" > "$safari/History.db-wal"
  printf 'shm sidecar %s\n' "$MARK_HIST" > "$safari/History.db-shm"
  printf '<plist><string>downloads %s</string></plist>\n' "$MARK_HIST" > "$safari/Downloads.plist"
  printf '<plist><string>topsites %s</string></plist>\n' "$MARK_HIST" > "$safari/TopSites.plist"
  printf '<plist><string>lastsession %s</string></plist>\n' "$MARK_HIST" > "$safari/LastSession.plist"
  printf 'safari cache blob %s\n' "$MARK_OWN" > "$home/Library/Caches/com.apple.Safari/cache-file"
  printf 'container cookies %s\n' "$MARK_HIST" > "$home/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
  printf 'legacy cookies %s\n' "$MARK_HIST" > "$home/Library/Cookies/Cookies.binarycookies"

  # Chromium-family profiles: Default plus a named profile. The second
  # profile catches implementations that only clean Default.
  local chrome="$home/Library/Application Support/Google/Chrome"
  local profile
  for profile in Default 'Profile 1'; do
    mkdir -p "$chrome/$profile/Cache"
    printf 'chrome history %s\n' "$MARK_HIST" > "$chrome/$profile/History"
    printf 'chrome cache %s\n' "$MARK_OWN" > "$chrome/$profile/Cache/cache.data"
  done

  # Firefox profiles can have arbitrary names; they are not required to
  # contain "default".
  local firefox="$home/Library/Application Support/Firefox/Profiles/abcd1234.work"
  mkdir -p "$firefox/cache2"
  printf 'firefox history %s\n' "$MARK_HIST" > "$firefox/places.sqlite"
  printf 'firefox cache %s\n' "$MARK_OWN" > "$firefox/cache2/cache.data"

  # --- launch services quarantine ---------------------------------------------
  make_quarantine_db "$home/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"

  # Current macOS stores KnowledgeC per user. Keep a fixture at the legacy
  # system path too; both must be handled when present.
  make_knowledge_db "$home/Library/Application Support/Knowledge/knowledgeC.db"

  # Shared File List recent-item stores replaced the old recentitems plist.
  local shared_lists="$home/Library/Application Support/com.apple.sharedfilelist"
  mkdir -p "$shared_lists"
  printf 'recent apps %s\n' "$MARK_OWN" > "$shared_lists/com.apple.LSSharedFileList.RecentApplications.sfl3"
  printf 'recent docs %s\n' "$MARK_OWN" > "$shared_lists/com.apple.LSSharedFileList.RecentDocuments.sfl3"
  printf 'favorite must survive\n' > "$shared_lists/com.apple.LSSharedFileList.FavoriteItems.sfl3"

  # --- trash (incl. hidden leak) ----------------------------------------------
  mkdir -p "$home/.Trash"
  printf 'trashed document\n' > "$home/.Trash/file.txt"
  printf 'hidden leak %s\n' "$MARK_HIST" > "$home/.Trash/.hidden-leak"

  # --- per-user diagnostic reports --------------------------------------------
  mkdir -p "$home/Library/Logs/DiagnosticReports"
  printf '{"ips":1,"marker":"%s","user":true}\n' "$MARK_OWN" > "$home/Library/Logs/DiagnosticReports/crash-user.ips"

  # --- homebrew ----------------------------------------------------------------
  mkdir -p "$home/Library/Caches/Homebrew" "$home/Library/Logs/Homebrew"
  printf 'fake tarball payload %s\n' "$MARK_OWN" > "$home/Library/Caches/Homebrew/brew-cache.tar.gz"
  printf 'brew build log %s\n' "$MARK_OWN" > "$home/Library/Logs/Homebrew/brew.log"

  # --- application traces ------------------------------------------------------
  local saved="$home/Library/Saved Application State"
  mkdir -p "$home/Library/Application Support/Code/Cache" \
           "$home/Library/Application Support/Code/logs" \
           "$home/Library/Logs/JetBrains/IntelliJIdea2024.1" \
           "$saved/com.apple.Terminal.savedState" \
           "$saved/com.googlecode.iterm2.savedState"
  printf 'vscode cache entry %s\n' "$MARK_OWN" > "$home/Library/Application Support/Code/Cache/x"
  printf 'vscode log entry %s\n' "$MARK_OWN" > "$home/Library/Application Support/Code/logs/y"
  printf 'idea log entry %s\n' "$MARK_OWN" > "$home/Library/Logs/JetBrains/IntelliJIdea2024.1/idea.log"
  printf '<plist><string>terminal windows %s</string></plist>\n' "$MARK_OWN" > "$saved/com.apple.Terminal.savedState/windows.plist"
  printf 'iterm2 restored state %s\n' "$MARK_OWN" > "$saved/com.googlecode.iterm2.savedState/data"
}

write_manifest() { # write_manifest <file>
  local out="$1" tmp="${1}.tmp.$$" rel
  printf '[artifacts] writing manifest: %s\n' "$out"
  : > "$tmp"
  {
    (cd "$SANDBOX_ROOT" && find . -type d -print | LC_ALL=C sort) | while IFS= read -r rel; do
      rel="${rel#./}"
      [ -n "$rel" ] || continue
      printf 'dir\t%s\n' "$rel"
    done
    (cd "$SANDBOX_ROOT" && find . -type f -print | LC_ALL=C sort) | while IFS= read -r rel; do
      rel="${rel#./}"
      [ -n "$rel" ] || continue
      printf '%s\t%s\n' "$(sha256_file "$SANDBOX_ROOT/$rel")" "$rel"
    done
    (cd "$SANDBOX_ROOT" && find . -type l -print | LC_ALL=C sort) | while IFS= read -r rel; do
      rel="${rel#./}"
      [ -n "$rel" ] || continue
      printf 'link:%s\t%s\n' "$(readlink "$SANDBOX_ROOT/$rel")" "$rel"
    done
  } > "$tmp"
  mv "$tmp" "$out"
}

main() {
  local root="$SANDBOX_ROOT" uname home dv sub special tier

  mkdir -p "$root"
  root="$(cd "$root" && pwd)"
  SANDBOX_ROOT="$root"
  : > "$root/.macos-shredder-test-root"

  if [ "$HAVE_SQLITE3" -eq 1 ]; then
    printf '[artifacts] sqlite3 detected: real database fixtures will be used\n'
  else
    printf '[artifacts] sqlite3 NOT found: plain-text database stand-ins will be used\n'
  fi

  printf '[artifacts] building user homes (alice, User Space)\n'
  for uname in 'alice' 'User Space'; do
    home="$root/Users/$uname"
    mkdir -p "$home"
    build_user_home "$home"
    dv="$root/System/Volumes/Data/Users/$uname"
    for sub in Desktop Documents Downloads; do
      mkdir -p "$dv/$sub" "$home/$sub"
      printf '.DS_Store blob %s (%s/%s)\n' "$MARK_OWN" "$uname" "$sub" > "$dv/$sub/.DS_Store"
      printf '.DS_Store blob %s (%s/%s home view)\n' "$MARK_OWN" "$uname" "$sub" > "$home/$sub/.DS_Store"
    done
  done

  # A user-controlled intermediate symlink must never let the root cleaner
  # escape the user's home. Chromium is intentionally absent from the normal
  # fixtures so the test cannot depend on whether Chrome runs on the host.
  mkdir -p "$root/escape-target/chromium-profile" \
    "$root/Users/alice/Library/Application Support/Chromium"
  printf 'must survive symlink escape test\n' > "$root/escape-target/chromium-profile/History"
  ln -s "$root/escape-target/chromium-profile" \
    "$root/Users/alice/Library/Application Support/Chromium/Default"

  # A symlink masquerading as a home directory must not be enumerated.
  mkdir -p "$root/escape-target/mallory-home"
  printf 'must survive linked-home test\n' > "$root/escape-target/mallory-home/.zsh_history"
  ln -s "$root/escape-target/mallory-home" "$root/Users/mallory"

  printf '[artifacts] building homes that enumerators must skip (Shared, Guest, .hiddenuser)\n'
  for special in 'Shared' 'Guest' '.hiddenuser'; do
    mkdir -p "$root/Users/$special"
    printf 'must survive cleaning %s\n' "$MARK_HIST" > "$root/Users/$special/.zsh_history"
    printf 'must survive dsstore cleaning %s\n' "$MARK_HIST" > "$root/Users/$special/.DS_Store"
  done
  printf 'must survive top-level dsstore cleaning %s\n' "$MARK_HIST" > "$root/Users/.DS_Store"

  printf '[artifacts] building system logs and diagnostic reports\n'
  mkdir -p "$root/var/log" "$root/Library/Logs/DiagnosticReports"
  {
    printf 'kernel: boot ok\n'
    printf '%s legacy branding must be scrubbed\n' "$MARK_LEGACY"
    printf '%s current branding log line\n' "$MARK_OWN"
  } > "$root/var/log/system.log"
  printf 'wifi association trace %s\n' "$MARK_OWN" > "$root/var/log/wifi.log"
  printf 'daily maintenance output %s\n' "$MARK_OWN" > "$root/var/log/daily.out"
  printf '{"ips":1,"marker":"%s","user":false}\n' "$MARK_OWN" > "$root/Library/Logs/DiagnosticReports/crash-1.ips"

  printf '[artifacts] building audit store (rotations + protected current)\n'
  mkdir -p "$root/var/audit"
  printf 'audit rotation 2023 tail\n' > "$root/var/audit/2023.12.31.235959+0000"
  printf 'audit rotation 2024 new year\n' > "$root/var/audit/2024.01.01.120000+0000"
  printf 'audit rotation 2024 mid year\n' > "$root/var/audit/2024.06.15.083000+0000"
  printf 'live audit stream — this entry must be preserved\n' > "$root/var/audit/2026.08.27.070000.not_terminated"
  rm -f "$root/var/audit/current"
  ln -s '2026.08.27.070000.not_terminated' "$root/var/audit/current"

  printf '[artifacts] building unified logging store\n'
  for tier in Persist Special HighVolume; do
    mkdir -p "$root/var/db/diagnostics/$tier"
    printf 'tracev3 chunk (%s) %s\n' "$tier" "$MARK_OWN" > "$root/var/db/diagnostics/$tier/0000000000000100.tracev3"
  done

  printf '[artifacts] building wifi system preferences\n'
  mkdir -p "$root/Library/Preferences/SystemConfiguration/com.apple.wifi.known-networks"
  printf 'airport remembered networks %s\n' "$MARK_OWN" > "$root/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist"
  printf 'wifi message tracer %s\n' "$MARK_OWN" > "$root/Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist"
  printf 'known network: home-ssid %s\n' "$MARK_OWN" > "$root/Library/Preferences/SystemConfiguration/com.apple.wifi.known-networks/network-home.plist"

  printf '[artifacts] building var folders (notification center, quicklook)\n'
  mkdir -p "$root/private/var/folders/xx/yy/C/com.apple.notificationcenter/db2" \
           "$root/private/var/folders/xx/yy/C/com.apple.QuickLook.thumbnailcache"
  printf 'notification center db %s\n' "$MARK_OWN" > "$root/private/var/folders/xx/yy/C/com.apple.notificationcenter/db2/db.db"
  printf 'thumbnail blob %s\n' "$MARK_OWN" > "$root/private/var/folders/xx/yy/C/com.apple.QuickLook.thumbnailcache/thumb.jpg"

  printf '[artifacts] building knowledge store (usage)\n'
  mkdir -p "$root/private/var/db/CoreDuet/Knowledge"
  make_knowledge_db "$root/private/var/db/CoreDuet/Knowledge/knowledgeC.db"

  printf '[artifacts] building external volume sentinel\n'
  mkdir -p "$root/Volumes/BACKUP"
  printf 'external backup volume sentinel %s\n' "$MARK_OWN" > "$root/Volumes/BACKUP/.DS_Store"

  if [ -n "$MANIFEST_FILE" ]; then
    write_manifest "$MANIFEST_FILE"
  fi

  printf '[artifacts] done: %s\n' "$root"
}

while [ $# -gt 0 ]; do
  case "$1" in
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
main
