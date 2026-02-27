#!/bin/bash
# Unified Experiment Runner (SSM-based)
#
# Design:
#   - SSH key not required (uses SSM Session Manager)
#   - File transfer via S3 + command execution via SSM send-command
#   - Uses setup/task_runner.sh (task execution engine is unchanged)
#
# Required environment variables:
#   SCRIPTS_BUCKET: S3 bucket name (from CDK Output)
#   NODE1_ID: Node1 instance ID
#   NODE2_ID: Node2 instance ID
#   NODE1_PRIVATE: Node1 private IP
#   NODE2_PRIVATE: Node2 private IP
#
# Usage:
#   ./run_experiment.sh <phase> <action> [options]
#
# Actions:
#   deploy              Deploy scripts to S3
#   run <layer|pattern> Run a specific layer or pattern
#   run all             Run all layers in priority order
#   status              Check measurement progress
#   list                List available task definitions
#
# Examples:
#   ./run_experiment.sh phase14 deploy
#   ./run_experiment.sh phase14 run L0
#   ./run_experiment.sh phase14 run p14-unified-1k
#   ./run_experiment.sh phase14 run all
#   ./run_experiment.sh phase14 status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load helper scripts
source "$LIB_DIR/ssm-deploy.sh"
source "$LIB_DIR/ssm-run.sh"

# Environment variables
: "${SCRIPTS_BUCKET:?SCRIPTS_BUCKET not set}"
: "${NODE1_ID:?NODE1_ID not set}"
: "${NODE2_ID:?NODE2_ID not set}"
: "${NODE1_PRIVATE:?NODE1_PRIVATE not set}"
: "${NODE2_PRIVATE:?NODE2_PRIVATE not set}"

TASK_RUNNER_SEARCH_PATHS=(
    "/work/data-science/claudecode/investigations/nixl-efa-tai/setup/task_runner.sh"
    "${SCRIPT_DIR}/../setup/task_runner.sh"
)

# Find task_runner.sh
TASK_RUNNER=""
for path in "${TASK_RUNNER_SEARCH_PATHS[@]}"; do
    if [ -f "$path" ]; then
        TASK_RUNNER="$path"
        break
    fi
done

if [ -z "$TASK_RUNNER" ]; then
    echo "[ERROR] task_runner.sh not found in search paths"
    echo "[INFO] Expected at: ${TASK_RUNNER_SEARCH_PATHS[*]}"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${YELLOW}[$(date -u '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }

# ---- Usage ----

usage() {
    echo "Usage: $0 <phase> <action> [options]"
    echo ""
    echo "Phases:  phase14, phase15, phase16, ..."
    echo ""
    echo "Actions:"
    echo "  deploy                Deploy scripts to S3"
    echo "  run <layer|pattern>   Run a layer (L0, L1, ...) or single pattern"
    echo "  run all               Run all layers in priority order"
    echo "  status                Check measurement progress"
    echo "  list                  List available task definitions"
    echo ""
    echo "Examples:"
    echo "  $0 phase14 deploy"
    echo "  $0 phase14 run L0"
    echo "  $0 phase14 run p14-unified-1k"
    echo "  $0 phase14 run all"
    echo "  $0 phase14 status"
    echo ""
    echo "Environment variables:"
    echo "  SCRIPTS_BUCKET          S3 bucket name (from CDK Output)"
    echo "  NODE1_ID, NODE2_ID      Instance IDs"
    echo "  NODE1_PRIVATE, NODE2_PRIVATE  Private IPs of nodes"
    exit 1
}

# ---- Deploy ----

do_deploy() {
    local phase="$1"
    local scripts_dir="$SCRIPT_DIR/scripts"
    local task_dir="$SCRIPT_DIR/task-definitions/$phase"

    log "Deploying scripts and tasks for $phase..."

    # Upload shared scripts to S3
    if [ -d "$scripts_dir" ]; then
        sync_to_s3 "$scripts_dir" "scripts/"
    else
        error "Scripts directory not found: $scripts_dir"
    fi

    # Upload task definitions to S3
    if [ -d "$task_dir" ]; then
        sync_to_s3 "$task_dir" "tasks/$phase/"
    else
        error "Task definitions not found: $task_dir"
        echo "[INFO] Generate them first: ./generate_tasks.py $phase"
    fi

    # Upload task_runner.sh to S3
    upload_to_s3 "$TASK_RUNNER" "scripts/task_runner.sh"

    success "All files deployed to S3"
    echo ""
    echo "Next steps:"
    echo "  1. Run experiment: ./run_experiment.sh $phase run L0"
}

# ---- Run ----

run_task_on_node() {
    local json_path="$1"
    local instance_id="$2"
    local json_name
    json_name=$(basename "$json_path")

    # Determine the S3 key for this task definition
    # json_path is like: .../task-definitions/phase14/p14-unified-1k.json
    # or .../task-definitions/phase14/consumer/p14-efa-4k-consumer.json
    local relative_path="${json_path#*task-definitions/}"
    local s3_task_key="tasks/$relative_path"

    log "Running $json_name on instance: $instance_id"

    ssm_run_command "$instance_id" \
        "aws s3 cp s3://$SCRIPTS_BUCKET/scripts/task_runner.sh /tmp/" \
        "aws s3 cp s3://$SCRIPTS_BUCKET/scripts/benchmark_common.py /tmp/" \
        "aws s3 cp s3://$SCRIPTS_BUCKET/scripts/disagg_proxy_server.py /tmp/ 2>/dev/null || true" \
        "aws s3 cp s3://$SCRIPTS_BUCKET/$s3_task_key /tmp/$json_name" \
        "chmod +x /tmp/task_runner.sh" \
        "export NODE1_PRIVATE=$NODE1_PRIVATE NODE2_PRIVATE=$NODE2_PRIVATE && bash /tmp/task_runner.sh /tmp/$json_name --reset"

    success "$json_name completed on $instance_id"
}

run_single_pattern() {
    local phase="$1"
    local pattern_id="$2"
    local task_dir="$SCRIPT_DIR/task-definitions/$phase"
    local consumer_dir="$task_dir/consumer"

    # Determine if this is a unified or disaggregated pattern
    local producer_json="$task_dir/$pattern_id.json"
    local consumer_json="$consumer_dir/$pattern_id-consumer.json"

    if [ ! -f "$producer_json" ]; then
        error "Task definition not found: $producer_json"
    fi

    if [ -f "$consumer_json" ]; then
        # Disaggregated: Run Consumer first, then Producer
        info "Disaggregated pattern detected. Running Consumer first, then Producer."
        echo ""

        log "Starting Consumer on Node2 ($NODE2_ID)..."
        run_task_on_node "$consumer_json" "$NODE2_ID" &
        local consumer_pid=$!

        # Wait for Consumer to initialize before starting Producer
        log "Waiting 30 seconds for Consumer to start initializing..."
        sleep 30

        log "Starting Producer on Node1 ($NODE1_ID)..."
        run_task_on_node "$producer_json" "$NODE1_ID"

        # Wait for Consumer to complete
        wait $consumer_pid 2>/dev/null || true
        success "Pattern $pattern_id completed"
    else
        # Unified: Run on Node1
        info "Unified pattern detected. Running on Node1 ($NODE1_ID)."
        run_task_on_node "$producer_json" "$NODE1_ID"
        success "Pattern $pattern_id completed"
    fi
}

run_layer() {
    local phase="$1"
    local layer_id="$2"
    local task_dir="$SCRIPT_DIR/task-definitions/$phase"

    if [ ! -d "$task_dir" ]; then
        error "Task definitions not found: $task_dir"
        echo "[INFO] Generate them first: ./generate_tasks.py $phase"
    fi

    # Find patterns matching the layer
    local plan_file="$SCRIPT_DIR/experiment-plans/$phase.json"
    if [ ! -f "$plan_file" ]; then
        error "Experiment plan not found: $plan_file"
    fi

    # Extract pattern IDs for the specified layer using Python
    local patterns
    patterns=$(python3 -c "
import json, sys
with open('$plan_file') as f:
    plan = json.load(f)
for layer in plan['layers']:
    if layer.get('id') == '$layer_id':
        for p in layer['patterns']:
            print(p['id'])
        sys.exit(0)
print('LAYER_NOT_FOUND', file=sys.stderr)
sys.exit(1)
" 2>&1)

    if [ $? -ne 0 ]; then
        error "Layer $layer_id not found in $plan_file"
    fi

    local pattern_count
    pattern_count=$(echo "$patterns" | wc -l)
    info "Layer $layer_id: $pattern_count patterns"
    echo ""

    local idx=0
    while IFS= read -r pattern_id; do
        idx=$((idx + 1))
        echo ""
        log "=== Pattern $idx/$pattern_count: $pattern_id ==="
        run_single_pattern "$phase" "$pattern_id"
    done <<< "$patterns"

    echo ""
    success "Layer $layer_id completed ($pattern_count patterns)"
}

run_all_layers() {
    local phase="$1"
    local plan_file="$SCRIPT_DIR/experiment-plans/$phase.json"

    if [ ! -f "$plan_file" ]; then
        error "Experiment plan not found: $plan_file"
    fi

    # Extract layer IDs in order
    local layer_ids
    layer_ids=$(python3 -c "
import json
with open('$plan_file') as f:
    plan = json.load(f)
for layer in plan['layers']:
    print(layer.get('id', ''))
")

    info "Running all layers for $phase"
    while IFS= read -r layer_id; do
        if [ -n "$layer_id" ]; then
            echo ""
            log "=========================================="
            log "Layer: $layer_id"
            log "=========================================="
            run_layer "$phase" "$layer_id"
        fi
    done <<< "$layer_ids"

    success "All layers completed for $phase"
}

do_run() {
    local phase="$1"
    local target="$2"

    if [ -z "$target" ]; then
        error "Specify a layer (L0, L1, ...) or pattern ID, or 'all'"
    fi

    case "$target" in
        all)
            run_all_layers "$phase"
            ;;
        L[0-9]*)
            run_layer "$phase" "$target"
            ;;
        *)
            # Assume it's a pattern ID
            run_single_pattern "$phase" "$target"
            ;;
    esac
}

# ---- Status ----

do_status() {
    local phase="$1"
    local task_dir="$SCRIPT_DIR/task-definitions/$phase"
    local results_dir="$SCRIPT_DIR/results/$phase"

    if [ ! -d "$task_dir" ]; then
        info "No task definitions found for $phase"
        info "Generate them first: ./generate_tasks.py $phase"
        return
    fi

    # Count task definitions (excluding consumer dir)
    local total_tasks
    total_tasks=$(find "$task_dir" -maxdepth 1 -name "*.json" | wc -l)

    # Count results
    local completed=0
    if [ -d "$results_dir" ]; then
        completed=$(find "$results_dir" -name "*.json" | wc -l)
    fi

    echo "=== $phase Status ==="
    echo "  Task definitions: $total_tasks"
    echo "  Results:          $completed"
    echo "  Remaining:        $((total_tasks - completed))"
    echo ""

    if [ -d "$results_dir" ] && [ "$completed" -gt 0 ]; then
        echo "  Latest results:"
        find "$results_dir" -name "*.json" -printf '    %T@ %p\n' | sort -rn | head -5 | cut -d' ' -f2-
    fi
}

# ---- List ----

do_list() {
    local phase="$1"
    local task_dir="$SCRIPT_DIR/task-definitions/$phase"

    if [ ! -d "$task_dir" ]; then
        info "No task definitions found for $phase"
        info "Generate them first: ./generate_tasks.py $phase"
        return
    fi

    echo "=== Task Definitions: $phase ==="
    echo ""

    # Group by layer using the experiment plan
    local plan_file="$SCRIPT_DIR/experiment-plans/$phase.json"
    if [ -f "$plan_file" ]; then
        python3 -c "
import json, os
with open('$plan_file') as f:
    plan = json.load(f)
task_dir = '$task_dir'
for layer in plan['layers']:
    lid = layer.get('id', '?')
    name = layer.get('name', '')
    priority = layer.get('priority', '')
    patterns = layer.get('patterns', [])
    print(f'  [{lid}] {name} ({priority}) - {len(patterns)} patterns')
    for p in patterns:
        pid = p['id']
        exists = os.path.exists(os.path.join(task_dir, f'{pid}.json'))
        status = '[OK]' if exists else '[MISSING]'
        print(f'    {status} {pid}')
    print()
"
    else
        find "$task_dir" -maxdepth 1 -name "*.json" | sort | while read -r f; do
            echo "  $(basename "$f")"
        done
    fi
}

# ---- Main ----

if [ $# -lt 2 ]; then
    usage
fi

PHASE="$1"
ACTION="$2"
shift 2

case "$ACTION" in
    deploy)
        do_deploy "$PHASE"
        ;;
    run)
        do_run "$PHASE" "$@"
        ;;
    status)
        do_status "$PHASE"
        ;;
    list)
        do_list "$PHASE"
        ;;
    *)
        error "Unknown action: $ACTION"
        ;;
esac
