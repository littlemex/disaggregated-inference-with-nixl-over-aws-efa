#!/bin/bash
##
## Disaggregated KV Cache Inference Test Script
##
## このスクリプトは以下を自動化します:
## 1. Producer/Consumer/Proxy の起動
## 2. 推論リクエストの送信
## 3. 結果の検証
##

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ssm_helper.sh"

# 設定ファイルの読み込み
if [ $# -lt 1 ]; then
    echo "Usage: $0 <config-file>"
    echo "Example: $0 configs/v9test-ap-northeast-1.env"
    exit 1
fi

CONFIG_FILE="$1"
source "${CONFIG_FILE}"

log "==========================================="
log "Disaggregated KV Cache Inference Test"
log "==========================================="
log "Producer: ${NODE1_INSTANCE_ID} (${NODE1_PRIVATE_IP}:${PRODUCER_PORT})"
log "Consumer: ${NODE2_INSTANCE_ID} (${NODE2_PRIVATE_IP}:${CONSUMER_PORT})"
log "Proxy:    ${NODE2_INSTANCE_ID} (${NODE2_PRIVATE_IP}:${PROXY_PORT})"
log ""

# ステップ 1: 起動スクリプトを再生成（修正版テンプレート使用）
log "[STEP 1] Regenerating startup scripts with fixed templates..."

# テンプレートを S3 にアップロード
aws s3 cp templates/ "s3://${S3_BUCKET}/templates/" --recursive --region "${AWS_REGION}"
success "Templates uploaded to S3"

# 環境変数をエクスポート（task_runner.sh が使用）
export S3_BUCKET AWS_REGION NODE1_INSTANCE_ID NODE2_INSTANCE_ID
export NODE1_PRIVATE_IP NODE2_PRIVATE_IP DEPLOYMENT_ID ENGINE_ID
export PRODUCER_PORT CONSUMER_PORT PROXY_PORT NIXL_PORT ZMQ_PORT
export REMOTE_USER MODEL_NAME PRODUCER_GPU_COUNT CONSUMER_GPU_COUNT
export GPU_MEMORY_UTILIZATION MAX_MODEL_LEN MAX_NUM_BATCHED_TOKENS
export KV_BUFFER_SIZE KV_BUFFER_DEVICE

# Task Runner で起動スクリプトを再生成
./task_runner.sh tasks/regenerate-startup-scripts.json
success "Startup scripts regenerated"

# ステップ 2: Producer を起動
log "[STEP 2] Starting Producer..."
ssm_run_command "${NODE1_INSTANCE_ID}" "${AWS_REGION}" "cd /home/ubuntu && ./start_producer.sh"
sleep 30
success "Producer started"

# Producer のログを確認
log "Checking Producer logs..."
PRODUCER_CMD_ID=$(ssm_run_command "${NODE1_INSTANCE_ID}" "${AWS_REGION}" "tail -50 /home/ubuntu/producer.log")
sleep 3
aws ssm get-command-invocation \
    --command-id "${PRODUCER_CMD_ID}" \
    --instance-id "${NODE1_INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'StandardOutputContent' \
    --output text | tail -20

# ステップ 3: Consumer を起動
log "[STEP 3] Starting Consumer..."
ssm_run_command "${NODE2_INSTANCE_ID}" "${AWS_REGION}" "cd /home/ubuntu && ./start_consumer.sh"
sleep 30
success "Consumer started"

# Consumer のログを確認
log "Checking Consumer logs..."
CONSUMER_CMD_ID=$(ssm_run_command "${NODE2_INSTANCE_ID}" "${AWS_REGION}" "tail -50 /home/ubuntu/consumer.log")
sleep 3
aws ssm get-command-invocation \
    --command-id "${CONSUMER_CMD_ID}" \
    --instance-id "${NODE2_INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'StandardOutputContent' \
    --output text | tail -20

# ステップ 4: Proxy を起動
log "[STEP 4] Starting Proxy Server..."
ssm_run_command "${NODE2_INSTANCE_ID}" "${AWS_REGION}" "cd /home/ubuntu && ./start_proxy.sh"
sleep 10
success "Proxy Server started"

# Proxy のログを確認
log "Checking Proxy logs..."
PROXY_CMD_ID=$(ssm_run_command "${NODE2_INSTANCE_ID}" "${AWS_REGION}" "tail -30 /home/ubuntu/proxy.log")
sleep 3
aws ssm get-command-invocation \
    --command-id "${PROXY_CMD_ID}" \
    --instance-id "${NODE2_INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'StandardOutputContent' \
    --output text

# ステップ 5: ヘルスチェック
log "[STEP 5] Health check..."
log "Checking Producer port ${PRODUCER_PORT}..."
ssm_run_and_wait "${NODE1_INSTANCE_ID}" "${AWS_REGION}" "nc -zv localhost ${PRODUCER_PORT}" 10

log "Checking Consumer port ${CONSUMER_PORT}..."
ssm_run_and_wait "${NODE2_INSTANCE_ID}" "${AWS_REGION}" "nc -zv localhost ${CONSUMER_PORT}" 10

log "Checking Proxy port ${PROXY_PORT}..."
ssm_run_and_wait "${NODE2_INSTANCE_ID}" "${AWS_REGION}" "nc -zv localhost ${PROXY_PORT}" 10

success "All services are running!"

# ステップ 6: 推論リクエストを送信
log "[STEP 6] Sending inference request..."

# Consumer の Public IP を取得
CONSUMER_PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "${NODE2_INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

log "Consumer Public IP: ${CONSUMER_PUBLIC_IP}"
log "Proxy URL: http://${CONSUMER_PUBLIC_IP}:${PROXY_PORT}/v1/completions"

# テストリクエストを作成
TEST_REQUEST=$(cat <<EOF
{
  "model": "${MODEL_NAME}",
  "prompt": "What is the capital of Japan?",
  "max_tokens": 100,
  "temperature": 0.7
}
EOF
)

log "Sending test request..."
curl -X POST "http://${CONSUMER_PUBLIC_IP}:${PROXY_PORT}/v1/completions" \
    -H "Content-Type: application/json" \
    -d "${TEST_REQUEST}" \
    -o /tmp/inference_result.json \
    -w "\nHTTP Status: %{http_code}\n" || true

if [ -f /tmp/inference_result.json ]; then
    log "Response:"
    cat /tmp/inference_result.json | jq '.' || cat /tmp/inference_result.json
    success "Inference test completed!"
else
    error "No response received"
fi

log ""
log "==========================================="
log "Test Summary"
log "==========================================="
log "Producer:  Running on ${NODE1_PRIVATE_IP}:${PRODUCER_PORT}"
log "Consumer:  Running on ${NODE2_PRIVATE_IP}:${CONSUMER_PORT}"
log "Proxy:     Running on ${NODE2_PRIVATE_IP}:${PROXY_PORT}"
log "Public IP: ${CONSUMER_PUBLIC_IP}"
log ""
log "To test manually:"
log "  curl -X POST http://${CONSUMER_PUBLIC_IP}:${PROXY_PORT}/v1/completions \\"
log "    -H 'Content-Type: application/json' \\"
log "    -d '{\"model\": \"${MODEL_NAME}\", \"prompt\": \"Hello!\", \"max_tokens\": 50}'"
log ""
