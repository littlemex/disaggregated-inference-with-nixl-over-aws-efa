#!/bin/bash
# Generic Task Runner (汎用タスク実行エンジン)
#
# 設計思想:
#   このスクリプトは JSON タスク定義を読み込んで実行する汎用エンジンです。
#   環境セットアップ、実験測定、データ収集など、すべてのリモート実行タスクは
#   JSON で定義し、このスクリプトで実行します。
#
# 重要:
#   - このスクリプト自体は編集しない
#   - 新しいタスクが必要な場合は tasks/*.json を追加する
#   - タスク実行専用のスクリプト（例: ex11_runner.sh）は作成しない
#
# 詳細は setup/DESIGN.md および .claude/rules/task-runner-design.md を参照

set -e

TASKS_FILE="${1:?Usage: $0 <tasks.json> [--from <task-id>] [--reset]}"
STATE_FILE="/tmp/task-state-$(hostname).json"
FROM_TASK=""
RESET_STATE=false

# 引数パース
shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) FROM_TASK="$2"; shift 2 ;;
        --reset) RESET_STATE=true; shift ;;
        *) echo "[ERROR] Unknown option: $1"; exit 1 ;;
    esac
done

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# jq が必要
command -v jq >/dev/null 2>&1 || { log "[ERROR] jq is required"; exit 1; }

# 変数テンプレートの展開
expand_variables() {
    local text="$1"
    local variables
    local key value
    variables=$(jq -r '.variables // {} | to_entries[] | "\(.key)=\(.value)"' "$TASKS_FILE")

    local OLD_IFS="$IFS"
    IFS='='
    while read -r key value; do
        text="${text//\{\{$key\}\}/$value}"
    done <<< "$variables"
    IFS="$OLD_IFS"

    echo "$text"
}

# 状態管理ファイルの初期化
init_state() {
    if [ "$RESET_STATE" = true ]; then
        log "[INFO] Resetting state file: $STATE_FILE"
        rm -f "$STATE_FILE"
    fi

    if [ ! -f "$STATE_FILE" ]; then
        echo '{}' > "$STATE_FILE"
    fi
}

# タスクの状態取得
get_task_status() {
    local task_id="$1"
    jq -r --arg id "$task_id" '.[$id].status // "pending"' "$STATE_FILE"
}

# タスクの状態更新
update_task_status() {
    local task_id="$1"
    local status="$2"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    jq --arg id "$task_id" --arg status "$status" --arg ts "$timestamp" \
        '.[$id] = {"status": $status, "timestamp": $ts}' "$STATE_FILE" > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# メイン実行
init_state

TASK_COUNT=$(jq '.tasks | length' "$TASKS_FILE")
SKIP_UNTIL_FOUND=false

if [ -n "$FROM_TASK" ]; then
    SKIP_UNTIL_FOUND=true
fi

log "[START] Task suite: $(jq -r '.name' "$TASKS_FILE")"
log "[INFO] Tasks: $TASK_COUNT, State file: $STATE_FILE"

COMPLETED=0
SKIPPED=0
FAILED=0

for i in $(seq 0 $((TASK_COUNT - 1))); do
    TASK_ID=$(jq -r ".tasks[$i].id" "$TASKS_FILE")
    TASK_NAME=$(jq -r ".tasks[$i].name" "$TASKS_FILE")
    SKIP_IF=$(jq -r ".tasks[$i].skip_if // empty" "$TASKS_FILE")

    # --from オプション処理
    if [ "$SKIP_UNTIL_FOUND" = true ]; then
        if [ "$TASK_ID" = "$FROM_TASK" ]; then
            SKIP_UNTIL_FOUND=false
        else
            log "[SKIP] $TASK_ID: $TASK_NAME (before --from)"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    # 完了済みタスクのスキップ
    STATUS=$(get_task_status "$TASK_ID")
    if [ "$STATUS" = "success" ]; then
        log "[SKIP] $TASK_ID: $TASK_NAME (already completed)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # skip_if 条件の評価
    if [ -n "$SKIP_IF" ]; then
        EXPANDED_SKIP=$(expand_variables "$SKIP_IF")
        if eval "$EXPANDED_SKIP" 2>/dev/null; then
            log "[SKIP] $TASK_ID: $TASK_NAME (condition met)"
            update_task_status "$TASK_ID" "success"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    # タスク実行
    log "[RUN] $TASK_ID: $TASK_NAME"
    update_task_status "$TASK_ID" "running"

    COMMANDS=$(jq -r ".tasks[$i].commands[]" "$TASKS_FILE")
    TASK_FAILED=false

    while IFS= read -r cmd; do
        EXPANDED_CMD=$(expand_variables "$cmd")
        log "[CMD] $EXPANDED_CMD"
        if ! eval "$EXPANDED_CMD"; then
            log "[FAIL] Command failed: $EXPANDED_CMD"
            TASK_FAILED=true
            break
        fi
    done <<< "$COMMANDS"

    if [ "$TASK_FAILED" = true ]; then
        update_task_status "$TASK_ID" "failed"
        FAILED=$((FAILED + 1))
        log "[ERROR] Task $TASK_ID failed. Re-run with: $0 $TASKS_FILE --from $TASK_ID"
        exit 1
    fi

    update_task_status "$TASK_ID" "success"
    COMPLETED=$((COMPLETED + 1))
    log "[OK] $TASK_ID: $TASK_NAME"
done

log "[DONE] Completed: $COMPLETED, Skipped: $SKIPPED, Failed: $FAILED"
