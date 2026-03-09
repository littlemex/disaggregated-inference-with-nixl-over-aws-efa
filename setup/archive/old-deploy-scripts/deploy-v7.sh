#!/bin/bash
##
## Complete NIXL Deployment Script (v7)
## SSM + S3 based deployment - no SSH/scp required
##
## Usage:
##   ./deploy-v7.sh <config-file>
##
## Example:
##   ./deploy-v7.sh configs/v7test-us-west-2.env
##
## This script automates the complete NIXL deployment using SSM and S3:
##   1. Check prerequisites (libfabric-dev)
##   2. Clone and build NIXL from GitHub
##   3. Upload plugin to S3
##   4. Setup Producer node via SSM with vLLM + NIXL + kv-transfer-config
##   5. Setup Consumer node via SSM with vLLM + NIXL + kv-transfer-config
##   6. Deploy custom LIBFABRIC plugin via S3
##   7. Create and upload startup scripts via S3
##

set -euo pipefail

# Load SSM helper functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ssm_helper.sh"

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <config-file>"
    echo ""
    echo "Example:"
    echo "  $0 configs/v7test-us-west-2.env"
    echo ""
    exit 1
fi

CONFIG_FILE="$1"

# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
    error "Config file not found: $CONFIG_FILE"
fi

# Load configuration
log "Loading configuration from $CONFIG_FILE..."
source "$CONFIG_FILE"

# Validate required variables
REQUIRED_VARS=(
    "S3_BUCKET"
    "AWS_REGION"
    "NODE1_INSTANCE_ID"
    "NODE2_INSTANCE_ID"
    "NODE1_PRIVATE_IP"
    "NODE2_PRIVATE_IP"
    "DEPLOYMENT_ID"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        error "Required variable $var is not set in $CONFIG_FILE"
    fi
done

success "Configuration loaded"

# Display configuration
echo ""
echo "========================================="
echo "Deployment Configuration (v7 - SSM + S3)"
echo "========================================="
echo "S3 Bucket:      $S3_BUCKET"
echo "AWS Region:     $AWS_REGION"
echo "Deployment ID:  $DEPLOYMENT_ID"
echo ""
echo "Producer (Node1):"
echo "  Instance ID:  $NODE1_INSTANCE_ID"
echo "  Private IP:   $NODE1_PRIVATE_IP"
echo "  Port:         ${PRODUCER_PORT:-8100}"
echo ""
echo "Consumer (Node2):"
echo "  Instance ID:  $NODE2_INSTANCE_ID"
echo "  Private IP:   $NODE2_PRIVATE_IP"
echo "  Port:         ${CONSUMER_PORT:-8200}"
echo ""
echo "Common ENGINE_ID: ${ENGINE_ID:-$DEPLOYMENT_ID}"
echo "NIXL Port:        ${NIXL_PORT:-14579}"
echo "ZMQ Port:         ${ZMQ_PORT:-50100}"
echo ""

# Confirm
read -p "Proceed with deployment? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi

# Export environment variables for task runner
export NIXL_REPO="${NIXL_REPO:-https://github.com/littlemex/nixl.git}"
export NIXL_BRANCH="${NIXL_BRANCH:-main}"
export NIXL_CLONE_DIR="${NIXL_CLONE_DIR:-/tmp/nixl-build}"
export BUILD_SUBDIR="${BUILD_SUBDIR:-build}"
export PLUGIN_RELATIVE_PATH="${PLUGIN_RELATIVE_PATH:-src/plugins/libfabric/libplugin_LIBFABRIC.so}"
export S3_PLUGIN_KEY="${S3_PLUGIN_KEY:-plugins/libplugin_LIBFABRIC.so}"
export REMOTE_USER="${REMOTE_USER:-ubuntu}"
export ENGINE_ID="${ENGINE_ID:-$DEPLOYMENT_ID}"
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen2.5-32B-Instruct}"
export TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-2}"
export GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.9}"
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-32000}"
export MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
export KV_BUFFER_SIZE="${KV_BUFFER_SIZE:-5000000000}"
export KV_BUFFER_DEVICE="${KV_BUFFER_DEVICE:-cpu}"
export NIXL_PORT="${NIXL_PORT:-14579}"
export ZMQ_PORT="${ZMQ_PORT:-50100}"
export PRODUCER_PORT="${PRODUCER_PORT:-8100}"
export CONSUMER_PORT="${CONSUMER_PORT:-8200}"

# Run deployment
TASK_FILE="$SCRIPT_DIR/tasks/complete-deployment-v7.json"

if [ ! -f "$TASK_FILE" ]; then
    error "Task file not found: $TASK_FILE"
fi

log "Starting deployment..."
bash "$SCRIPT_DIR/task_runner.sh" "$TASK_FILE"

success "Deployment complete!"
echo ""
echo "To start the services:"
echo "  Producer: aws ssm send-command --instance-ids $NODE1_INSTANCE_ID --document-name AWS-RunShellScript --parameters 'commands=[\"./start_producer.sh\"]' --region $AWS_REGION"
echo "  Consumer: aws ssm send-command --instance-ids $NODE2_INSTANCE_ID --document-name AWS-RunShellScript --parameters 'commands=[\"./start_consumer.sh\"]' --region $AWS_REGION"
echo ""
