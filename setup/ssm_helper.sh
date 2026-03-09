#!/bin/bash
##
## SSM Helper Functions for NIXL Deployment
##
## Provides utilities for:
## - Running commands via SSM send-command
## - Waiting for command completion
## - S3 file transfer coordination
##

set -eo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

##
## ssm_run_command: Run a command via SSM and return command ID
##
## Usage:
##   COMMAND_ID=$(ssm_run_command <instance-id> <region> <command>)
##
ssm_run_command() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local COMMAND="$3"

    log "Running SSM command on ${INSTANCE_ID}..."

    local COMMAND_ID=$(aws ssm send-command \
        --instance-ids "${INSTANCE_ID}" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"${COMMAND}\"]" \
        --region "${REGION}" \
        --output text \
        --query "Command.CommandId" 2>&1)

    if [ $? -ne 0 ]; then
        error "Failed to send SSM command: ${COMMAND_ID}"
    fi

    echo "${COMMAND_ID}"
}

##
## ssm_wait_command: Wait for SSM command to complete
##
## Usage:
##   ssm_wait_command <command-id> <instance-id> <region> [timeout-seconds]
##
ssm_wait_command() {
    local COMMAND_ID="$1"
    local INSTANCE_ID="$2"
    local REGION="$3"
    local TIMEOUT="${4:-300}"  # Default 5 minutes

    log "Waiting for command ${COMMAND_ID} to complete (timeout: ${TIMEOUT}s)..."

    local ELAPSED=0
    local INTERVAL=5

    while [ $ELAPSED -lt $TIMEOUT ]; do
        local STATUS=$(aws ssm get-command-invocation \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}" \
            --region "${REGION}" \
            --query "Status" \
            --output text 2>/dev/null || echo "Pending")

        case "$STATUS" in
            "Success")
                success "Command completed successfully"
                return 0
                ;;
            "Failed"|"Cancelled"|"TimedOut")
                # Get output for debugging
                local OUTPUT=$(aws ssm get-command-invocation \
                    --command-id "${COMMAND_ID}" \
                    --instance-id "${INSTANCE_ID}" \
                    --region "${REGION}" \
                    --query "StandardErrorContent" \
                    --output text 2>/dev/null || echo "No output")
                error "Command failed with status: ${STATUS}\nError: ${OUTPUT}"
                ;;
            "InProgress"|"Pending")
                echo -n "."
                sleep $INTERVAL
                ELAPSED=$((ELAPSED + INTERVAL))
                ;;
            *)
                echo -n "?"
                sleep $INTERVAL
                ELAPSED=$((ELAPSED + INTERVAL))
                ;;
        esac
    done

    error "Command timed out after ${TIMEOUT} seconds"
}

##
## ssm_run_and_wait: Run SSM command and wait for completion
##
## Usage:
##   ssm_run_and_wait <instance-id> <region> <command> [timeout]
##
ssm_run_and_wait() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local COMMAND="$3"
    local TIMEOUT="${4:-300}"

    local COMMAND_ID=$(ssm_run_command "${INSTANCE_ID}" "${REGION}" "${COMMAND}")
    ssm_wait_command "${COMMAND_ID}" "${INSTANCE_ID}" "${REGION}" "${TIMEOUT}"
}

##
## ssm_get_output: Get command output
##
## Usage:
##   OUTPUT=$(ssm_get_output <command-id> <instance-id> <region>)
##
ssm_get_output() {
    local COMMAND_ID="$1"
    local INSTANCE_ID="$2"
    local REGION="$3"

    aws ssm get-command-invocation \
        --command-id "${COMMAND_ID}" \
        --instance-id "${INSTANCE_ID}" \
        --region "${REGION}" \
        --query "StandardOutputContent" \
        --output text
}

##
## s3_upload_file: Upload file to S3
##
## Usage:
##   s3_upload_file <local-file> <s3-bucket> <s3-key> <region>
##
s3_upload_file() {
    local LOCAL_FILE="$1"
    local S3_BUCKET="$2"
    local S3_KEY="$3"
    local REGION="$4"

    if [ ! -f "${LOCAL_FILE}" ]; then
        error "Local file not found: ${LOCAL_FILE}"
    fi

    log "Uploading ${LOCAL_FILE} to s3://${S3_BUCKET}/${S3_KEY}..."

    aws s3 cp "${LOCAL_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" --region "${REGION}"

    if [ $? -eq 0 ]; then
        success "File uploaded successfully"
    else
        error "S3 upload failed"
    fi
}

##
## ssm_download_from_s3: Download file from S3 via SSM
##
## Usage:
##   ssm_download_from_s3 <instance-id> <region> <s3-bucket> <s3-key> <remote-path>
##
ssm_download_from_s3() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local S3_BUCKET="$3"
    local S3_KEY="$4"
    local REMOTE_PATH="$5"

    local COMMAND="aws s3 cp s3://${S3_BUCKET}/${S3_KEY} ${REMOTE_PATH} --region ${REGION}"

    ssm_run_and_wait "${INSTANCE_ID}" "${REGION}" "${COMMAND}" 60
}

##
## ssm_run_script: Run a shell script via S3 distribution
##
## Usage:
##   ssm_run_script <instance-id> <region> <s3-bucket> <local-script> [timeout]
##
## This function:
##   1. Validates script syntax locally
##   2. Uploads script to S3
##   3. Downloads and executes on remote instance via SSM
##   4. Cleans up remote script file
##
ssm_run_script() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local S3_BUCKET="$3"
    local LOCAL_SCRIPT="$4"
    local TIMEOUT="${5:-300}"

    if [ ! -f "${LOCAL_SCRIPT}" ]; then
        error "Script file not found: ${LOCAL_SCRIPT}"
    fi

    # Validate script syntax locally
    if ! bash -n "${LOCAL_SCRIPT}" 2>/dev/null; then
        error "Script syntax error in ${LOCAL_SCRIPT}"
    fi

    local SCRIPT_NAME=$(basename "${LOCAL_SCRIPT}")
    local S3_KEY="scripts/${SCRIPT_NAME}"
    local REMOTE_PATH="/tmp/${SCRIPT_NAME}"

    # Upload to S3
    log "Uploading script ${SCRIPT_NAME} to S3..."
    aws s3 cp "${LOCAL_SCRIPT}" "s3://${S3_BUCKET}/${S3_KEY}" \
        --region "${REGION}" --quiet || error "S3 upload failed"

    # Execute on remote instance
    local RUN_CMD="aws s3 cp s3://${S3_BUCKET}/${S3_KEY} ${REMOTE_PATH} --region ${REGION} --quiet && chmod +x ${REMOTE_PATH} && bash ${REMOTE_PATH} && rm -f ${REMOTE_PATH}"

    ssm_run_and_wait "${INSTANCE_ID}" "${REGION}" "${RUN_CMD}" "${TIMEOUT}"
}

##
## ssm_run_script_with_env: Run a script template with environment variable substitution
##
## Usage:
##   ssm_run_script_with_env <instance-id> <region> <s3-bucket> <template-script> [timeout]
##
## This function uses envsubst to expand variables like ${VAR_NAME} in the script template.
## Make sure to export all required variables before calling this function.
##
ssm_run_script_with_env() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local S3_BUCKET="$3"
    local TEMPLATE_SCRIPT="$4"
    local TIMEOUT="${5:-300}"

    if [ ! -f "${TEMPLATE_SCRIPT}" ]; then
        error "Template script not found: ${TEMPLATE_SCRIPT}"
    fi

    # Create temporary expanded script
    local TEMP_SCRIPT=$(mktemp /tmp/expanded-XXXXXX.sh)

    # Expand environment variables
    envsubst < "${TEMPLATE_SCRIPT}" > "${TEMP_SCRIPT}"

    # Validate expanded script
    if ! bash -n "${TEMP_SCRIPT}" 2>/dev/null; then
        cat "${TEMP_SCRIPT}" >&2
        rm -f "${TEMP_SCRIPT}"
        error "Expanded script has syntax errors"
    fi

    # Run the expanded script
    ssm_run_script "${INSTANCE_ID}" "${REGION}" "${S3_BUCKET}" "${TEMP_SCRIPT}" "${TIMEOUT}"

    # Cleanup
    rm -f "${TEMP_SCRIPT}"
}

##
## Export functions for use in task_runner.sh
##
export -f log success error
export -f ssm_run_command ssm_wait_command ssm_run_and_wait ssm_get_output
export -f s3_upload_file ssm_download_from_s3
export -f ssm_run_script ssm_run_script_with_env
