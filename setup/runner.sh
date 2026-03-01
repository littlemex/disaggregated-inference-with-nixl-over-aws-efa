#!/bin/bash
##
## Setup Runner - Deploy and execute environment setup tasks via SSM
##
## Usage:
##   ./runner.sh <instance-id> [task-json]
##
## Examples:
##   ./runner.sh i-1234567890abcdef0
##   ./runner.sh i-1234567890abcdef0 tasks/setup-v0.16.0-environment.json
##
## Default task: tasks/setup-v0.16.0-environment.json
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
if [ $# -lt 1 ]; then
    echo "Usage: $0 <instance-id> [task-json]"
    echo ""
    echo "Examples:"
    echo "  $0 i-1234567890abcdef0"
    echo "  $0 i-1234567890abcdef0 tasks/setup-v0.16.0-environment.json"
    echo ""
    echo "Default task: tasks/setup-v0.16.0-environment.json"
    exit 1
fi

INSTANCE_ID="$1"
TASK_JSON="${2:-tasks/setup-v0.16.0-environment.json}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_RUNNER="${SCRIPT_DIR}/task_runner.sh"

# Verify files exist
if [ ! -f "$TASK_RUNNER" ]; then
    error "task_runner.sh not found: $TASK_RUNNER"
    exit 1
fi

if [ ! -f "${SCRIPT_DIR}/${TASK_JSON}" ]; then
    error "Task JSON not found: ${SCRIPT_DIR}/${TASK_JSON}"
    exit 1
fi

log "=========================================="
log "Setup Runner - Environment Setup via SSM"
log "=========================================="
log "Instance ID: $INSTANCE_ID"
log "Task JSON:   $TASK_JSON"
log ""

# Create temporary directory on remote instance
TMP_DIR="/tmp/nixl-setup-$(date +%s)"

log "[1/4] Creating temporary directory on remote instance..."
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"mkdir -p $TMP_DIR\"]" \
    --output text \
    --query "Command.CommandId" >/dev/null

sleep 2
log "[OK] Temporary directory created: $TMP_DIR"

# Copy task_runner.sh and task JSON to S3 (if S3 bucket is configured) or directly via SSM
log "[2/4] Uploading task_runner.sh and task JSON..."

# For simplicity, we'll embed the files in the SSM command
# Read task_runner.sh and task JSON
TASK_RUNNER_CONTENT=$(cat "$TASK_RUNNER" | base64 -w 0)
TASK_JSON_CONTENT=$(cat "${SCRIPT_DIR}/${TASK_JSON}" | base64 -w 0)

# Upload files via SSM
UPLOAD_CMD_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        \"echo '$TASK_RUNNER_CONTENT' | base64 -d > $TMP_DIR/task_runner.sh\",
        \"echo '$TASK_JSON_CONTENT' | base64 -d > $TMP_DIR/$(basename $TASK_JSON)\",
        \"chmod +x $TMP_DIR/task_runner.sh\",
        \"echo '[OK] Files uploaded to $TMP_DIR'\"
    ]" \
    --output text \
    --query "Command.CommandId")

# Wait for upload to complete
log "Waiting for upload to complete (Command ID: $UPLOAD_CMD_ID)..."
aws ssm wait command-executed \
    --command-id "$UPLOAD_CMD_ID" \
    --instance-id "$INSTANCE_ID"

log "[OK] Files uploaded successfully"

# Execute task_runner.sh
log "[3/4] Executing task_runner.sh on remote instance..."

EXEC_CMD_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[
        \"cd $TMP_DIR\",
        \"sudo -u ubuntu bash task_runner.sh $(basename $TASK_JSON)\"
    ]" \
    --output text \
    --query "Command.CommandId")

log "Execution started (Command ID: $EXEC_CMD_ID)"
log "Waiting for task execution to complete..."

# Wait for execution (timeout: 30 minutes)
if aws ssm wait command-executed \
    --command-id "$EXEC_CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --cli-read-timeout 1800 \
    --cli-connect-timeout 1800 2>/dev/null; then
    log "[OK] Task execution completed"
else
    warn "Wait command timed out or failed. Checking command status..."
fi

# Get command output
log "[4/4] Retrieving execution output..."

OUTPUT=$(aws ssm get-command-invocation \
    --command-id "$EXEC_CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "StandardOutputContent" \
    --output text 2>/dev/null || echo "[No output]")

ERROR_OUTPUT=$(aws ssm get-command-invocation \
    --command-id "$EXEC_CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "StandardErrorContent" \
    --output text 2>/dev/null || echo "")

echo ""
echo "=========================================="
echo "Execution Output"
echo "=========================================="
echo "$OUTPUT"

if [ -n "$ERROR_OUTPUT" ] && [ "$ERROR_OUTPUT" != "None" ]; then
    echo ""
    echo "=========================================="
    echo "Error Output"
    echo "=========================================="
    echo "$ERROR_OUTPUT"
fi

# Check final status
STATUS=$(aws ssm get-command-invocation \
    --command-id "$EXEC_CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "Status" \
    --output text 2>/dev/null || echo "Unknown")

echo ""
echo "=========================================="
if [ "$STATUS" = "Success" ]; then
    log "Setup completed successfully!"
    echo "=========================================="
    exit 0
else
    error "Setup failed with status: $STATUS"
    echo "=========================================="
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check SSM Session Manager access:"
    echo "     aws ssm start-session --target $INSTANCE_ID"
    echo "  2. Check task_runner.sh logs on the instance:"
    echo "     ls -la $TMP_DIR/"
    echo "  3. Re-run failed tasks:"
    echo "     cd $TMP_DIR && sudo -u ubuntu bash task_runner.sh $(basename $TASK_JSON) --from <task-id>"
    exit 1
fi
