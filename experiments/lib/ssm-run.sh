#!/bin/bash
# SSM send-command を使ったリモートコマンド実行ヘルパー

set -e

SCRIPTS_BUCKET="${SCRIPTS_BUCKET:-}"
if [ -z "$SCRIPTS_BUCKET" ]; then
    echo "Error: SCRIPTS_BUCKET environment variable not set"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${YELLOW}[$(date -u '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# SSM send-command を実行
ssm_run_command() {
    local instance_id="$1"
    shift
    local commands=("$@")

    log "Running commands on instance: $instance_id"

    # jq を使用して安全に JSON 配列を構築（インジェクション防止）
    local json_commands
    json_commands=$(printf '%s\n' "${commands[@]}" | jq -R . | jq -s '.')

    local parameters_json
    parameters_json=$(jq -n --argjson cmds "$json_commands" '{"commands": $cmds}')

    # send-command を実行
    local command_id
    command_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "$parameters_json" \
        --timeout-seconds 3600 \
        --output-s3-bucket-name "$SCRIPTS_BUCKET" \
        --output-s3-key-prefix "command-output/" \
        --query 'Command.CommandId' \
        --output text)

    if [ -z "$command_id" ]; then
        error "Failed to send command"
    fi

    log "Command ID: $command_id"

    # 完了待ち（ポーリング）
    log "Waiting for command to complete..."
    local max_attempts=120  # 120 * 30s = 3600s = 60 minutes
    local attempt=0
    local status="Pending"

    while [ $attempt -lt $max_attempts ]; do
        status=$(aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --query 'Status' \
            --output text 2>/dev/null || echo "Pending")

        if [ "$status" = "Success" ] || [ "$status" = "Failed" ] || [ "$status" = "Cancelled" ] || [ "$status" = "TimedOut" ]; then
            break
        fi

        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            log "Still waiting... ($attempt/$max_attempts, Status: $status)"
        fi
        sleep 30
    done

    if [ $attempt -eq $max_attempts ]; then
        error "Command timed out after 60 minutes"
    fi

    # 結果取得
    log "Retrieving command output..."
    local output
    output=$(aws ssm get-command-invocation \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        --query '[Status,StandardOutputContent,StandardErrorContent]' \
        --output json)

    local status
    status=$(echo "$output" | jq -r '.[0]')

    if [ "$status" = "Success" ]; then
        success "Command completed successfully"
        echo "$output" | jq -r '.[1]'  # stdout
        return 0
    else
        # Don't exit on error - just log and return non-zero
        echo -e "${RED}[ERROR]${NC} Command failed with status: $status" >&2
        echo "$output" | jq -r '.[2]'  # stderr
        return 1
    fi
}

# 関数をエクスポート（source された場合）
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    export -f ssm_run_command
fi
