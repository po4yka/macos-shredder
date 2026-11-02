#!/bin/bash
# AI cleanup acceptance tests. Never open the host's agent stores.
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
    AI_HOME="$USERS_DIR/User Space"
}

put() { mkdir -p "${1%/*}"; printf '%s\n' "${2:-session-marker}" > "$1"; }
expect_status() {
    local expected="$1" rc=0
    shift
    /bin/bash "$SHREDDER" "$@" > "$WORK/last.log" 2>&1 || rc=$?
    if [ "$rc" -ne "$expected" ]; then cat "$WORK/last.log"; printf 'expected %s, got %s\n' "$expected" "$rc"; return 1; fi
}

seed() {
    local h="$1" item
    for item in \
        .claude/projects/project/11111111-1111-1111-1111-111111111111.jsonl \
        .claude/projects/project/11111111-1111-1111-1111-111111111111/subagents/agent.jsonl \
        .claude/projects/project/11111111-1111-1111-1111-111111111111/tool-results/result.txt \
        .claude/projects/project/old.jsonl.superseded-123 .claude/projects/project/sessions-index.json \
        .claude/history.jsonl .claude/file-history/session/file .claude/paste-cache/paste \
        .claude/tasks/session/task .claude/debug/session.log .claude/shell-snapshots/shell \
        .codex/sessions/2026/session.jsonl .codex/archived_sessions/session.jsonl \
        .codex/history.jsonl .codex/session_index.jsonl .codex/attachments/image \
        .codex/shell_snapshots/shell .codex/log/log .codex/dictation-history/audio \
        '.local/share/opencode/storage/session/project/session.json' \
        '.local/share/opencode/storage/message/session/message.json' \
        '.local/share/opencode/storage/part/message/part.json' \
        .local/share/opencode/tool-output/result .local/share/opencode/snapshot/repo/object \
        .local/share/opencode/log/log .local/state/opencode/prompt-history.jsonl \
        .local/state/opencode/session.json 'Library/Logs/com.openai.codex/date/app.log'; do put "$h/$item"; done
    for item in .claude/settings.json .claude/.credentials.json .claude/skills/custom/SKILL.md \
        .claude/projects/project/memory/MEMORY.md .claude/plans/plan.md \
        .codex/auth.json .codex/config.toml .codex/skills/custom/SKILL.md \
        .codex/worktrees/work/edited.txt .codex/memories_v2/memory.md .codex/plans/plan.md \
        .codex/artifacts/result .codex/memories-backup.tgz \
        .local/share/opencode/auth.json .local/share/opencode/mcp-auth.json \
        .local/share/opencode/storage/project/project.json .local/share/opencode/repos/work/edited.txt \
        .config/opencode/opencode.json .local/state/opencode/model.json; do put "$h/$item" keep; done
    put "$h/.codex/.codex-global-state.json" '{"theme":"dark","thread-titles":{"t":"session-marker"},"electron-persisted-atom-state":{"prompt-history":["session-marker"],"composer-prompt-drafts-v1":{"p":"session-marker"},"sidebar-width":200}}'
    cp "$h/.codex/.codex-global-state.json" "$h/.codex/.codex-global-state.json.bak"
    put "$h/.claude.json" '{"oauthAccount":{"fixture":"keep"},"projects":{"/project":{"history":["session-marker"],"lastSessionId":"session-marker","allowedTools":["keep"]}}}'
    mkdir -p "$h/.codex/sqlite"
    sqlite3 "$h/.codex/state_5.sqlite" <<'SQL'
CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT);
CREATE TABLE thread_dynamic_tools(thread_id TEXT REFERENCES threads(id) ON DELETE CASCADE, input_schema TEXT);
CREATE TABLE projects(id TEXT PRIMARY KEY, metadata TEXT);
CREATE TABLE remote_control_enrollments(account_id TEXT);
INSERT INTO threads VALUES('t','session-marker');
INSERT INTO thread_dynamic_tools VALUES('t','session-marker');
INSERT INTO projects VALUES('p','keep');
INSERT INTO remote_control_enrollments VALUES('keep');
SQL
    sqlite3 "$h/.codex/thread_history_1.sqlite" 'CREATE TABLE thread_items(item_json TEXT); INSERT INTO thread_items VALUES("session-marker");'
    sqlite3 "$h/.codex/logs_2.sqlite" 'CREATE TABLE logs(feedback_log_body TEXT); INSERT INTO logs VALUES("session-marker");'
    sqlite3 "$h/.codex/goals_1.sqlite" 'CREATE TABLE thread_goals(objective TEXT); INSERT INTO thread_goals VALUES("session-marker");'
    sqlite3 "$h/.codex/queue_1.sqlite" 'CREATE TABLE queued_items(payload_json TEXT); INSERT INTO queued_items VALUES("session-marker");'
    sqlite3 "$h/.codex/memories_1.sqlite" 'CREATE TABLE stage1_outputs(raw_memory TEXT); INSERT INTO stage1_outputs VALUES("keep");'
    sqlite3 "$h/.codex/sqlite/codex.db" 'CREATE TABLE automation_runs(archived_user_message TEXT); INSERT INTO automation_runs VALUES("session-marker"); CREATE TABLE automations(prompt TEXT); INSERT INTO automations VALUES("keep");'
    sqlite3 "$h/.codex/sqlite/codex-thread-summaries.db" 'CREATE TABLE thread_turn_summaries(summary TEXT); INSERT INTO thread_turn_summaries VALUES("session-marker");'
    sqlite3 "$h/.local/share/opencode/opencode.db" <<'SQL'
CREATE TABLE project(id TEXT PRIMARY KEY, worktree TEXT);
CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, project_id TEXT REFERENCES project(id));
CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT REFERENCES session(id) ON DELETE CASCADE, data TEXT);
CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT REFERENCES message(id) ON DELETE CASCADE, data TEXT);
CREATE TABLE session_v2(id TEXT PRIMARY KEY, title TEXT);
CREATE TABLE session_message(id TEXT PRIMARY KEY, session_id TEXT REFERENCES session_v2(id) ON DELETE CASCADE, data TEXT);
CREATE TABLE instruction_blob(hash TEXT PRIMARY KEY, value TEXT);
CREATE TABLE blob(hash TEXT PRIMARY KEY, data BLOB);
CREATE TABLE event(aggregate_id TEXT, data TEXT);
CREATE TABLE event_sequence(aggregate_id TEXT, seq INTEGER);
CREATE TABLE credential(id TEXT, value TEXT);
CREATE TABLE account(id TEXT, access_token TEXT);
CREATE TABLE permission(id TEXT, action TEXT);
CREATE TABLE schedule(id TEXT, session_id TEXT REFERENCES session_v2(id) ON DELETE CASCADE, action TEXT);
INSERT INTO project VALUES('p','keep');
INSERT INTO session VALUES('s','session-marker','p');
INSERT INTO message VALUES('m','s','session-marker');
INSERT INTO part VALUES('part','m','session-marker');
INSERT INTO session_v2 VALUES('s2','session-marker');
INSERT INTO session_message VALUES('m2','s2','session-marker');
INSERT INTO instruction_blob VALUES('i','session-marker');
INSERT INTO blob VALUES('b','session-marker');
INSERT INTO event VALUES('s2','session-marker');
INSERT INTO event VALUES('ses_orphan','session-marker');
INSERT INTO event VALUES('configuration','keep');
INSERT INTO event_sequence VALUES('s2',1);
INSERT INTO event_sequence VALUES('configuration',1);
INSERT INTO credential VALUES('c','keep');
INSERT INTO account VALUES('a','keep');
INSERT INTO permission VALUES('p','keep');
INSERT INTO schedule VALUES('session-task','s2','session-marker');
INSERT INTO schedule VALUES('standalone-task',NULL,'keep');
SQL
}

test_cleanup() (
    setup cleanup
    seed "$AI_HOME"
    cp -R "$SANDBOX" "$WORK/before"
    expect_status 0 --modules ai --dry-run --debug
    diff -r "$WORK/before" "$SANDBOX"
    expect_status 0 --modules apps --force
    [ -s "$AI_HOME/.codex/history.jsonl" ]
    expect_status 0 --modules ai --force --debug
    # No session marker may survive in files or database free pages.
    if grep -R -a -l session-marker "$AI_HOME"; then exit 1; fi
    local item
    for item in .claude/settings.json .claude/.credentials.json .claude/skills/custom/SKILL.md \
        .claude/projects/project/memory/MEMORY.md .claude/plans/plan.md \
        .codex/auth.json .codex/config.toml .codex/worktrees/work/edited.txt .codex/memories_v2/memory.md \
        .codex/plans/plan.md .codex/artifacts/result .codex/memories-backup.tgz \
        .local/share/opencode/auth.json .local/share/opencode/mcp-auth.json \
        .local/share/opencode/repos/work/edited.txt .local/share/opencode/storage/project/project.json \
        .local/state/opencode/model.json .config/opencode/opencode.json; do
        cmp "$WORK/before/Users/User Space/$item" "$AI_HOME/$item"
    done
    [ "$(sqlite3 "$AI_HOME/.codex/state_5.sqlite" 'SELECT metadata FROM projects; SELECT account_id FROM remote_control_enrollments;')" = $'keep\nkeep' ]
    [ "$(sqlite3 "$AI_HOME/.local/share/opencode/opencode.db" 'SELECT value FROM credential; SELECT access_token FROM account; SELECT action FROM permission; SELECT action FROM schedule;')" = $'keep\nkeep\nkeep\nkeep' ]
    [ "$(sqlite3 "$AI_HOME/.local/share/opencode/opencode.db" 'SELECT data FROM event; SELECT aggregate_id FROM event_sequence;')" = $'keep\nconfiguration' ]
    (cd "$AI_HOME/.codex" && [ "$(sqlite3 :memory: "SELECT json_extract(CAST(readfile('.codex-global-state.json') AS TEXT),'$.theme');")" = dark ])
    (cd "$AI_HOME" && [ "$(sqlite3 :memory: "SELECT json_extract(CAST(readfile('.claude.json') AS TEXT),'$.oauthAccount.fixture');")" = keep ])
    [ "$(sqlite3 "$AI_HOME/.local/share/opencode/opencode.db" 'PRAGMA integrity_check;')" = ok ]
    [ -z "$(sqlite3 "$AI_HOME/.local/share/opencode/opencode.db" 'PRAGMA foreign_key_check;')" ]
    expect_status 0 --modules ai --force --ai-derived
    [ ! -e "$AI_HOME/.claude/projects/project/memory" ]
    [ ! -e "$AI_HOME/.codex/memories_v2" ]
    [ ! -e "$AI_HOME/.codex/memories-backup.tgz" ]
    [ ! -e "$AI_HOME/.codex/artifacts" ]
    [ "$(sqlite3 "$AI_HOME/.codex/memories_1.sqlite" 'SELECT count(*) FROM stage1_outputs;')" = 0 ]
    expect_status 0 --modules ai --force --ai-derived
)
test_cleanup
printf 'PASS: AI sessions, archives, indexes, JSON and derived data; settings and credentials preserved\n'

test_custom_roots() (
    setup custom
    put "$AI_HOME/custom claude/history.jsonl"
    put "$AI_HOME/custom state/prompt-history.jsonl"
    put "$AI_HOME/custom temp/project/session/images/image.png"
    put "$AI_HOME/custom code/sessions/session.jsonl"
    put "$AI_HOME/custom code/auth.json" keep
    sqlite3 "$AI_HOME/custom.db" 'CREATE TABLE session(id TEXT); INSERT INTO session VALUES("session-marker");'
    expect_status 0 --modules ai --force \
        --ai-root 'claude=/Users/User Space/custom claude' \
        --ai-root 'opencode-state=/Users/User Space/custom state' \
        --ai-root 'claude-temp=/Users/User Space/custom temp' \
        --ai-root 'codex=/Users/User Space/custom code' \
        --ai-root 'opencode-db=/Users/User Space/custom.db'
    [ ! -e "$AI_HOME/custom claude/history.jsonl" ]
    [ ! -e "$AI_HOME/custom state/prompt-history.jsonl" ]
    [ -z "$(find "$AI_HOME/custom temp" -type f -print)" ]
    [ ! -e "$AI_HOME/custom code/sessions" ]
    [ -s "$AI_HOME/custom code/auth.json" ]
    [ "$(sqlite3 "$AI_HOME/custom.db" 'SELECT count(*) FROM session;')" = 0 ]
    expect_status 64 --modules ai --force --ai-root 'claude=/Users/User Space/../outside'
    expect_status 64 --modules ai --force --ai-root 'claude=/tmp/other'
    expect_status 64 --modules ai --force --ai-root 'unknown=/Users/User Space/custom'
    expect_status 2 --modules ai --force --ai-root 'claude=/Users/absent/custom'
)
test_custom_roots
printf 'PASS: custom AI roots, spaces, sandbox mapping and input rejection\n'

test_database_refusal() (
    setup refusal
    local db="$AI_HOME/.codex/state_5.sqlite"
    put "$AI_HOME/.codex/sessions/keep.jsonl"
    sqlite3 "$db" 'CREATE TABLE threads(id TEXT); INSERT INTO threads VALUES("session-marker"); CREATE TABLE unknown(data TEXT);'
    cp "$db" "$WORK/unknown.sqlite"
    expect_status 2 --modules ai --force
    cmp "$db" "$WORK/unknown.sqlite"
    [ -s "$AI_HOME/.codex/sessions/keep.jsonl" ]
    sqlite3 "$db" 'DROP TABLE unknown; CREATE TRIGGER deny_delete BEFORE DELETE ON threads BEGIN SELECT RAISE(ABORT,"keep"); END;'
    expect_status 2 --modules ai --force
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM threads;')" = 1 ]
    [ -s "$AI_HOME/.codex/sessions/keep.jsonl" ]
    printf 'broken database\n' > "$db"
    expect_status 2 --modules ai --force
    grep -q '^broken database$' "$db"
    [ -s "$AI_HOME/.codex/sessions/keep.jsonl" ]
    # Missing SQLite cannot fall back to deleting a mixed database.
    # shellcheck disable=SC2329
    command() { if [ "${2:-}" = sqlite3 ]; then return 1; fi; builtin command "$@"; }
    if ai_purge_database "$db" state; then exit 1; fi
)
test_database_refusal
printf 'PASS: unsupported/corrupt schemas, triggers and absent SQLite preserve sessions\n'

test_links() (
    setup links
    put "$WORK/outside/history.jsonl" keep
    ln -s "$WORK/outside" "$AI_HOME/.claude"
    expect_status 2 --modules ai --force
    grep -q keep "$WORK/outside/history.jsonl"
    mkdir -p "$AI_HOME/.codex"
    sqlite3 "$WORK/outside.sqlite" 'CREATE TABLE threads(id TEXT); INSERT INTO threads VALUES("keep");'
    ln -s "$WORK/outside.sqlite" "$AI_HOME/.codex/state_5.sqlite"
    expect_status 2 --modules ai --force
    rm "$AI_HOME/.codex/state_5.sqlite"
    ln "$WORK/outside.sqlite" "$AI_HOME/.codex/state_5.sqlite"
    expect_status 2 --modules ai --force
    [ "$(sqlite3 "$WORK/outside.sqlite" 'SELECT id FROM threads;')" = keep ]
    rm "$AI_HOME/.codex/state_5.sqlite"
    cp "$WORK/outside.sqlite" "$AI_HOME/.codex/state_5.sqlite"
    ln -s "$WORK/outside/history.jsonl" "$AI_HOME/.codex/state_5.sqlite-wal"
    expect_status 2 --modules ai --force
    grep -q keep "$WORK/outside/history.jsonl"
)
test_links
printf 'PASS: AI root, database, WAL symlinks and database hard links are refused\n'

test_process_guard() (
    setup processes
    TEST_MODE=0
    local executable
    for executable in '/usr/local/bin/claude --resume' '/usr/bin/node /pkg/codex.js' '/Applications/Codex.app/Contents/MacOS/Codex' '/bin/opencode serve'; do
        # shellcheck disable=SC2329
        ps() { printf '%s\n' "$executable"; }
        if ai_agents_stopped; then exit 1; fi
    done
    # shellcheck disable=SC2329
    ps() { return 1; }
    if ai_agents_stopped; then exit 1; fi
    # shellcheck disable=SC2329
    ps() { printf '/bin/bash shredder.sh --modules ai\n'; }
    ai_agents_stopped
)
test_process_guard
printf 'PASS: CLI, Node launcher, desktop, background server and process-query failure guard\n'

test_scratchpads() (
    setup scratchpads
    local uid root
    uid="$(id -u)"
    root="$SANDBOX/private/tmp/claude-$uid"
    put "$root/project/session/scratchpad/draft"
    put "$root/project/session/images/image"
    DRY_RUN=1
    ai_claude_temp "$AI_HOME" "$uid"
    [ -s "$root/project/session/scratchpad/draft" ]
    DRY_RUN=0
    ai_claude_temp "$AI_HOME" "$uid"
    [ "$FAILED_COUNT" -eq 0 ]
    [ -z "$(find "$root" -type f -print)" ]
    rmdir "$root"
    ln -s "$WORK/outside" "$root"
    ai_claude_temp "$AI_HOME" "$uid"
    [ "$FAILED_COUNT" -eq 1 ]
    grep -q keep "$WORK/outside/history.jsonl"
)
test_scratchpads
printf 'PASS: Claude scratchpads use the home owner and refuse symlink escapes\n'

test_wal_and_lock() (
    setup wal
    local db="$AI_HOME/.codex/state_5.sqlite" pid attempt=0
    put "$AI_HOME/.codex/sessions/session.jsonl"
    # Keep a real connection open so the committed record lives in WAL, then
    # hold a writer lock. The cleaner must see the record and refuse the lock.
    mkfifo "$WORK/sql-input"
    sqlite3 "$db" < "$WORK/sql-input" > "$WORK/sql-output" 2>&1 &
    pid=$!
    trap 'exec 3>&-; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
    exec 3> "$WORK/sql-input"
    printf '%s\n' 'PRAGMA journal_mode=WAL;' 'CREATE TABLE threads(id TEXT);' \
        'INSERT INTO threads VALUES("session-marker");' 'BEGIN IMMEDIATE;' '.print ready' >&3
    until grep -q ready "$WORK/sql-output"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 200 ] || exit 1
        sleep 0.01
    done
    [ -s "$db-wal" ]
    cp -R "$SANDBOX" "$WORK/wal-before"
    expect_status 0 --modules ai --dry-run
    diff -r "$WORK/wal-before" "$SANDBOX"
    expect_status 2 --modules ai --force
    [ -s "$AI_HOME/.codex/sessions/session.jsonl" ]
    [ "$(sqlite3 "$db" 'SELECT id FROM threads;')" = session-marker ]
    printf '%s\n' 'COMMIT;' '.quit' >&3
    exec 3>&-
    wait "$pid"
    trap - EXIT
    expect_status 0 --modules ai --force
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM threads;')" = 0 ]
    [ ! -s "$db-wal" ]
    [ ! -e "$AI_HOME/.codex/sessions" ]
    put "$AI_HOME/.codex/unknown.sqlite-wal" keep
    expect_status 2 --modules ai --force
    [ -s "$AI_HOME/.codex/unknown.sqlite-wal" ]
)
test_wal_and_lock
printf 'PASS: real WAL dry-run stability, writer-lock refusal and successful retry\n'

test_json_errors_and_defaults() (
    setup json
    put "$AI_HOME/.codex/.codex-global-state.json" '{invalid'
    expect_status 2 --modules ai --force
    grep -q invalid "$AI_HOME/.codex/.codex-global-state.json"
    put "$AI_HOME/.codex/.codex-global-state.json" '["keep"]'
    expect_status 2 --modules ai --force
    grep -q keep "$AI_HOME/.codex/.codex-global-state.json"
    rm "$AI_HOME/.codex/.codex-global-state.json"
    put "$WORK/json-outside" '{"prompt-history":["keep"]}'
    ln "$WORK/json-outside" "$AI_HOME/.codex/.codex-global-state.json"
    expect_status 2 --modules ai --force
    grep -q keep "$WORK/json-outside"
    rm "$AI_HOME/.codex/.codex-global-state.json"
    ln -s "$WORK/json-outside" "$AI_HOME/.codex/.codex-global-state.json"
    expect_status 2 --modules ai --force
    grep -q keep "$WORK/json-outside"
    rm "$AI_HOME/.codex/.codex-global-state.json"
    put "$AI_HOME/.claude/history.jsonl"
    put "$USERS_DIR/alice/.codex/archived_sessions/session.jsonl"
    expect_status 0 --force
    [ ! -e "$AI_HOME/.claude/history.jsonl" ]
    [ ! -e "$USERS_DIR/alice/.codex/archived_sessions" ]
)
test_json_errors_and_defaults
printf 'PASS: malformed/hard-linked JSON retained; default modules clean both users\n'

test_environment_roots() (
    setup environment
    unset CLAUDE_CONFIG_DIR CODEX_HOME CODEX_SQLITE_HOME XDG_DATA_HOME XDG_STATE_HOME OPENCODE_DB CLAUDE_CODE_TMPDIR
    unset CONTINUE_GLOBAL_DIR CLINE_DATA_DIR CLINE_DIR AIDER_CHAT_HISTORY_FILE AIDER_INPUT_HISTORY_FILE AIDER_LLM_HISTORY_FILE
    CLAUDE_CONFIG_DIR='/Users/User Space/custom claude'
    CODEX_HOME='/Users/User Space/custom code'
    CODEX_SQLITE_HOME='/Users/User Space/database'
    XDG_DATA_HOME='/Users/User Space/data'
    XDG_STATE_HOME='/Users/User Space/state'
    OPENCODE_DB='channel.db'
    CLAUDE_CODE_TMPDIR='/tmp/custom'
    # Sandbox runs must ignore host storage overrides.
    ai_environment_roots
    [ "${#AI_ROOTS[@]}" -eq 0 ]
    TEST_MODE=0
    ai_environment_roots
    [ "${#AI_ROOTS[@]}" -eq 6 ]
    [ "${AI_ROOTS[0]}" = 'claude=/Users/User Space/custom claude' ]
    [ "${AI_ROOTS[5]}" = 'opencode-db=/Users/User Space/data/opencode/channel.db' ]
    [ "$AI_CLAUDE_TMP_BASE" = /private/tmp/custom ]
)
test_environment_roots
printf 'PASS: environment overrides resolve paths and are ignored in sandbox mode\n'

test_statement_failure_rollback() (
    setup statement_failure
    local db="$AI_HOME/transaction.db" sqlite_bin selected
    selected="$(command -v sqlite3)"
    # Test the native macOS CLI as well when PATH selects a different build.
    for sqlite_bin in "$selected" /usr/bin/sqlite3; do
        [ -x "$sqlite_bin" ] || continue
        rm -f "$db"
        "$sqlite_bin" "$db" 'CREATE TABLE preserved(value TEXT); INSERT INTO preserved VALUES("keep");'
        if ai_sqlite_command "$db" "$sqlite_bin" 'BEGIN IMMEDIATE; CREATE TEMP TABLE safe(ok INTEGER CHECK(ok=1)); INSERT INTO safe VALUES(0); DELETE FROM preserved; COMMIT;' > "$WORK/transaction.log" 2>&1; then
            printf 'failed CHECK unexpectedly succeeded: %s\n' "$sqlite_bin"
            exit 1
        fi
        [ "$("$sqlite_bin" "$db" 'SELECT value FROM preserved;')" = keep ]
        [ "$("$sqlite_bin" "$db" 'PRAGMA integrity_check;')" = ok ]
    done
)
test_statement_failure_rollback
printf 'PASS: failed SQL statements stop before downstream DELETE and COMMIT\n'
