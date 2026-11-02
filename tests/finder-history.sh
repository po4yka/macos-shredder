#!/bin/bash
# Fixture-only Finder history tests; native tools never target host preferences.
# shellcheck disable=SC2034 # Sourced functions consume the globals.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/User Space/Library/Preferences"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# shellcheck source=shredder.sh
source "$SHREDDER"
TEST_MODE=1
SANDBOX="$SHREDDER_ROOT"
resolve_paths
STORE_HOME="$USERS_DIR/User Space"
PREFS="$STORE_HOME/Library/Preferences"
FINDER="$PREFS/com.apple.finder.plist"
if module_selected finderhistory; then exit 1; fi
parse_args --modules finderhistory
cat > "$FINDER" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>FXRecentFolders</key><array><dict><key>name</key><string>private-folder</string><key>bookmark</key><data>AAEC/w==</data></dict></array>
<key>GoToFieldHistory</key><array><string>private-folder</string></array>
<key>GoToField</key><string>private-folder</string>
<key>FXConnectToLastURL</key><string>smb://private-server</string>
<key>RecentMoveAndCopyDestinations</key><array><string>private-folder</string></array>
<key>RecentSearches</key><array><string>private-search</string></array>
<key>FavoriteItems</key><array><string>keep-favorite</string></array>
<key>FXDesktopVolumePositions</key><dict><key>keep-position</key><integer>4</integer></dict>
<key>KeepBlob</key><data>AAEC/w==</data>
<key>KeepDate</key><date>2026-01-01T00:00:00Z</date>
<key>KeepBool</key><true/>
<key>FutureSetting</key><dict><key>deep</key><array><integer>42</integer></array></dict>
</dict></plist>
PLIST
for file in "$PREFS/.GlobalPreferences.plist" "$PREFS/com.apple.appkit.xpc.openAndSavePanelService.plist" "$STORE_HOME/Library/Containers/com.apple.appkit.xpc.openAndSavePanelService/Data/Library/Preferences/com.apple.appkit.xpc.openAndSavePanelService.plist"; do
    mkdir -p "${file%/*}"
    cat > "$file" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>NSNavRecentPlaces</key><array><string>private-folder</string></array><key>KeepSetting</key><string>keep</string></dict></plist>
PLIST
done
cp -R "$SANDBOX" "$WORK/before"
DRY_RUN=1
module_finderhistory
[ "$CLEANED_COUNT" -eq 4 ]
diff -r "$WORK/before" "$SANDBOX"
DRY_RUN=0
ln -s "$FINDER" "$PREFS/link.plist"
finder_history_plist "$PREFS/link.plist" finder
[ "$FAILED_COUNT" -eq 1 ]
mkdir "$PREFS/directory.plist"
finder_history_plist "$PREFS/directory.plist" finder
[ "$FAILED_COUNT" -eq 2 ]
FAILED_COUNT=0
printf 'PASS: finder selection, exact candidate paths, preview and path refusal\n'
# Only the process query is controlled, never a native user preference store.
TEST_MODE=0
ps() { return 2; }
if finder_history_clients_stopped; then exit 1; fi
ps() { printf '/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder\n'; }
if finder_history_clients_stopped; then exit 1; fi
ps() { printf '/System/XPCServices/com.apple.appkit.xpc.openAndSavePanelService\n'; }
if finder_history_clients_stopped; then exit 1; fi
ps() { printf '/bin/bash test\n'; }
finder_history_clients_stopped
unset -f ps
TEST_MODE=1
printf 'PASS: finder and panel process guards and query failure\n'
if [ "$(uname -s)" != Darwin ] || [ ! -x /usr/bin/defaults ]; then
    before="$(cksum "$FINDER")"
    finder_history_plist "$FINDER" finder
    [ "$FAILED_COUNT" -eq 1 ]
    [ "$(cksum "$FINDER")" = "$before" ]
    printf 'PASS: unavailable native tools retain preference data\n'
    printf 'SKIP: native preference operations require macOS; run this test on macOS\n'
    exit 0
fi
# Binary input includes data/date/bool/nested unknown settings that must survive.
/usr/bin/plutil -convert binary1 "$FINDER"
module_finderhistory
[ "$FAILED_COUNT" -eq 0 ]
[ "$CLEANED_COUNT" -eq 8 ]
for key in FXRecentFolders GoToFieldHistory GoToField FXConnectToLastURL RecentMoveAndCopyDestinations RecentSearches; do
    if /usr/bin/plutil -type "$key" "$FINDER" >/dev/null 2>&1; then exit 1; fi
done
[ "$(/usr/bin/plutil -extract FavoriteItems.0 raw "$FINDER")" = keep-favorite ]
[ "$(/usr/bin/plutil -extract FXDesktopVolumePositions.keep-position raw "$FINDER")" = 4 ]
[ "$(/usr/bin/plutil -extract KeepBlob raw "$FINDER")" = AAEC/w== ]
[ "$(/usr/bin/plutil -extract KeepDate raw "$FINDER")" = 2026-01-01T00:00:00Z ]
[ "$(/usr/bin/plutil -extract KeepBool raw "$FINDER")" = true ]
[ "$(/usr/bin/plutil -extract FutureSetting.deep.0 raw "$FINDER")" = 42 ]
for file in "$PREFS/.GlobalPreferences.plist" "$PREFS/com.apple.appkit.xpc.openAndSavePanelService.plist" "$STORE_HOME/Library/Containers/com.apple.appkit.xpc.openAndSavePanelService/Data/Library/Preferences/com.apple.appkit.xpc.openAndSavePanelService.plist"; do
    if /usr/bin/plutil -type NSNavRecentPlaces "$file" >/dev/null 2>&1; then exit 1; fi
    [ "$(/usr/bin/plutil -extract KeepSetting raw "$file")" = keep ]
done
before="$(cksum "$FINDER")"
module_finderhistory
[ "$CLEANED_COUNT" -eq 8 ]
[ "$FAILED_COUNT" -eq 0 ]
[ "$(cksum "$FINDER")" = "$before" ]
printf 'PASS: native binary/XML key deletion, data/date/settings preservation and repeat runs\n'
# Unknown known-key type blocks the entire file before another history key changes.
/usr/bin/plutil -insert GoToField -string private-folder "$FINDER"
/usr/bin/plutil -insert FXRecentFolders -string unknown-future-format "$FINDER"
before="$(cksum "$FINDER")"
finder_history_plist "$FINDER" finder
[ "$FAILED_COUNT" -eq 1 ]
[ "$(cksum "$FINDER")" = "$before" ]
# Even a valid plist is refused when it has a second hardlink.
/usr/bin/plutil -remove FXRecentFolders "$FINDER"
ln "$FINDER" "$PREFS/hardlink.plist"
before="$(cksum "$FINDER")"
finder_history_plist "$FINDER" finder
[ "$FAILED_COUNT" -eq 2 ]
[ "$(cksum "$FINDER")" = "$before" ]
printf 'not a plist\n' > "$PREFS/malformed.plist"
before="$(cksum "$PREFS/malformed.plist")"
finder_history_plist "$PREFS/malformed.plist" finder
[ "$FAILED_COUNT" -eq 3 ]
[ "$(cksum "$PREFS/malformed.plist")" = "$before" ]
printf 'PASS: native unknown-format, hardlink and malformed plist refusal\n'
