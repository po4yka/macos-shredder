#!/bin/bash
# Real SQLite databases and file stores inside marked temporary sandboxes.
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
}
put() { mkdir -p "${1%/*}"; printf '%s\n' "${2:-history-marker}" > "$1"; }
expect_status() {
    local expected="$1" rc=0
    shift
    /bin/bash "$SHREDDER" --modules shell "$@" > "$WORK/last.log" 2>&1 || rc=$?
    if [ "$rc" -ne "$expected" ]; then cat "$WORK/last.log"; printf 'expected %s, got %s\n' "$expected" "$rc"; return 1; fi
}
seed_atuin() {
    mkdir -p "$1"
    sqlite3 "$1/history.db" <<'SQL'
CREATE TABLE history(id TEXT PRIMARY KEY, timestamp INTEGER, duration INTEGER, exit INTEGER, command TEXT, cwd TEXT, session TEXT, hostname TEXT, deleted_at INTEGER);
CREATE TABLE events(id TEXT PRIMARY KEY, timestamp INTEGER, hostname TEXT, event_type TEXT, history_id TEXT);
CREATE TABLE _sqlx_migrations(version INTEGER PRIMARY KEY, description TEXT);
INSERT INTO history VALUES('id',1,2,0,'history-marker','/private/path','session','host',NULL);
INSERT INTO events VALUES('event',1,'host','history-marker','id');
INSERT INTO _sqlx_migrations VALUES(1,'keep');
SQL
    sqlite3 "$1/records.db" <<'SQL'
CREATE TABLE store(id TEXT PRIMARY KEY, idx INTEGER, host TEXT, tag TEXT, timestamp INTEGER, version TEXT, data BLOB, cek BLOB);
CREATE TABLE records(id TEXT PRIMARY KEY, parent TEXT, host TEXT, tag TEXT, timestamp INTEGER, version TEXT, data BLOB, cek BLOB);
CREATE TABLE _sqlx_migrations(version INTEGER PRIMARY KEY, description TEXT);
INSERT INTO store VALUES('history',1,'host','history',1,'v1','history-marker','key-material');
INSERT INTO store VALUES('alias',1,'host','config-shell-alias',1,'v1',X'000102FF',X'AABB');
INSERT INTO store VALUES('kv',1,'host','kv',1,'v1','keep-kv','keep-key');
INSERT INTO store VALUES('script',1,'host','script',1,'v1','keep-script','keep-key');
INSERT INTO store VALUES('history-pack',1,'host','packfile',1,'v1','001{"host":"host","tag":"history","start_idx":1,"end_idx":2}','');
INSERT INTO store VALUES('config-pack',2,'host','packfile',1,'v1','001{"host":"host","tag":"kv","start_idx":1,"end_idx":2}','');
INSERT INTO records VALUES('legacy',NULL,'host','history',1,'v1','history-marker','key-material');
INSERT INTO records VALUES('other',NULL,'host','kv',1,'v1','keep-kv','keep-key');
INSERT INTO _sqlx_migrations VALUES(1,'keep');
SQL
    put "$1/key" keep-key
    put "$1/session" keep-session
    put "$1/host_id" keep-host
    put "$1/config.toml" keep-config
}

test_atuin() (
    setup atuin
    local root
    for root in "$STORE_HOME/.local/share/atuin" "$STORE_HOME/.atuin/data"; do seed_atuin "$root"; done
    cp -R "$SANDBOX" "$WORK/before"
    expect_status 0 --dry-run --debug
    diff -r "$WORK/before" "$SANDBOX"
    expect_status 0 --force
    for root in "$STORE_HOME/.local/share/atuin" "$STORE_HOME/.atuin/data"; do
        [ "$(sqlite3 "$root/history.db" 'SELECT count(*) FROM history; SELECT count(*) FROM events;')" = $'0\n0' ]
        [ "$(sqlite3 "$root/records.db" 'SELECT count(*) FROM store; SELECT count(*) FROM records;')" = $'4\n1' ]
        [ "$(sqlite3 "$root/records.db" "SELECT hex(data)||':'||hex(cek) FROM store WHERE id='alias';")" = 000102FF:AABB ]
        [ "$(sqlite3 "$root/records.db" 'PRAGMA integrity_check;')" = ok ]
        [ "$(sqlite3 "$root/history.db" 'SELECT description FROM _sqlx_migrations;')" = keep ]
        if grep -a -q history-marker "$root/history.db" "$root/records.db"; then exit 1; fi
        grep -q keep-key "$root/key"
        grep -q keep-session "$root/session"
        grep -q keep-host "$root/host_id"
        grep -q keep-config "$root/config.toml"
    done
    expect_status 0 --force
)
test_atuin
printf 'PASS: Atuin local/history records and pack manifests cleared; auth/configuration preserved\n'

test_atuin_analyzed() (
    setup atuin-analyzed
    local root="$STORE_HOME/.local/share/atuin"
    seed_atuin "$root"
    # ANALYZE adds sqlite_stat1, which has no tag column.
    sqlite3 "$root/records.db" 'CREATE INDEX store_tag ON store(tag); ANALYZE;'
    sqlite3 "$root/history.db" 'CREATE INDEX history_cwd ON history(cwd); ANALYZE;'
    expect_status 0 --force
    [ "$(sqlite3 "$root/records.db" 'SELECT count(*) FROM store; SELECT count(*) FROM records;')" = $'4\n1' ]
    [ "$(sqlite3 "$root/history.db" 'SELECT count(*) FROM history;')" = 0 ]
)
test_atuin_analyzed
printf 'PASS: analyzed Atuin databases are cleaned\n'

test_alternatives() (
    setup alternatives
    local entry root
    for entry in '.local/share/fish/fish_history' '.local/share/fish/work_history' '.config/fish/old_history' \
        'Library/Application Support/nushell/history.txt' '.config/nushell/history.txt' \
        '.local/share/xonsh/history_json/xonsh-session.json' '.local/share/xonsh/xonsh-old.json' \
        'Library/Application Support/zoxide/db.zo' 'Library/Application Support/zoxide/db.txt' '.local/share/zoxide/db.zo' \
        '.fasd' '.z' '.ipython/profile_work/history.sqlite' '.ipython/profile_work/history.sqlite-wal'; do
        put "$STORE_HOME/$entry"
    done
    for entry in '.config/fish/config.fish' '.local/share/fish/fish_variables' \
        'Library/Application Support/nushell/config.nu' '.config/nushell/env.nu' \
        '.local/share/xonsh/config.json' '.local/share/xonsh/history_json/notes.json' \
        '.fasdrc' '.zshrc' '.ipython/profile_work/ipython_config.py'; do put "$STORE_HOME/$entry" keep; done
    for root in "$STORE_HOME/Library/Application Support/nushell" "$STORE_HOME/.config/nushell"; do
        sqlite3 "$root/history.sqlite3" 'CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, command_line TEXT); INSERT INTO history(command_line) VALUES("history-marker");'
    done
    sqlite3 "$STORE_HOME/.local/share/xonsh/xonsh-history.sqlite" 'CREATE TABLE xonsh_history(inp TEXT, rtn INTEGER, tsb REAL, tse REAL, sessionid TEXT, out TEXT, info TEXT, frequency INTEGER); INSERT INTO xonsh_history(inp,out) VALUES("history-marker","history-marker");'
    mkdir -p "$STORE_HOME/.histdb"
    sqlite3 "$STORE_HOME/.histdb/zsh-history.db" 'CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, command_id INTEGER, place_id INTEGER); CREATE TABLE commands(id INTEGER PRIMARY KEY, argv TEXT); CREATE TABLE places(id INTEGER PRIMARY KEY,host TEXT,dir TEXT); INSERT INTO history VALUES(1,1,1); INSERT INTO commands VALUES(1,"history-marker"); INSERT INTO places VALUES(1,"host","history-marker");'
    expect_status 0 --force
    if grep -R -a -l history-marker "$STORE_HOME"; then exit 1; fi
    for entry in '.config/fish/config.fish' '.local/share/fish/fish_variables' \
        'Library/Application Support/nushell/config.nu' '.config/nushell/env.nu' \
        '.local/share/xonsh/config.json' '.local/share/xonsh/history_json/notes.json' \
        '.fasdrc' '.zshrc' '.ipython/profile_work/ipython_config.py'; do grep -q keep "$STORE_HOME/$entry"; done
    expect_status 0 --force
)
test_alternatives
printf 'PASS: fish, Nushell, Xonsh, histdb, directory jump stores and all IPython profiles\n'

test_failures() (
    setup failures
    local root="$STORE_HOME/.local/share/atuin" before
    seed_atuin "$root"
    before="$(shasum "$root/history.db")"
    sqlite3 "$root/records.db" 'CREATE TABLE unknown_settings(secret TEXT); INSERT INTO unknown_settings VALUES("keep");'
    expect_status 2 --force
    [ "$(shasum "$root/history.db")" = "$before" ]
    [ "$(sqlite3 "$root/records.db" 'SELECT count(*) FROM store;')" = 6 ]
    sqlite3 "$root/records.db" 'DROP TABLE unknown_settings; CREATE TRIGGER unsafe AFTER DELETE ON store BEGIN DELETE FROM records; END;'
    expect_status 2 --force
    [ "$(shasum "$root/history.db")" = "$before" ]
    [ "$(sqlite3 "$root/records.db" 'SELECT count(*) FROM records;')" = 2 ]
    sqlite3 "$root/records.db" "DROP TRIGGER unsafe; UPDATE store SET data='002unknown' WHERE id='history-pack';"
    expect_status 2 --force
    [ "$(sqlite3 "$root/records.db" 'SELECT count(*) FROM store;')" = 6 ]
    [ "$(shasum "$root/history.db")" = "$before" ]
    # A late format error must roll back an earlier DELETE in the same file.
    sqlite3 "$root/records.db" "UPDATE store SET data='001{\"tag\":\"history\"}' WHERE id='history-pack'; INSERT INTO records VALUES('bad-pack',NULL,'host','packfile',1,'v1','002unknown','');"
    if shell_purge_database "$root/records.db" atuin-records 2>/dev/null; then exit 1; fi
    [ "$(sqlite3 "$root/records.db" 'SELECT count(*) FROM store;')" = 6 ]
    [ "$(sqlite3 "$root/records.db" 'SELECT count(*) FROM records;')" = 3 ]
)
test_failures
printf 'PASS: unknown schema, triggers and unsupported pack versions retain both Atuin stores\n'

test_links() (
    setup links
    local root="$STORE_HOME/.local/share/atuin"
    seed_atuin "$root"
    put "$WORK/sentinel" keep
    ln -s "$WORK/sentinel" "$root/records.db-wal"
    expect_status 2 --force
    grep -q keep "$WORK/sentinel"
    [ "$(sqlite3 "$root/history.db" 'SELECT count(*) FROM history;')" = 1 ]
    rm "$root/records.db-wal"
    ln "$root/history.db" "$WORK/hardlink.db"
    expect_status 2 --force
    [ "$(sqlite3 "$WORK/hardlink.db" 'SELECT count(*) FROM history;')" = 1 ]
    rm "$WORK/hardlink.db"
    mkdir -p "$WORK/elsewhere"
    put "$WORK/elsewhere/history.txt" keep
    mkdir -p "$STORE_HOME/.config"
    ln -s "$WORK/elsewhere" "$STORE_HOME/.config/nushell"
    expect_status 2 --force
    grep -q keep "$WORK/elsewhere/history.txt"
    mkdir -p "$STORE_HOME/.fasd"
    put "$STORE_HOME/.fasd/important" keep
    expect_status 2 --force
    grep -q keep "$STORE_HOME/.fasd/important"
)
test_links
printf 'PASS: database hardlinks, linked sidecars/parents and unexpected directories retained\n'

test_process_guard() (
    setup processes
    TEST_MODE=0
    ps() { printf '%s\n' "$PROCESS_LINE"; }
    local name
    for name in atuin fish nu xonsh ipython; do
        PROCESS_LINE="/opt/homebrew/bin/$name daemon"
        if shell_stores_stopped; then exit 1; fi
    done
    for PROCESS_LINE in '/opt/homebrew/bin/python3 -m ipykernel_launcher -f kernel.json' \
        '/opt/homebrew/bin/python3 /opt/homebrew/bin/jupyter-lab'; do
        if shell_stores_stopped; then exit 1; fi
    done
    PROCESS_LINE='/bin/bash shredder.sh --modules shell --force'
    shell_stores_stopped
    ps() { return 1; }
    if shell_stores_stopped; then exit 1; fi
)
test_process_guard
printf 'PASS: active history clients and failed process queries refuse extended cleanup\n'
