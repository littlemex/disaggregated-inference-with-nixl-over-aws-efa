#!/bin/bash
##
## Environment Check Script - Verify GPU instance environment
##
## This script checks that the deployed EC2 instance has all necessary
## components for disaggregated inference experiments:
## - EFA (Elastic Fabric Adapter)
## - GPU and drivers
## - vLLM installation
## - NIXL library
## - NCCL tests
## - MLflow connectivity
## - Network connectivity between nodes
##

set -uo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0

# Helper functions
print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

print_check() {
    echo -n "[CHECK] $1... "
}

print_pass() {
    echo -e "${GREEN}[OK]${NC}"
    ((CHECKS_PASSED++))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC}"
    echo "  Error: $1"
    ((CHECKS_FAILED++))
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC}"
    echo "  $1"
}

# Check functions
check_efa() {
    print_header "1. EFA (Elastic Fabric Adapter) Check"

    print_check "EFA device presence"
    if [ -e /dev/infiniband/uverbs0 ]; then
        print_pass
    else
        print_fail "EFA device /dev/infiniband/uverbs0 not found"
        return
    fi

    print_check "EFA interface"
    if ip link show | grep -q efa; then
        EFA_INTERFACE=$(ip link show | grep efa | awk '{print $2}' | tr -d ':' | head -1)
        echo "  Interface: $EFA_INTERFACE"
        print_pass
    else
        print_fail "EFA network interface not found"
        return
    fi

    print_check "fi_info availability"
    if command -v fi_info &> /dev/null; then
        print_pass
        echo "  Available providers:"
        fi_info -l 2>/dev/null | grep -E "provider|version" | head -5 || true
    else
        print_fail "fi_info command not found (libfabric not installed?)"
    fi
}

check_gpu() {
    print_header "2. GPU Check"

    print_check "nvidia-smi availability"
    if command -v nvidia-smi &> /dev/null; then
        print_pass
    else
        print_fail "nvidia-smi not found"
        return
    fi

    print_check "GPU devices"
    GPU_COUNT=$(nvidia-smi -L | wc -l)
    if [ "$GPU_COUNT" -gt 0 ]; then
        print_pass
        echo "  Found $GPU_COUNT GPU(s):"
        nvidia-smi -L | sed 's/^/  /'
    else
        print_fail "No GPU devices found"
    fi

    print_check "CUDA availability"
    if nvidia-smi > /dev/null 2>&1; then
        CUDA_VERSION=$(nvidia-smi | grep "CUDA Version" | awk '{print $9}')
        print_pass
        echo "  CUDA Version: $CUDA_VERSION"
    else
        print_fail "CUDA not available"
    fi
}

check_vllm() {
    print_header "3. vLLM Installation Check"

    print_check "vLLM Python package"
    if python3 -c "import vllm" 2>/dev/null; then
        VLLM_VERSION=$(python3 -c "import vllm; print(vllm.__version__)" 2>/dev/null || echo "unknown")
        print_pass
        echo "  vLLM version: $VLLM_VERSION"
    else
        print_fail "vLLM package not found"
    fi

    print_check "vLLM CLI"
    if command -v vllm &> /dev/null; then
        print_pass
    else
        print_warning "vllm command not found (may be in virtual environment)"
    fi
}

check_nixl() {
    print_header "4. NIXL Library Check"

    print_check "NIXL Python package"
    if python3 -c "import nixl" 2>/dev/null; then
        print_pass
        NIXL_VERSION=$(python3 -c "import nixl; print(nixl.__version__)" 2>/dev/null || echo "unknown")
        echo "  NIXL version: $NIXL_VERSION"
    else
        print_fail "NIXL package not found"
        echo "  Install with: pip install nixl"
    fi
}

check_nccl() {
    print_header "5. NCCL Tests Check"

    NCCL_TESTS_DIR="/opt/nccl-tests"

    print_check "NCCL tests installation"
    if [ -d "$NCCL_TESTS_DIR" ] && [ -f "$NCCL_TESTS_DIR/build/all_reduce_perf" ]; then
        print_pass
        echo "  Location: $NCCL_TESTS_DIR"
    else
        print_fail "NCCL tests not installed"
        echo "  Run: sudo bash $(dirname "$0")/setup-nccl-tests.sh"
        return
    fi

    print_check "NCCL all_reduce_perf"
    if [ -x "$NCCL_TESTS_DIR/build/all_reduce_perf" ]; then
        print_pass
    else
        print_fail "all_reduce_perf not executable"
    fi

    print_check "NCCL all_gather_perf"
    if [ -x "$NCCL_TESTS_DIR/build/all_gather_perf" ]; then
        print_pass
    else
        print_fail "all_gather_perf not executable"
    fi
}

check_mlflow() {
    print_header "6. MLflow Connectivity Check"

    print_check "MLflow Python package"
    if python3 -c "import mlflow" 2>/dev/null; then
        MLFLOW_VERSION=$(python3 -c "import mlflow; print(mlflow.__version__)" 2>/dev/null || echo "unknown")
        print_pass
        echo "  MLflow version: $MLFLOW_VERSION"
    else
        print_fail "MLflow package not found"
        return
    fi

    print_check "MLFLOW_TRACKING_ARN environment variable"
    if [ -n "${MLFLOW_TRACKING_ARN:-}" ]; then
        print_pass
        echo "  ARN: ${MLFLOW_TRACKING_ARN}"
    else
        print_fail "MLFLOW_TRACKING_ARN not set"
        return
    fi

    print_check "MLflow connectivity"
    # Use the test-mlflow.py script if available
    if [ -f "$(dirname "$0")/test-mlflow.py" ]; then
        if python3 "$(dirname "$0")/test-mlflow.py" --experiment-name "env-check-test" > /tmp/mlflow-check.log 2>&1; then
            print_pass
            echo "  Successfully connected to MLflow tracking server"
        else
            print_fail "Failed to connect to MLflow tracking server"
            echo "  See /tmp/mlflow-check.log for details"
        fi
    else
        print_warning "test-mlflow.py not found, skipping connectivity test"
    fi
}

check_network() {
    print_header "7. Network Connectivity Check"

    print_check "Private IP address"
    PRIVATE_IP=$(hostname -I | awk '{print $1}')
    if [ -n "$PRIVATE_IP" ]; then
        print_pass
        echo "  Private IP: $PRIVATE_IP"
    else
        print_fail "Could not determine private IP"
    fi

    print_check "Internet connectivity"
    if ping -c 1 -W 5 8.8.8.8 > /dev/null 2>&1; then
        print_pass
    else
        print_fail "No internet connectivity"
    fi

    # Check peer connectivity if NODE2_PRIVATE_IP is set
    if [ -n "${NODE2_PRIVATE_IP:-}" ]; then
        print_check "Connectivity to peer node ($NODE2_PRIVATE_IP)"
        if ping -c 3 -W 5 "$NODE2_PRIVATE_IP" > /dev/null 2>&1; then
            print_pass
        else
            print_fail "Cannot reach peer node at $NODE2_PRIVATE_IP"
        fi
    fi
}

check_system_info() {
    print_header "System Information"

    echo "Hostname: $(hostname)"
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "Kernel: $(uname -r)"
    echo "Uptime: $(uptime -p)"
    echo ""
    echo "Memory:"
    free -h | grep -E "Mem|Swap"
    echo ""
    echo "Disk:"
    df -h / | tail -1
}

# Main execution
main() {
    print_header "Environment Check for Disaggregated Inference with NIXL over AWS EFA"

    check_system_info
    check_efa
    check_gpu
    check_vllm
    check_nixl
    check_nccl
    check_mlflow
    check_network

    # Summary
    print_header "Summary"
    echo "Checks passed: $CHECKS_PASSED"
    echo "Checks failed: $CHECKS_FAILED"
    echo ""

    if [ "$CHECKS_FAILED" -eq 0 ]; then
        echo -e "${GREEN}All checks passed! Environment is ready for experiments.${NC}"
        exit 0
    else
        echo -e "${RED}Some checks failed. Please review the output above.${NC}"
        exit 1
    fi
}

main "$@"
