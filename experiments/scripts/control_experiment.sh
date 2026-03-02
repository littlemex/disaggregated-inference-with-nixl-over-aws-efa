#!/bin/bash
# Phase 2 Experiment Controller - Start, stop, and manage experiments
# Usage: ./control_experiment.sh [start|stop|restart|status|collect] [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default values
ACTION=""
ENV_FILE="/tmp/phase2_env.sh"
LOG_DIR="/tmp/phase2_logs"
LAYER=""
PATTERN=""
DRY_RUN=0

# Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_CYAN="\033[36m"

# Usage
usage() {
    cat <<EOF
Usage: $0 <action> [options]

Actions:
  start     Start experiment (or resume from checkpoint)
  stop      Stop running experiment
  restart   Restart experiment from beginning
  status    Show experiment status
  collect   Collect results from remote nodes

Options:
  --env FILE         Environment file (default: $ENV_FILE)
  --log-dir DIR      Log directory (default: $LOG_DIR)
  --layer LAYER      Target layer (L0-Baseline, L1-Unified, L2-EFA, L3-TCP, L4-Analysis)
  --pattern NAME     Target pattern name
  --dry-run          Show what would be done without executing

Examples:
  # Start experiment
  $0 start --env /tmp/phase2_env.sh

  # Start specific layer
  $0 start --layer L2-EFA

  # Stop experiment
  $0 stop

  # Show status
  $0 status

  # Collect results
  $0 collect --log-dir /tmp/phase2_results
EOF
    exit 1
}

# Parse arguments
if [ $# -eq 0 ]; then
    usage
fi

ACTION="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --layer)
            LAYER="$2"
            shift 2
            ;;
        --pattern)
            PATTERN="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Load environment
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${C_RED}[ERROR]${C_RESET} Environment file not found: $ENV_FILE"
    echo "Please run infrastructure setup first."
    exit 1
fi

source "$ENV_FILE"

# Validate required variables
if [ -z "${NODE1_IP:-}" ] || [ -z "${NODE2_IP:-}" ]; then
    echo -e "${C_RED}[ERROR]${C_RESET} NODE1_IP or NODE2_IP not set in $ENV_FILE"
    exit 1
fi

# Check SSH connectivity
check_ssh() {
    local node_ip="$1"
    local node_name="$2"

    if ssh -o ConnectTimeout=5 -o BatchMode=yes "ubuntu@$node_ip" "echo 2>&1" >/dev/null 2>&1; then
        echo -e "${C_GREEN}[OK]${C_RESET} $node_name ($node_ip) is reachable"
        return 0
    else
        echo -e "${C_RED}[ERROR]${C_RESET} $node_name ($node_ip) is not reachable"
        return 1
    fi
}

# Start experiment
start_experiment() {
    echo -e "${C_BOLD}=== Starting Phase 2 Experiment ===${C_RESET}"
    echo ""

    # Check connectivity
    echo -e "${C_CYAN}[INFO]${C_RESET} Checking node connectivity..."
    check_ssh "$NODE1_IP" "Node 1" || exit 1
    check_ssh "$NODE2_IP" "Node 2" || exit 1
    echo ""

    # Create log directory
    mkdir -p "$LOG_DIR"

    # Prepare experiment command
    local layer_opt=""
    if [ -n "$LAYER" ]; then
        layer_opt="--layer $LAYER"
    fi

    local pattern_opt=""
    if [ -n "$PATTERN" ]; then
        pattern_opt="--pattern $PATTERN"
    fi

    local experiment_cmd="cd /home/ubuntu/experiments && ./run_phase2.sh $layer_opt $pattern_opt"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${C_YELLOW}[DRY RUN]${C_RESET} Would execute on Node 1:"
        echo "  $experiment_cmd"
        return 0
    fi

    # Start experiment on Node 1
    local log_file="$LOG_DIR/phase2_$(date +%Y%m%d_%H%M%S).log"
    echo -e "${C_CYAN}[INFO]${C_RESET} Starting experiment on Node 1..."
    echo -e "${C_CYAN}[INFO]${C_RESET} Logs: $log_file"
    echo ""

    ssh "ubuntu@$NODE1_IP" "$experiment_cmd" 2>&1 | tee "$log_file" &
    local pid=$!

    echo "$pid" > "$LOG_DIR/experiment.pid"
    echo -e "${C_GREEN}[OK]${C_RESET} Experiment started (PID: $pid)"
    echo ""
    echo "Monitor progress with:"
    echo "  $SCRIPT_DIR/monitor_experiment.sh --log $log_file --follow"
}

# Stop experiment
stop_experiment() {
    echo -e "${C_BOLD}=== Stopping Phase 2 Experiment ===${C_RESET}"
    echo ""

    if [ -f "$LOG_DIR/experiment.pid" ]; then
        local pid=$(cat "$LOG_DIR/experiment.pid")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${C_CYAN}[INFO]${C_RESET} Stopping local process (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            rm -f "$LOG_DIR/experiment.pid"
            echo -e "${C_GREEN}[OK]${C_RESET} Local process stopped"
        else
            echo -e "${C_YELLOW}[WARNING]${C_RESET} Local process not running"
            rm -f "$LOG_DIR/experiment.pid"
        fi
    else
        echo -e "${C_YELLOW}[WARNING]${C_RESET} No PID file found"
    fi

    # Stop processes on remote nodes
    echo ""
    echo -e "${C_CYAN}[INFO]${C_RESET} Stopping processes on remote nodes..."

    for node_ip in "$NODE1_IP" "$NODE2_IP"; do
        echo -e "${C_CYAN}[INFO]${C_RESET} Stopping on $node_ip..."
        ssh "ubuntu@$node_ip" "pkill -f 'python.*vllm' || true; pkill -f 'run_phase2' || true" || true
    done

    echo -e "${C_GREEN}[OK]${C_RESET} Experiment stopped on all nodes"
}

# Restart experiment
restart_experiment() {
    echo -e "${C_BOLD}=== Restarting Phase 2 Experiment ===${C_RESET}"
    echo ""

    stop_experiment
    sleep 3
    start_experiment
}

# Show status
show_status() {
    echo -e "${C_BOLD}=== Phase 2 Experiment Status ===${C_RESET}"
    echo ""

    # Local process
    if [ -f "$LOG_DIR/experiment.pid" ]; then
        local pid=$(cat "$LOG_DIR/experiment.pid")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${C_GREEN}[RUNNING]${C_RESET} Local process (PID: $pid)"
        else
            echo -e "${C_YELLOW}[STOPPED]${C_RESET} Local process (stale PID file)"
            rm -f "$LOG_DIR/experiment.pid"
        fi
    else
        echo -e "${C_YELLOW}[STOPPED]${C_RESET} No local process"
    fi

    echo ""

    # Remote processes
    echo -e "${C_CYAN}[INFO]${C_RESET} Checking remote nodes..."
    for node_ip in "$NODE1_IP" "$NODE2_IP"; do
        local node_name="Node 1"
        if [ "$node_ip" = "$NODE2_IP" ]; then
            node_name="Node 2"
        fi

        local count=$(ssh "ubuntu@$node_ip" "pgrep -f 'python.*vllm' | wc -l" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo -e "  ${C_GREEN}[RUNNING]${C_RESET} $node_name ($node_ip): $count vllm processes"
        else
            echo -e "  ${C_YELLOW}[IDLE]${C_RESET} $node_name ($node_ip): no vllm processes"
        fi
    done

    echo ""

    # Latest log
    if [ -d "$LOG_DIR" ]; then
        local latest_log=$(ls -t "$LOG_DIR"/phase2_*.log 2>/dev/null | head -1)
        if [ -n "$latest_log" ]; then
            echo -e "${C_CYAN}[INFO]${C_RESET} Latest log: $latest_log"
            echo ""
            echo "Monitor with:"
            echo "  $SCRIPT_DIR/monitor_experiment.sh --log $latest_log --follow"
        fi
    fi
}

# Collect results
collect_results() {
    echo -e "${C_BOLD}=== Collecting Experiment Results ===${C_RESET}"
    echo ""

    mkdir -p "$LOG_DIR/collected"

    for node_ip in "$NODE1_IP" "$NODE2_IP"; do
        local node_name="node1"
        if [ "$node_ip" = "$NODE2_IP" ]; then
            node_name="node2"
        fi

        echo -e "${C_CYAN}[INFO]${C_RESET} Collecting from $node_name ($node_ip)..."

        # Collect logs
        local remote_logs="/home/ubuntu/experiments/logs"
        if ssh "ubuntu@$node_ip" "test -d $remote_logs" 2>/dev/null; then
            rsync -avz --progress "ubuntu@$node_ip:$remote_logs/" "$LOG_DIR/collected/${node_name}_logs/" || true
        fi

        # Collect results
        local remote_results="/home/ubuntu/experiments/results"
        if ssh "ubuntu@$node_ip" "test -d $remote_results" 2>/dev/null; then
            rsync -avz --progress "ubuntu@$node_ip:$remote_results/" "$LOG_DIR/collected/${node_name}_results/" || true
        fi
    done

    echo ""
    echo -e "${C_GREEN}[OK]${C_RESET} Results collected to: $LOG_DIR/collected/"
    echo ""
    echo "Files:"
    find "$LOG_DIR/collected" -type f | head -20
}

# Main
case "$ACTION" in
    start)
        start_experiment
        ;;
    stop)
        stop_experiment
        ;;
    restart)
        restart_experiment
        ;;
    status)
        show_status
        ;;
    collect)
        collect_results
        ;;
    *)
        echo -e "${C_RED}[ERROR]${C_RESET} Unknown action: $ACTION"
        usage
        ;;
esac
