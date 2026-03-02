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
    echo "  collect-results       Collect results from remote nodes"
    echo "  status                Check measurement progress"
    echo "  list                  List available task definitions"
    echo ""
    echo "Examples:"
    echo "  $0 phase14 deploy"
    echo "  $0 phase14 run L0"
    echo "  $0 phase14 run p14-unified-1k"
    echo "  $0 phase14 run all"
    echo "  $0 phase14 collect-results"
    echo "  $0 phase14 status"
    echo ""
    echo "Environment variables:"
    echo "  SCRIPTS_BUCKET          S3 bucket name (from CDK Output)"
    echo "  NODE1_ID, NODE2_ID      Instance IDs"
    echo "  NODE1_PRIVATE, NODE2_PRIVATE  Private IPs of nodes"
    exit 1
}

# ---- Phase State Management ----

get_phase_state_dir() {
    local phase="$1"
    echo "$SCRIPT_DIR/.phase-state/$phase"
}

get_experiment_timestamp() {
    local phase="$1"
    local state_dir
    state_dir=$(get_phase_state_dir "$phase")
    local timestamp_file="$state_dir/experiment_timestamp"

    # Read phase plan to check if timestamp_suffix is enabled
    local plan_file="$SCRIPT_DIR/experiment-plans/$phase.json"
    if [ ! -f "$plan_file" ]; then
        echo ""
        return
    fi

    local timestamp_enabled
    timestamp_enabled=$(python3 -c "import json; plan = json.load(open('$plan_file')); print(plan.get('mlflow_config', {}).get('timestamp_suffix', False))" 2>/dev/null || echo "False")

    if [ "$timestamp_enabled" != "True" ]; then
        echo ""
        return
    fi

    # If timestamp file exists, read it
    if [ -f "$timestamp_file" ]; then
        cat "$timestamp_file"
    else
        # Generate new timestamp
        mkdir -p "$state_dir"
        local new_timestamp
        new_timestamp=$(date -u '+%Y%m%d-%H%M%S')
        echo "$new_timestamp" > "$timestamp_file"
        echo "$new_timestamp"
    fi
}

reset_experiment_timestamp() {
    local phase="$1"
    local state_dir
    state_dir=$(get_phase_state_dir "$phase")
    rm -f "$state_dir/experiment_timestamp"
    info "Experiment timestamp reset for $phase"
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
    local phase="$3"
    local extra_env="$4"  # Optional: additional environment variables
    local json_name
    json_name=$(basename "$json_path")

    # Determine the S3 key for this task definition
    # json_path is like: .../task-definitions/phase14/p14-unified-1k.json
    # or .../task-definitions/phase14/consumer/p14-efa-4k-consumer.json
    local relative_path="${json_path#*task-definitions/}"
    local s3_task_key="tasks/$relative_path"

    # Get experiment timestamp for this phase
    local exp_timestamp
    exp_timestamp=$(get_experiment_timestamp "$phase")

    log "Running $json_name on instance: $instance_id"

    # Build environment variable exports
    local env_exports="export NODE1_PRIVATE='$NODE1_PRIVATE' NODE2_PRIVATE='$NODE2_PRIVATE'"
    if [ -n "$exp_timestamp" ]; then
        env_exports="$env_exports MLFLOW_EXPERIMENT_TIMESTAMP='$exp_timestamp'"
        info "Using experiment timestamp: $exp_timestamp"
    fi

    # Extract PEER_IP from extra_env if present (format: "PEER_IP='172.31.47.40'")
    local peer_ip=""
    if [ -n "$extra_env" ]; then
        env_exports="$env_exports $extra_env"
        peer_ip=$(echo "$extra_env" | sed -n "s/.*PEER_IP='\([^']*\)'.*/\1/p")
    fi

    # Prepare commands array
    local commands=(
        "aws s3 cp s3://$SCRIPTS_BUCKET/scripts/task_runner.sh /tmp/"
        "aws s3 cp s3://$SCRIPTS_BUCKET/scripts/benchmark_common.py /tmp/"
        "aws s3 cp s3://$SCRIPTS_BUCKET/scripts/disagg_proxy_server.py /tmp/ 2>/dev/null || true"
        "mkdir -p /tmp/scripts"
        "aws s3 sync s3://$SCRIPTS_BUCKET/scripts/ /tmp/scripts/ --exclude 'task_runner.sh' --exclude 'benchmark_common.py' --exclude 'disagg_proxy_server.py'"
        "aws s3 cp s3://$SCRIPTS_BUCKET/$s3_task_key /tmp/$json_name"
    )

    # Add PEER_IP override if needed
    if [ -n "$peer_ip" ]; then
        commands+=("jq '.variables.PEER_IP = \"$peer_ip\"' /tmp/$json_name > /tmp/${json_name}.tmp && mv /tmp/${json_name}.tmp /tmp/$json_name")
    fi

    commands+=(
        "chmod +x /tmp/task_runner.sh"
        "runuser ubuntu -c \"$env_exports && bash /tmp/task_runner.sh /tmp/$json_name --reset\""
    )

    if ssm_run_command "$instance_id" "${commands[@]}"; then
        success "$json_name completed on $instance_id"
        return 0
    else
        echo -e "${RED}[ERROR]${NC} $json_name failed on $instance_id"
        return 1
    fi
}

run_single_pattern() {
    local phase="$1"
    local pattern_id="$2"
    local task_dir="$SCRIPT_DIR/task-definitions/$phase"
    local producer_dir="$task_dir/producer"
    local consumer_dir="$task_dir/consumer"
    local client_dir="$task_dir/client"
    local baseline_dir="$task_dir/baseline"

    # Determine if this is a baseline pattern
    local producer_json
    if [[ "$pattern_id" == p*-baseline-* ]]; then
        # Baseline pattern: check baseline/ subdirectory
        if [ -f "$baseline_dir/$pattern_id.json" ]; then
            producer_json="$baseline_dir/$pattern_id.json"
        elif [ -f "$baseline_dir/$pattern_id-server.json" ]; then
            # Baseline dual-node (server)
            producer_json="$baseline_dir/$pattern_id-server.json"
            client_json="$baseline_dir/$pattern_id-client.json"
        else
            error "Baseline task definition not found: $baseline_dir/$pattern_id.json or $baseline_dir/$pattern_id-server.json"
        fi
    else
        # Regular pattern: check producer/ subdirectory first, then fallback to root
        if [ -f "$producer_dir/$pattern_id.json" ]; then
            producer_json="$producer_dir/$pattern_id.json"
        elif [ -f "$task_dir/$pattern_id.json" ]; then
            producer_json="$task_dir/$pattern_id.json"
        else
            error "Producer task definition not found: $producer_dir/$pattern_id.json or $task_dir/$pattern_id.json"
        fi
        consumer_json="$consumer_dir/$pattern_id.json"
        client_json="$client_dir/$pattern_id-client.json"
    fi

    if [ ! -f "$producer_json" ]; then
        error "Task definition not found: $producer_json"
    fi

    if [ -f "$client_json" ]; then
        # Dual-node (baseline or low-level): Run Server on Node1, Client on Node2
        if [[ "$pattern_id" == p*-baseline-* ]]; then
            info "Baseline dual-node pattern detected. Running Server on Node1, Client on Node2."
        else
            info "Low-level dual-node pattern detected. Running Server on Node1, Client on Node2."
        fi
        echo ""

        log "Starting Server on Node1 ($NODE1_ID)..."
        run_task_on_node "$producer_json" "$NODE1_ID" "$phase" "PEER_IP='$NODE2_PRIVATE'" &
        local server_pid=$!

        # Wait for server to start before launching client
        log "Waiting 10 seconds for server to start..."
        sleep 10

        log "Starting Client on Node2 ($NODE2_ID)..."
        if run_task_on_node "$client_json" "$NODE2_ID" "$phase" "PEER_IP='$NODE1_PRIVATE'"; then
            # Wait for Server to complete
            wait $server_pid 2>/dev/null || true
            success "Pattern $pattern_id completed (dual-node)"
        else
            echo -e "${RED}[ERROR]${NC} Pattern $pattern_id failed, but continuing..."
            return 1
        fi
    elif [ -f "$consumer_json" ]; then
        # Disaggregated: Run Consumer first, then Producer
        info "Disaggregated pattern detected. Running Consumer first, then Producer."
        echo ""

        log "Starting Consumer on Node2 ($NODE2_ID)..."
        run_task_on_node "$consumer_json" "$NODE2_ID" "$phase" &
        local consumer_pid=$!

        # Wait for Consumer to initialize before starting Producer
        log "Waiting 30 seconds for Consumer to start initializing..."
        sleep 30

        log "Starting Producer on Node1 ($NODE1_ID)..."
        if run_task_on_node "$producer_json" "$NODE1_ID" "$phase"; then
            # Wait for Consumer to complete
            wait $consumer_pid 2>/dev/null || true
            success "Pattern $pattern_id completed"
        else
            echo -e "${RED}[ERROR]${NC} Pattern $pattern_id failed, but continuing..."
            return 1
        fi
    else
        # Unified: Run on Node1
        info "Unified pattern detected. Running on Node1 ($NODE1_ID)."
        if run_task_on_node "$producer_json" "$NODE1_ID" "$phase"; then
            success "Pattern $pattern_id completed"
        else
            echo -e "${RED}[ERROR]${NC} Pattern $pattern_id failed, but continuing..."
            return 1
        fi
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
    patterns=$(python3 - "$plan_file" "$layer_id" <<'PYEOF'
import json, sys
plan_file = sys.argv[1]
layer_id = sys.argv[2]
with open(plan_file) as f:
    plan = json.load(f)
for layer in plan['layers']:
    if layer.get('id') == layer_id:
        for p in layer['patterns']:
            print(p['id'])
        sys.exit(0)
print('LAYER_NOT_FOUND', file=sys.stderr)
sys.exit(1)
PYEOF
    )

    if [ $? -ne 0 ]; then
        error "Layer $layer_id not found in $plan_file"
    fi

    local pattern_count
    pattern_count=$(echo "$patterns" | wc -l)
    info "Layer $layer_id: $pattern_count patterns"
    echo ""

    local idx=0
    local failed_count=0
    while IFS= read -r pattern_id; do
        idx=$((idx + 1))
        echo ""
        log "=== Pattern $idx/$pattern_count: $pattern_id ==="
        if run_single_pattern "$phase" "$pattern_id"; then
            echo "" # Success logged by run_single_pattern
        else
            failed_count=$((failed_count + 1))
            echo -e "${YELLOW}[WARNING]${NC} Pattern $pattern_id failed, continuing with next pattern..."
        fi
    done <<< "$patterns"

    echo ""
    if [ $failed_count -eq 0 ]; then
        success "Layer $layer_id completed ($pattern_count patterns, all succeeded)"
    else
        echo -e "${YELLOW}[WARNING]${NC} Layer $layer_id completed with $failed_count failures ($((pattern_count - failed_count))/$pattern_count succeeded)"
    fi
}

run_all_layers() {
    local phase="$1"
    local plan_file="$SCRIPT_DIR/experiment-plans/$phase.json"

    if [ ! -f "$plan_file" ]; then
        error "Experiment plan not found: $plan_file"
    fi

    # Extract layer IDs in order
    local layer_ids
    layer_ids=$(python3 - "$plan_file" <<'PYEOF'
import json, sys
plan_file = sys.argv[1]
with open(plan_file) as f:
    plan = json.load(f)
for layer in plan['layers']:
    print(layer.get('id', ''))
PYEOF
    )

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

# ---- Collect Results ----

ssm_download_results() {
    local instance_id="$1"
    local remote_dir="$2"
    local local_dir="$3"
    local node_name="$4"

    log "Collecting results from $node_name ($instance_id)..."

    # List result files on remote node
    local file_list
    file_list=$(ssm_run_command "$instance_id" \
        "ls -1 $remote_dir/*.json 2>/dev/null || echo 'NO_FILES'") || true

    if [ "$file_list" = "NO_FILES" ] || [ -z "$file_list" ]; then
        info "No result files found on $node_name at $remote_dir"
        return 0
    fi

    # Copy each result file via S3 as intermediary
    local count=0
    while IFS= read -r remote_file; do
        [ -z "$remote_file" ] && continue
        local filename
        filename=$(basename "$remote_file")
        local s3_key="results-transfer/$node_name/$filename"

        # Upload from remote node to S3
        ssm_run_command "$instance_id" \
            "aws s3 cp $remote_file s3://$SCRIPTS_BUCKET/$s3_key --quiet" || {
            echo "[WARNING] Failed to upload $filename from $node_name"
            continue
        }

        # Download from S3 to local
        aws s3 cp "s3://$SCRIPTS_BUCKET/$s3_key" "$local_dir/$filename" --quiet || {
            echo "[WARNING] Failed to download $filename from S3"
            continue
        }

        count=$((count + 1))
    done <<< "$file_list"

    success "Collected $count result files from $node_name"
}

do_collect_results() {
    local phase="$1"
    local results_dir="$SCRIPT_DIR/results/$phase"

    mkdir -p "$results_dir"

    log "Collecting results for $phase..."

    # Collect from Node1
    ssm_download_results "$NODE1_ID" "/tmp/low-level-results" "$results_dir" "Node1"

    # Collect from Node2
    ssm_download_results "$NODE2_ID" "/tmp/low-level-results" "$results_dir" "Node2"

    echo ""
    local total
    total=$(find "$results_dir" -name "*.json" 2>/dev/null | wc -l)
    success "Total result files collected: $total"
    info "Results directory: $results_dir"

    if [ "$total" -gt 0 ]; then
        echo ""
        echo "Collected files:"
        find "$results_dir" -name "*.json" -printf '  %f\n' | sort
    fi
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
        python3 - "$plan_file" "$task_dir" <<'PYEOF'
import json, os, sys
plan_file = sys.argv[1]
task_dir = sys.argv[2]
with open(plan_file) as f:
    plan = json.load(f)
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
PYEOF
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
    collect-results)
        do_collect_results "$PHASE"
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
