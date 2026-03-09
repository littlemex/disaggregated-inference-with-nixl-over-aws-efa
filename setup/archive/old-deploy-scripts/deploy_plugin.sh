#!/bin/bash
##
## NIXL LIBFABRIC Plugin Deployment Script
##
## Usage:
##   ./deploy_plugin.sh <instance-id> <plugin-so-path>
##
## Example:
##   ./deploy_plugin.sh i-1234567890abcdef0 /home/coder/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so
##

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Helper functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR]${NC} $1"
}

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <instance-id> <plugin-so-path>"
    echo ""
    echo "Example:"
    echo "  $0 i-1234567890abcdef0 /home/coder/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so"
    exit 1
fi

INSTANCE_ID="$1"
PLUGIN_PATH="$2"

# Verify plugin file exists
if [ ! -f "$PLUGIN_PATH" ]; then
    error "Plugin file not found: $PLUGIN_PATH"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_RUNNER="${SCRIPT_DIR}/task_runner.sh"
TASK_JSON="${SCRIPT_DIR}/tasks/deploy-nixl-libfabric-plugin.json"

# Verify files exist
if [ ! -f "$TASK_RUNNER" ]; then
    error "task_runner.sh not found: $TASK_RUNNER"
    exit 1
fi

if [ ! -f "$TASK_JSON" ]; then
    error "Task JSON not found: $TASK_JSON"
    exit 1
fi

log "================================================"
log "NIXL LIBFABRIC Plugin Deployment"
log "================================================"
log "Instance ID:   $INSTANCE_ID"
log "Plugin:        $PLUGIN_PATH"
log "Plugin size:   $(ls -lh "$PLUGIN_PATH" | awk '{print $5}')"
log ""

# Get S3 bucket from Phase 3 config
PHASE3_CONFIG="${SCRIPT_DIR}/../../../phase3/group1/config.json"
if [ -f "$PHASE3_CONFIG" ]; then
    S3_BUCKET=$(jq -r '.s3.bucket' "$PHASE3_CONFIG")
    log "Using S3 bucket from Phase 3 config: $S3_BUCKET"
else
    error "Phase 3 config not found: $PHASE3_CONFIG"
    exit 1
fi

# Step 1: Upload plugin to S3
log "[1/4] Uploading plugin to S3..."
S3_KEY="plugins/libplugin_LIBFABRIC.so"
aws s3 cp "$PLUGIN_PATH" "s3://${S3_BUCKET}/${S3_KEY}" --quiet
log "[OK] Plugin uploaded to s3://${S3_BUCKET}/${S3_KEY}"

# Step 2: Download plugin from S3 on remote instance
log "[2/4] Downloading plugin from S3 to remote instance..."
DOWNLOAD_COMMAND="aws s3 cp s3://${S3_BUCKET}/${S3_KEY} /tmp/libplugin_LIBFABRIC.so --quiet && chmod 644 /tmp/libplugin_LIBFABRIC.so && ls -lh /tmp/libplugin_LIBFABRIC.so"

COMMAND_ID=$(aws ssm send-command \
    --region us-west-2 \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$DOWNLOAD_COMMAND\"]" \
    --output text \
    --query "Command.CommandId")

# Wait for download to complete
sleep 5
log "[OK] Plugin downloaded to /tmp/libplugin_LIBFABRIC.so"

# Step 3: Base64 encode task_runner.sh and task JSON
log "[3/4] Uploading task_runner.sh and task JSON..."
TASK_RUNNER_BASE64=$(cat "$TASK_RUNNER" | base64 -w 0)
TASK_JSON_BASE64=$(cat "$TASK_JSON" | base64 -w 0)

TMP_DIR="/tmp/nixl-deploy-$(date +%s)"
SETUP_COMMANDS="mkdir -p $TMP_DIR && echo '$TASK_RUNNER_BASE64' | base64 -d > $TMP_DIR/task_runner.sh && echo '$TASK_JSON_BASE64' | base64 -d > $TMP_DIR/deploy.json && chmod +x $TMP_DIR/task_runner.sh"

COMMAND_ID=$(aws ssm send-command \
    --region us-west-2 \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$SETUP_COMMANDS\"]" \
    --output text \
    --query "Command.CommandId")

sleep 3
log "[OK] Task files uploaded"

# Step 4: Execute deployment task
log "[4/4] Executing deployment task..."
DEPLOY_COMMAND="cd $TMP_DIR && bash task_runner.sh deploy.json"

COMMAND_ID=$(aws ssm send-command \
    --region us-west-2 \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$DEPLOY_COMMAND\"]" \
    --timeout-seconds "300" \
    --output text \
    --query "Command.CommandId")

log "Deployment started. Command ID: $COMMAND_ID"
log "Waiting for deployment to complete..."

# Wait and show output
sleep 5

# Get command output
OUTPUT=$(aws ssm get-command-invocation \
    --region us-west-2 \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --output text \
    --query "StandardOutputContent")

STATUS=$(aws ssm get-command-invocation \
    --region us-west-2 \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --output text \
    --query "Status")

echo ""
echo "========== Deployment Output =========="
echo "$OUTPUT"
echo "========================================"
echo ""

if [ "$STATUS" = "Success" ]; then
    log "[SUCCESS] Plugin deployed successfully!"
    log ""
    log "Next steps:"
    log "  1. Verify plugin is loaded: ssh to instance and check NIXL logs"
    log "  2. Test with backend=['LIBFABRIC'] in your vLLM configuration"
else
    error "Deployment failed. Status: $STATUS"

    ERROR_OUTPUT=$(aws ssm get-command-invocation \
        --region us-west-2 \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --output text \
        --query "StandardErrorContent" || echo "No error output")

    echo ""
    echo "========== Error Output =========="
    echo "$ERROR_OUTPUT"
    echo "=================================="

    exit 1
fi

# Cleanup remote temporary directory
log "Cleaning up temporary directory..."
aws ssm send-command \
    --region us-west-2 \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"rm -rf $TMP_DIR\"]" \
    --output text \
    --query "Command.CommandId" >/dev/null

log "[OK] Deployment complete!"
