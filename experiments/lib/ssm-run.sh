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

    # 完了待ち
    log "Waiting for command to complete..."
    aws ssm wait command-executed \
        --command-id "$command_id" \
        --instance-id "$instance_id"

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
        error "Command failed with status: $status"
        echo "$output" | jq -r '.[2]'  # stderr
        return 1
    fi
}

# 関数をエクスポート（source された場合）
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    export -f ssm_run_command
fi
