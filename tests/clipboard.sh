#!/bin/bash
# Maccy schema, pin preservation and refusal tests in marked temporary roots.
# shellcheck disable=SC2034 # Globals are consumed by sourced module functions.
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
    STORE_HOME="$USERS_DIR/User Space"
    CLIPBOARD_INCLUDE_PINNED=0
    CLIPBOARD_CURRENT=0
}
seed() {
    mkdir -p "${1%/*}"
    sqlite3 "$1" <<'SQL'
CREATE TABLE ZHISTORYITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNUMBEROFCOPIES INTEGER, ZFIRSTCOPIEDAT TIMESTAMP, ZLASTCOPIEDAT TIMESTAMP, ZAPPLICATION VARCHAR, ZPIN VARCHAR, ZTITLE VARCHAR);
CREATE TABLE ZHISTORYITEMCONTENT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZITEM INTEGER, ZTYPE VARCHAR, ZVALUE BLOB);
CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR, Z_PLIST BLOB);
CREATE TABLE Z_MODELCACHE (Z_CONTENT BLOB);
CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
CREATE TABLE ACHANGE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCHANGETYPE INTEGER, ZENTITY INTEGER, ZENTITYPK INTEGER, ZTRANSACTIONID INTEGER, ZCOLUMNS BLOB);
CREATE TABLE ATRANSACTION (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAUTHORTS INTEGER, ZBUNDLEIDTS INTEGER, ZCONTEXTNAMETS INTEGER, ZPROCESSIDTS INTEGER, ZTIMESTAMP FLOAT, ZAUTHOR VARCHAR, ZBUNDLEID VARCHAR, ZCONTEXTNAME VARCHAR, ZPROCESSID VARCHAR, ZQUERYGEN BLOB);
CREATE TABLE ATRANSACTIONSTRING (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNAME VARCHAR);
INSERT INTO ZHISTORYITEM (Z_PK,ZPIN,ZTITLE) VALUES(1,NULL,'remove-marker'),(2,'b','pinned'),(3,'','empty-pin-is-still-a-pin');
INSERT INTO ZHISTORYITEMCONTENT(Z_PK,ZITEM,ZTYPE,ZVALUE) VALUES(1,1,'public.text','remove-marker'),(2,2,'public.data',X'000102FF'),(3,3,'public.text','keep-empty-pin'),(4,NULL,'public.text','remove-marker'),(5,99,'public.text','remove-marker');
INSERT INTO Z_METADATA VALUES(1,'keep-uuid',X'AABB');
INSERT INTO Z_MODELCACHE VALUES(X'FF0001');
INSERT INTO Z_PRIMARYKEY VALUES(1,'HistoryItem',0,3),(2,'HistoryItemContent',0,5);
INSERT INTO ACHANGE(Z_PK,ZCOLUMNS) VALUES(1,'remove-marker');
INSERT INTO ATRANSACTION(Z_PK,ZAUTHOR) VALUES(1,'remove-marker');
INSERT INTO ATRANSACTIONSTRING(Z_PK,ZNAME) VALUES(1,'remove-marker');
SQL
    printf 'keep-preferences\n' > "${1%/*}/preferences.plist"
}
assert_kept() {
    [ "$(sqlite3 "$1" 'SELECT count(*) FROM ZHISTORYITEM; SELECT count(*) FROM ZHISTORYITEMCONTENT;')" = $'2\n2' ]
    [ "$(sqlite3 "$1" 'SELECT hex(ZVALUE) FROM ZHISTORYITEMCONTENT WHERE Z_PK=2;')" = 000102FF ]
    [ "$(sqlite3 "$1" 'SELECT Z_UUID||hex(Z_PLIST) FROM Z_METADATA;')" = keep-uuidAABB ]
    [ "$(sqlite3 "$1" 'SELECT hex(Z_CONTENT) FROM Z_MODELCACHE;')" = FF0001 ]
    [ "$(sqlite3 "$1" 'SELECT sum(Z_MAX) FROM Z_PRIMARYKEY;')" = 8 ]
    [ "$(sqlite3 "$1" 'PRAGMA integrity_check;')" = ok ]
    grep -q keep-preferences "${1%/*}/preferences.plist"
    if grep -a -q remove-marker "$1"; then return 1; fi
}

test_history() (
    setup history
    local root db
    for root in "$STORE_HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy" "$STORE_HOME/Library/Application Support/Maccy"; do
        seed "$root/Storage.sqlite"
    done
    cp -R "$SANDBOX" "$WORK/before"
    DRY_RUN=1
    module_clipboard
    [ "$CLEANED_COUNT" -eq 2 ]
    diff -r "$WORK/before" "$SANDBOX"
    DRY_RUN=0
    module_clipboard
    [ "$FAILED_COUNT" -eq 0 ]
    for db in "$STORE_HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite" "$STORE_HOME/Library/Application Support/Maccy/Storage.sqlite"; do
        CLIPBOARD_INCLUDE_PINNED=0
        assert_kept "$db"
        clipboard_purge_maccy "$db"
        assert_kept "$db"
        CLIPBOARD_INCLUDE_PINNED=1
        clipboard_purge_maccy "$db"
        [ "$(sqlite3 "$db" 'SELECT count(*) FROM ZHISTORYITEM; SELECT count(*) FROM ZHISTORYITEMCONTENT;')" = $'0\n0' ]
    done
)
test_history
printf 'PASS: Maccy dry-run, both default paths, pinned/metadata preservation and opt-in pin deletion\n'

test_failures() (
    setup failures
    local db="$STORE_HOME/Storage.sqlite" before
    seed "$db"
    sqlite3 "$db" 'CREATE TABLE unknown_settings(value TEXT); INSERT INTO unknown_settings VALUES("keep");'
    before="$(shasum "$db")"
    if clipboard_purge_maccy "$db"; then exit 1; fi
    [ "$(shasum "$db")" = "$before" ]
    sqlite3 "$db" 'DROP TABLE unknown_settings; CREATE TRIGGER unsafe AFTER DELETE ON ZHISTORYITEM BEGIN DELETE FROM Z_METADATA; END;'
    before="$(shasum "$db")"
    if clipboard_purge_maccy "$db"; then exit 1; fi
    [ "$(shasum "$db")" = "$before" ]
    sqlite3 "$db" 'DROP TRIGGER unsafe; ALTER TABLE ZHISTORYITEM ADD COLUMN FUTURE_SETTINGS TEXT;'
    before="$(shasum "$db")"
    if clipboard_purge_maccy "$db"; then exit 1; fi
    [ "$(shasum "$db")" = "$before" ]
    printf 'not sqlite\n' > "$STORE_HOME/corrupt.sqlite"
    if clipboard_purge_maccy "$STORE_HOME/corrupt.sqlite"; then exit 1; fi
    mkdir "$STORE_HOME/.Storage_SUPPORT"
    if clipboard_purge_maccy "$db"; then exit 1; fi
    [ "$(shasum "$db")" = "$before" ]
)
test_failures
printf 'PASS: unknown tables/columns, triggers, corruption and external blobs fail closed\n'

test_links() (
    setup links
    local db="$STORE_HOME/Storage.sqlite"
    seed "$db"
    ln "$db" "$WORK/hardlink.sqlite"
    if clipboard_purge_maccy "$db"; then exit 1; fi
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM ZHISTORYITEM;')" = 3 ]
    rm "$WORK/hardlink.sqlite"
    printf keep > "$WORK/sentinel"
    ln -s "$WORK/sentinel" "$db-wal"
    if clipboard_purge_maccy "$db"; then exit 1; fi
    [ "$(cat "$WORK/sentinel")" = keep ]
    rm "$db-wal"
    ln -s "$db" "$STORE_HOME/linked.sqlite"
    if clipboard_purge_maccy "$STORE_HOME/linked.sqlite"; then exit 1; fi
    printf orphan > "$STORE_HOME/missing.sqlite-wal"
    if clipboard_purge_maccy "$STORE_HOME/missing.sqlite"; then exit 1; fi
    [ -f "$STORE_HOME/missing.sqlite-wal" ]
    ln -s "$STORE_HOME" "$STORE_HOME/link-parent"
    if clipboard_purge_maccy "$STORE_HOME/link-parent/Storage.sqlite"; then exit 1; fi
)
test_links
printf 'PASS: database/parent symlinks, hardlinks and orphan sidecars retained\n'

test_process_guard() (
    setup processes
    TEST_MODE=0
    ps() { printf '%s\n' "$PROCESS_LINE"; }
    local line
    for line in '/Applications/Maccy.app/Contents/MacOS/Maccy' '/opt/homebrew/bin/Maccy' 'Maccy'; do
        PROCESS_LINE="$line"
        if clipboard_maccy_stopped; then exit 1; fi
    done
    PROCESS_LINE='/bin/bash shredder.sh --modules clipboard --force'
    clipboard_maccy_stopped
    ps() { return 1; }
    if clipboard_maccy_stopped; then exit 1; fi
    TEST_MODE=1
    run_as_user() { printf 'host command called\n' >&2; return 99; }
    CLIPBOARD_CURRENT=1
    module_clipboard
    [ "$FAILED_COUNT" -eq 0 ]
)
test_process_guard
printf 'PASS: active Maccy/process-query failure guard and sandbox pasteboard isolation\n'

test_wal_and_lock() (
    setup wal
    local db="$STORE_HOME/Storage.sqlite" pid attempt=0
    seed "$db"
    mkfifo "$WORK/clipboard-sql-input"
    sqlite3 "$db" < "$WORK/clipboard-sql-input" > "$WORK/clipboard-sql-output" 2>&1 &
    pid=$!
    trap 'exec 3>&-; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
    exec 3> "$WORK/clipboard-sql-input"
    printf '%s\n' 'PRAGMA journal_mode=WAL;' \
        'INSERT INTO ZHISTORYITEM(Z_PK,ZPIN,ZTITLE) VALUES(4,NULL,"remove-marker-wal");' \
        'BEGIN IMMEDIATE;' '.print ready' >&3
    until grep -q ready "$WORK/clipboard-sql-output"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 200 ] || exit 1
        sleep 0.01
    done
    [ -s "$db-wal" ]
    cp -R "$SANDBOX" "$WORK/clipboard-wal-before"
    DRY_RUN=1
    clipboard_purge_maccy "$db"
    diff -r "$WORK/clipboard-wal-before" "$SANDBOX"
    DRY_RUN=0
    if clipboard_purge_maccy "$db"; then exit 1; fi
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM ZHISTORYITEM;')" = 4 ]
    printf '%s\n' 'COMMIT;' '.quit' >&3
    exec 3>&-
    wait "$pid"
    trap - EXIT
    clipboard_purge_maccy "$db"
    assert_kept "$db"
    [ ! -s "$db-wal" ]
)
test_wal_and_lock
printf 'PASS: real WAL byte-stable preview, writer-lock refusal and successful checkpoint\n'

test_sqlite_required() (
    setup sqlite-required
    local db="$STORE_HOME/Storage.sqlite" before
    seed "$db"
    before="$(shasum "$db")"
    command() {
        if [ "$*" = '-v sqlite3' ]; then return 1; fi
        builtin command "$@"
    }
    if clipboard_purge_maccy "$db"; then exit 1; fi
    [ "$(shasum "$db")" = "$before" ]
)
test_sqlite_required
printf 'PASS: missing SQLite retains Maccy history\n'
