#!/bin/bash
# shellcheck disable=SC2034 # sourced module functions use fixture globals
# Real SQLite operations only inside marked temporary roots; no host cleanup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
setup() {
    export SHREDDER_ROOT="$WORK/$1"
    mkdir -p "$SHREDDER_ROOT/Users/User Space"
    : > "$SHREDDER_ROOT/.macos-shredder-test-root"
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    TEST_MODE=1; SANDBOX="$SHREDDER_ROOT"; resolve_paths
    STORE_HOME="$USERS_DIR/User Space"
}
notifications() {
    mkdir -p "${1%/*}"
    sqlite3 "$1" <<'SQL'
CREATE TABLE dbinfo(key VARCHAR,value VARCHAR);
CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier VARCHAR,badge INTEGER);
CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,data BLOB,request_date REAL,request_last_date REAL,delivered_date REAL,presented Bool,style INTEGER,snooze_fire_date REAL);
CREATE TABLE requests(app_id INTEGER PRIMARY KEY,list BLOB);
CREATE TABLE delivered(app_id INTEGER PRIMARY KEY,list BLOB);
CREATE TABLE displayed(app_id INTEGER PRIMARY KEY,list BLOB);
CREATE TABLE categories(app_id INTEGER PRIMARY KEY,categories BLOB);
INSERT INTO dbinfo VALUES('version','1');
INSERT INTO app VALUES(1,'example.app',2);
INSERT INTO categories VALUES(1,'preserved-category');
INSERT INTO requests VALUES(1,'pending-request');
INSERT INTO record(rec_id,app_id,data,delivered_date) VALUES(1,1,'delivered-history',100),(2,1,'pending-data',NULL),(3,1,'pending-zero',0);
INSERT INTO delivered VALUES(1,'delivered-history');
INSERT INTO displayed VALUES(1,'displayed-history');
SQL
}
(
    setup notifications
    db="$STORE_HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
    notifications "$db"
    cp -R "$SANDBOX" "$WORK/before"
    DRY_RUN=1; module_notifications; diff -r "$WORK/before" "$SANDBOX"
    DRY_RUN=0; module_notifications
    [ "$FAILED_COUNT" -eq 0 ]; [ "$CLEANED_COUNT" -eq 2 ]
    [ "$(sqlite3 "$db" 'SELECT group_concat(rec_id) FROM record;')" = '2,3' ]
    [ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM delivered UNION ALL SELECT COUNT(*) FROM displayed;')" = $'0\n0' ]
    [ "$(sqlite3 "$db" 'SELECT list FROM requests;')" = pending-request ]
    [ "$(sqlite3 "$db" 'SELECT categories FROM categories;')" = preserved-category ]
    [ "$(sqlite3 "$db" 'SELECT identifier FROM app;')" = example.app ]
    module_notifications; [ "$FAILED_COUNT" -eq 0 ]
)
printf 'PASS: notification cleanup preserves pending requests, app settings and categories; dry-run stable\n'
for fault in unknown trigger column symlink hardlink locked; do
(
    setup "$fault"
    db="$STORE_HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
    notifications "$db"
    case "$fault" in
        unknown) sqlite3 "$db" 'CREATE TABLE unknown_settings(value);' ;;
        trigger) sqlite3 "$db" 'CREATE TRIGGER damage AFTER DELETE ON record BEGIN DELETE FROM app; END;' ;;
        column) sqlite3 "$db" 'ALTER TABLE record RENAME COLUMN delivered_date TO unknown_date;' ;;
        symlink) mv "$db" "${db%/*}/../saved"; ln -s "${db%/*}/../saved" "$db" ;;
        hardlink) ln "$db" "${db%/*}/../saved" ;;
        locked) activity_store_idle() { return 1; } ;;
    esac
    module_notifications
    [ "$FAILED_COUNT" -eq 1 ]
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM record;')" -eq 3 ]
    [ "$(sqlite3 "$db" 'SELECT identifier FROM app;')" = example.app ]
)
done
printf 'PASS: unknown schema, trigger, missing column, links and active stores are retained\n'
(
    setup intelligence
    base="$STORE_HOME/Library/IntelligencePlatform"; mkdir -p "$base"
    sqlite3 "$base/eventLog.db" 'CREATE TABLE grdb_migrations(identifier TEXT); CREATE TABLE events(id INTEGER,timestamp DATETIME,payload BLOB); CREATE TABLE pre_events(id INTEGER,timestamp DATETIME,payload BLOB); INSERT INTO grdb_migrations VALUES("preserve"); INSERT INTO events VALUES(1,100,"history"); INSERT INTO pre_events VALUES(2,200,"history");'
    sqlite3 "$base/feedbackLog.db" 'CREATE TABLE grdb_migrations(identifier TEXT); CREATE TABLE feedback(id INTEGER PRIMARY KEY AUTOINCREMENT,timestamp DATETIME,feedback BLOB); CREATE TABLE deferred(feedbackId INTEGER,processorName TEXT); INSERT INTO grdb_migrations VALUES("preserve"); INSERT INTO feedback VALUES(1,100,"history"); INSERT INTO deferred VALUES(1,"worker");'
    printf keep > "$base/keyvalue.db"
    module_activity; [ "$FAILED_COUNT" -eq 0 ]
    [ "$(sqlite3 "$base/eventLog.db" 'SELECT count(*) FROM events UNION ALL SELECT count(*) FROM pre_events;')" = $'0\n0' ]
    [ "$(sqlite3 "$base/feedbackLog.db" 'SELECT count(*) FROM feedback UNION ALL SELECT count(*) FROM deferred;')" = $'0\n0' ]
    [ "$(sqlite3 "$base/feedbackLog.db" 'SELECT identifier FROM grdb_migrations;')" = preserve ]
    grep -q keep "$base/keyvalue.db"
    mkdir -p "$STORE_HOME/Library/Biome/streams"; printf keep > "$STORE_HOME/Library/Biome/streams/data"
    printf keep > "$base/graph.db"
    module_activity; [ "$FAILED_COUNT" -eq 2 ]
    grep -q keep "$base/graph.db"; grep -q keep "$STORE_HOME/Library/Biome/streams/data"
)
printf 'PASS: IntelligencePlatform event/feedback cleanup preserves configuration; unsupported stores report failure\n'
(
    setup knowledge
    db="$STORE_HOME/Library/Application Support/Knowledge/knowledgeC.db"; mkdir -p "${db%/*}"
    sqlite3 "$db" 'CREATE TABLE ZOBJECT(Z_PK INTEGER,Z_ENT INTEGER); CREATE TABLE ZSTRUCTUREDMETADATA(Z_PK INTEGER,Z_ENT INTEGER); CREATE TABLE ZKEYVALUE(ZKEY TEXT,ZVALUE BLOB); CREATE TABLE ZCUSTOMMETADATA(Z_PK INTEGER,ZOBJECT INTEGER); INSERT INTO ZOBJECT VALUES(1,1); INSERT INTO ZSTRUCTUREDMETADATA VALUES(1,1); INSERT INTO ZCUSTOMMETADATA VALUES(1,1); INSERT INTO ZKEYVALUE VALUES("setting","keep");'
    purge_knowledge_db "$db"; [ "$FAILED_COUNT" -eq 0 ]
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM ZOBJECT UNION ALL SELECT count(*) FROM ZCUSTOMMETADATA;')" = $'0\n0' ]
    [ "$(sqlite3 "$db" 'SELECT ZVALUE FROM ZKEYVALUE;')" = keep ]
)
printf 'PASS: KnowledgeC related event tables clear while key/value settings remain\n'
(
    setup processes
    TEST_MODE=0
    ps() { printf '%s\n' "$PROCESS"; }
    for PROCESS in /usr/sbin/usernoted /System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter; do
        if activity_store_idle /nonexistent notifications; then exit 1; fi
    done
    PROCESS=/usr/libexec/intelligenceplatformd
    if activity_store_idle /nonexistent events; then exit 1; fi
    PROCESS=/usr/libexec/knowledge-agent
    if activity_store_idle /nonexistent knowledge; then exit 1; fi
    ps() { return 1; }
    if activity_store_idle /nonexistent knowledge; then exit 1; fi
)
printf 'PASS: known service processes and failed process discovery block mutations\n'
(
    setup siri
    module_siri
    [ "$FAILED_COUNT" -eq 1 ]; [ "$CLEANED_COUNT" -eq 0 ]
    FAILED_COUNT=0; DRY_RUN=1; module_siri
    [ "$FAILED_COUNT" -eq 0 ]; [ "$CLEANED_COUNT" -eq 0 ]
    SELECTED_MODULES=''
    for name in notifications activity siri; do if module_selected "$name"; then exit 1; fi; done
    rc=0
    SHREDDER_ROOT="$SANDBOX" /bin/bash "$SHREDDER" --modules siri --force > "$WORK/siri.log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ]; grep -q 'Delete Siri & Dictation History' "$WORK/siri.log"
)
printf 'PASS: Siri guidance reports incomplete without host actions or a fake cleaned count\n'
(
    setup wal-lock
    db="$STORE_HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
    notifications "$db"
    sqlite3 "$db" <<SQL > "$WORK/writer.log" 2>&1 &
PRAGMA journal_mode=WAL;
BEGIN IMMEDIATE;
.shell touch "$WORK/writer-ready"
.shell sleep 3
ROLLBACK;
SQL
    writer=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [ ! -e "$WORK/writer-ready" ] || break
        sleep 0.02
    done
    [ -e "$WORK/writer-ready" ]
    module_notifications
    [ "$FAILED_COUNT" -eq 1 ]
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM record;')" -eq 3 ]
    wait "$writer"
    FAILED_COUNT=0; module_notifications; [ "$FAILED_COUNT" -eq 0 ]
    printf archive > "${db%/*}/db.corrupt"
    module_notifications; [ "$FAILED_COUNT" -eq 1 ]
    grep -q archive "${db%/*}/db.corrupt"
)
printf 'PASS: real WAL writer lock refuses cleanup; retry succeeds; unknown archives remain with incomplete status\n'
(
    setup no-sqlite
    db="$STORE_HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
    notifications "$db"
    command() { if [ "${2:-}" = sqlite3 ]; then return 1; fi; builtin command "$@"; }
    module_notifications; [ "$FAILED_COUNT" -eq 1 ]
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM record;')" -eq 3 ]
)
printf 'PASS: missing SQLite never removes the database\n'
