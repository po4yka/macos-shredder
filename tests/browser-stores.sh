#!/bin/bash
# Browser storage tests use only a marked temporary sandbox.
# Each subshell calls setup(), which reloads all cleaner globals.
# shellcheck disable=SC2030,SC2031
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
setup() {
    export SHREDDER_ROOT="$WORK/$1"
    mkdir -p "$SHREDDER_ROOT/Users/User Space"
    : > "$SHREDDER_ROOT/.macos-shredder-test-root"
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    TEST_MODE=1
    SANDBOX="$SHREDDER_ROOT"
    resolve_paths
    BROWSER_HOME="$USERS_DIR/User Space"
}
put() { mkdir -p "${1%/*}"; printf '%s\n' "${2:-site-marker}" > "$1"; }
expect_status() {
    local expected="$1" rc=0
    shift
    /bin/bash "$SHREDDER" "$@" > "$WORK/last.log" 2>&1 || rc=$?
    if [ "$rc" -ne "$expected" ]; then cat "$WORK/last.log"; printf 'expected %s, got %s\n' "$expected" "$rc"; return 1; fi
}
seed_firefox_db() {
    mkdir -p "${1%/*}"
    sqlite3 "$1" <<'SQL'
CREATE TABLE webappsstore2(originAttributes TEXT, originKey TEXT, scope TEXT, key TEXT, value TEXT);
INSERT INTO webappsstore2 VALUES('', 'moc.elpmaxe.:https:443', '', 'token', 'site-marker');
INSERT INTO webappsstore2 VALUES('^userContextId=2', 'moc.elpmaxe.:http:80', '', 'token', 'site-marker');
INSERT INTO webappsstore2 VALUES('', '.:file:0', '', 'token', 'site-marker');
INSERT INTO webappsstore2 VALUES('', 'di-extension.:moz-extension:0', '', 'token', 'keep-extension');
SQL
}

test_chromium() (
    setup chromium
    local base="$BROWSER_HOME/Library/Application Support/Google/Chrome" prof item
    for prof in Default 'Profile 1' 'Guest Profile'; do
        for item in Network/Cookies Network/Cookies-wal 'Network/Device Bound Sessions' \
            Sessions/Session_123 Sessions_Encrypted/Tabs_123 'Current Session' 'Current Tabs' \
            'Last Session' 'Last Tabs' IndexedDB/https_example.com_0.indexeddb.leveldb/0001.ldb \
            IndexedDB/file__0.indexeddb.blob/blob; do put "$base/$prof/$item"; done
        for item in Bookmarks 'Login Data' Preferences 'Secure Preferences' \
            'Local Extension Settings/extension/0001.ldb' 'Sync Extension Settings/extension/0001.ldb' \
            IndexedDB/chrome-extension_extension_0.indexeddb.leveldb/0001.ldb; do put "$base/$prof/$item" keep; done
        for item in 'Local Storage' 'Session Storage' 'Service Worker' 'File System' databases 'Application Cache' WebStorage; do
            put "$base/$prof/$item/0001.ldb" mixed-marker
        done
    done
    cp -R "$SANDBOX" "$WORK/chromium-before"
    expect_status 0 --modules browser --dry-run --debug --include-extension-data
    diff -r "$WORK/chromium-before" "$SANDBOX"
    expect_status 2 --modules browser --force
    if grep -R -a -l site-marker "$base"; then exit 1; fi
    for prof in Default 'Profile 1' 'Guest Profile'; do
        grep -q keep "$base/$prof/Preferences"
        grep -q keep "$base/$prof/IndexedDB/chrome-extension_extension_0.indexeddb.leveldb/0001.ldb"
        grep -q mixed-marker "$base/$prof/Local Storage/0001.ldb"
    done
    expect_status 0 --modules browser --force --include-extension-data
    if grep -R -a -l mixed-marker "$base"; then exit 1; fi
    for prof in Default 'Profile 1' 'Guest Profile'; do
        [ ! -e "$base/$prof/IndexedDB" ]
        grep -q keep "$base/$prof/Login Data"
        grep -q keep "$base/$prof/Bookmarks"
        grep -q keep "$base/$prof/Local Extension Settings/extension/0001.ldb"
    done
    expect_status 0 --modules browser --force --include-extension-data
)
test_chromium
printf 'PASS: Chromium profiles, recovery, cookies and explicit mixed-store opt-in\n'

test_firefox() (
    setup firefox
    local prof="$BROWSER_HOME/Library/Application Support/Firefox/Profiles/test.default" store scheme
    for store in default temporary permanent persistent; do
        for scheme in http+++example.com 'https+++example.com^userContextId=3' file++++Users+file; do
            put "$prof/storage/$store/$scheme/idb/data.sqlite"
        done
        put "$prof/storage/$store/moz-extension+++extension/idb/data.sqlite" keep
        put "$prof/storage/$store/about+home/data.sqlite" keep
    done
    seed_firefox_db "$prof/webappsstore.sqlite"
    seed_firefox_db "$prof/storage/ls-archive.sqlite"
    sqlite3 "$prof/storage.sqlite" <<'SQL'
CREATE TABLE database(cache_version INTEGER NOT NULL DEFAULT 0);
CREATE TABLE cache(valid INTEGER NOT NULL DEFAULT 0, build_id TEXT NOT NULL DEFAULT '');
CREATE TABLE repository(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE origin(repository_id INTEGER NOT NULL, suffix TEXT, group_ TEXT NOT NULL,
    origin TEXT NOT NULL, client_usages TEXT NOT NULL, usage INTEGER NOT NULL,
    last_access_time INTEGER NOT NULL, last_maintenance_date INTEGER NOT NULL,
    accessed INTEGER NOT NULL, persisted INTEGER NOT NULL,
    PRIMARY KEY(repository_id,origin), FOREIGN KEY(repository_id) REFERENCES repository(id));
INSERT INTO database VALUES(1);
INSERT INTO cache VALUES(1,'keep');
INSERT INTO repository VALUES(0,'default');
INSERT INTO origin VALUES(0,'','example.com','https://site-marker','',1,1,1,1,0);
INSERT INTO origin VALUES(0,'','extension','moz-extension://extension','',1,1,1,1,0);
SQL
    put "$prof/sessionstore.jsonlz4"
    put "$prof/sessionstore-backups/recovery.jsonlz4"
    put "$prof/sessionstore.js"
    put "$prof/sessionstore.bak"
    put "$prof/logins.json" keep
    put "$prof/key4.db" keep
    put "$prof/prefs.js" keep
    put "$prof/browser-extension-data/extension/storage.js" keep
    expect_status 0 --modules browser --force
    if grep -R -a -l site-marker "$prof"; then exit 1; fi
    [ "$(sqlite3 "$prof/webappsstore.sqlite" 'SELECT value FROM webappsstore2;')" = keep-extension ]
    [ "$(sqlite3 "$prof/storage/ls-archive.sqlite" 'PRAGMA integrity_check;')" = ok ]
    grep -q keep "$prof/storage/default/moz-extension+++extension/idb/data.sqlite"
    grep -q keep "$prof/key4.db"
    [ "$(sqlite3 "$prof/storage.sqlite" 'SELECT origin FROM origin;')" = 'moz-extension://extension' ]
    [ "$(sqlite3 "$prof/storage.sqlite" 'SELECT valid FROM cache;')" = 0 ]
    expect_status 0 --modules browser --force
    expect_status 0 --modules browser --force --include-extension-data
    [ "$(sqlite3 "$prof/storage.sqlite" 'SELECT count(*) FROM origin;')" = 0 ]
    [ ! -e "$prof/webappsstore.sqlite" ]
    [ ! -e "$prof/storage/default/moz-extension+++extension" ]
    grep -q keep "$prof/browser-extension-data/extension/storage.js"
)
test_firefox
printf 'PASS: Firefox website origins, legacy SQLite and extension/password preservation\n'

test_safari() (
    setup safari
    local lib="$BROWSER_HOME/Library/Containers/com.apple.Safari/Data/Library" item
    for item in Safari/LastSession.plist Safari/RecentlyClosedTabs.plist \
        'Saved Application State/com.apple.Safari.savedState/windows.plist' \
        Cookies/Cookies.binarycookies WebKit/WebsiteDataStore/profile/Cookies/Cookies.binarycookies; do put "$lib/$item"; done
    for item in WebKit/WebsiteData/Default/hash/origin \
        WebKit/WebsiteData/LocalStorage/https_example.com_0.localstorage \
        WebKit/WebsiteDataStore/profile/Origins/hash/origin \
        WebKit/WebsiteDataStore/profile/IndexedDB/hash/data.sqlite; do put "$lib/$item" mixed-marker; done
    put "$lib/Safari/Bookmarks.plist" keep
    put "$lib/Preferences/com.apple.Safari.plist" keep
    expect_status 2 --modules browser --force
    if grep -R -a -l site-marker "$lib"; then exit 1; fi
    expect_status 0 --modules browser --force --include-extension-data
    if grep -R -a -l mixed-marker "$lib"; then exit 1; fi
    grep -q keep "$lib/Safari/Bookmarks.plist"
    grep -q keep "$lib/Preferences/com.apple.Safari.plist"
    put "$lib/Safari/SafariTabs.db" keep-synced-tabs
    expect_status 2 --modules browser --force --include-extension-data
    grep -q keep-synced-tabs "$lib/Safari/SafariTabs.db"
)
test_safari
printf 'PASS: Safari WebKit stores and recovery; mixed saved/synced tabs remain reported\n'

test_failures() (
    setup failure
    local prof="$BROWSER_HOME/Library/Application Support/Firefox/Profiles/test.default" chrome
    seed_firefox_db "$prof/webappsstore.sqlite"
    sqlite3 "$prof/webappsstore.sqlite" 'CREATE TABLE unknown_config(value TEXT);'
    expect_status 2 --modules browser --force
    [ "$(sqlite3 "$prof/webappsstore.sqlite" 'SELECT count(*) FROM webappsstore2;')" = 4 ]
    put "$WORK/outside/data" keep
    chrome="$BROWSER_HOME/Library/Application Support/Google/Chrome/Default"
    mkdir -p "$chrome"
    ln -s "$WORK/outside" "$chrome/Network"
    mkdir -p "$prof/storage"
    ln -s "$WORK/outside" "$prof/storage/default"
    expect_status 2 --modules browser --force --include-extension-data
    grep -q keep "$WORK/outside/data"
)
test_failures
printf 'PASS: unknown SQLite schema and linked site-storage parents are safe\n'

test_running() (
    setup running
    local chrome="$BROWSER_HOME/Library/Application Support/Google/Chrome/Default" firefox safari
    firefox="$BROWSER_HOME/Library/Application Support/Firefox/Profiles/test.default"
    safari="$BROWSER_HOME/Library/Containers/com.apple.Safari/Data/Library"
    put "$chrome/Sessions/Session_123" keep
    put "$chrome/Local Storage/leveldb/0001.ldb" keep
    put "$firefox/storage/default/https+++example.com/idb/data" keep
    put "$safari/WebKit/WebsiteData/Default/hash/origin" keep
    cp -R "$SANDBOX" "$WORK/running-before"
    browser_running() { return 0; }
    INCLUDE_EXTENSION_DATA=1
    module_browser
    [ "$FAILED_COUNT" -eq 3 ]
    diff -r "$WORK/running-before" "$SANDBOX"
    # Reload the real process guard, then inject return statuses, never a host mutation.
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    TEST_MODE=0
    # shellcheck disable=SC2329 # called by browser_running
    pgrep() { return 2; }
    browser_running Safari
    # shellcheck disable=SC2329 # called by browser_running
    pgrep() { return 1; }
    if browser_running Safari; then exit 1; fi
    # shellcheck disable=SC2329 # called by browser_running
    pgrep() { return 0; }
    browser_running 'Google Chrome'

)
test_running
printf 'PASS: running browsers and failed process queries block site/session cleanup\n'

# Check the macOS process name through the actual browser registry.
test_brave_process_name() (
    setup brave_process
    FAILED_COUNT=0
    put "$BROWSER_HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Sessions/Session_1" keep
    browser_running() { [ "$1" = 'Brave Browser' ]; }
    clean_chrome_family_for_home "$BROWSER_HOME"
    [ "$FAILED_COUNT" -eq 1 ]
    grep -q keep "$BROWSER_HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Sessions/Session_1"
)
test_brave_process_name
printf 'PASS: Brave uses its macOS process name in the active-browser guard\n'


test_safari_cache_roots() (
    setup safari_cache
    local cache="$BROWSER_HOME/Library/Caches/com.apple.Safari" item
    # No ~/Library/Safari, container or cookie root exists in this first case.
    put "$cache/WebKit/ServiceWorkers/ServiceWorkerRegistrations-1.sqlite3" mixed-marker
    put "$cache/WebKit/CacheStorage/hash/data" mixed-marker
    put "$cache/WebKit/Storage/hash/origin" mixed-marker
    put "$cache/WebKit/NetworkCache/cache" site-marker
    put "$cache/cache-file" site-marker
    cp -R "$SANDBOX" "$WORK/safari-cache-before"
    browser_running() { return 0; }
    clean_safari_for_home "$BROWSER_HOME"
    [ "$FAILED_COUNT" -eq 1 ]
    diff -r "$WORK/safari-cache-before" "$SANDBOX"
    browser_running() { return 1; }
    clean_safari_for_home "$BROWSER_HOME"
    if grep -R -a -l site-marker "$cache"; then exit 1; fi
    grep -q mixed-marker "$cache/WebKit/CacheStorage/hash/data"
    cache="$BROWSER_HOME/Library/Containers/com.apple.Safari/Data/Library/Caches"
    for item in ServiceWorkers CacheStorage Storage; do put "$cache/WebKit/$item/data" mixed-marker; done
    INCLUDE_EXTENSION_DATA=1
    FAILED_COUNT=0
    clean_safari_for_home "$BROWSER_HOME"
    [ "$FAILED_COUNT" -eq 0 ]
    if grep -R -a -l mixed-marker "$BROWSER_HOME"; then exit 1; fi
)
test_safari_cache_roots
printf 'PASS: Safari cache-only roots respect active-browser and mixed-store guards\n'

test_busy_browser_checkpoint() (
    setup busy_browser_checkpoint
    local db="$BROWSER_HOME/webappsstore.sqlite" pid attempt=0
    seed_firefox_db "$db"
    mkfifo "$WORK/browser-sql-input"
    sqlite3 "$db" < "$WORK/browser-sql-input" > "$WORK/browser-sql-output" 2>&1 &
    pid=$!
    trap 'exec 3>&-; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
    exec 3> "$WORK/browser-sql-input"
    # Keep both the connection and a read snapshot open after a committed write.
    printf '%s\n' 'PRAGMA journal_mode=WAL;' \
        "INSERT INTO webappsstore2 VALUES('', 'moc.elpmaxe.:https:443', '', 'wal', 'pinned-wal-marker');" \
        'BEGIN;' 'SELECT count(*) FROM webappsstore2;' '.print ready' >&3
    until grep -q ready "$WORK/browser-sql-output"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 200 ] || exit 1
        sleep 0.01
    done
    purge_firefox_localstorage "$db"
    [ "$FAILED_COUNT" -eq 1 ]
    [ "$CLEANED_COUNT" -eq 0 ]
    grep -a -q pinned-wal-marker "$db-wal"
    printf '%s\n' 'COMMIT;' '.quit' >&3
    exec 3>&-
    wait "$pid"
    trap - EXIT
    FAILED_COUNT=0
    purge_firefox_localstorage "$db"
    [ "$FAILED_COUNT" -eq 0 ]
    [ ! -s "$db-wal" ]
    [ "$(sqlite3 "$db" 'SELECT value FROM webappsstore2;')" = keep-extension ]
)
test_busy_browser_checkpoint
printf 'PASS: pinned WAL reader reports failure until checkpoint can complete\n'
