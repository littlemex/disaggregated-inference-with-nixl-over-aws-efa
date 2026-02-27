# Experiment System

Unified experiment management for Disaggregated Inference with NIXL over EFA.

## Architecture

```
experiments/
  experiment-plans/        # Experiment plan JSON (version controlled)
    phase14.json           # Phase 14 experiment plan
    phase15.json           # Phase 15 experiment plan
  templates/               # Jinja2 templates (version controlled)
    unified.json.jinja2
    disaggregated-producer.json.jinja2
    disaggregated-consumer.json.jinja2
  scripts/                 # Shared scripts (version controlled)
    benchmark_common.py    # Phase-agnostic benchmark script
    disagg_proxy_server.py # Disaggregated proxy server
  lib/                     # Helper scripts (version controlled)
    ssm-deploy.sh          # S3 file transfer helper
    ssm-run.sh             # SSM send-command execution helper
  generate_tasks.py        # Task definition generator
  run_experiment.sh        # Unified experiment runner (SSM-based)
  task-definitions/        # Auto-generated (NOT version controlled)
    phase14/
    phase15/
  results/                 # Measurement results (NOT version controlled)
    phase14/
    phase15/
```

## Quick Start

### 1. Generate Task Definitions

```bash
cd experiments
./generate_tasks.py phase14
```

This reads `experiment-plans/phase14.json` and generates JSON task definitions
in `task-definitions/phase14/`.

### 2. Set Environment Variables

```bash
# S3 bucket name (from CDK Output)
export SCRIPTS_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name NixlEfaStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ScriptsBucketName`].OutputValue' \
  --output text)

# Instance IDs (from tags)
export NODE1_ID=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

export NODE2_ID=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Private IPs (from tags)
export NODE1_PRIVATE=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

export NODE2_PRIVATE=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

# Verify
echo "SCRIPTS_BUCKET: $SCRIPTS_BUCKET"
echo "NODE1_ID: $NODE1_ID"
echo "NODE2_ID: $NODE2_ID"
echo "NODE1_PRIVATE: $NODE1_PRIVATE"
echo "NODE2_PRIVATE: $NODE2_PRIVATE"
```

### Connection Method

- **File transfer**: Via S3 (no SSH key required)
- **Command execution**: AWS SSM send-command (no SSH key required)
- **Interactive connection**: AWS SSM Session Manager

SSH keys are not used at all.

### 3. Deploy Scripts

```bash
./run_experiment.sh phase14 deploy
```

### 4. Run Experiments

```bash
# Run a specific layer
./run_experiment.sh phase14 run L0

# Run a single pattern
./run_experiment.sh phase14 run p14-unified-1k

# Run all layers
./run_experiment.sh phase14 run all
```

### 5. Check Status

```bash
./run_experiment.sh phase14 status
./run_experiment.sh phase14 list
```

## Adding a New Phase

To add Phase 16 (or any new phase):

1. Create experiment plan:
   ```bash
   # Create experiments/experiment-plans/phase16.json
   # Follow the schema of phase14.json or phase15.json
   ```

2. Generate and run:
   ```bash
   ./generate_tasks.py phase16
   ./run_experiment.sh phase16 deploy
   ./run_experiment.sh phase16 run all
   ```

No code changes required. The templates and scripts are Phase-agnostic.

## Experiment Plan JSON Schema

```json
{
  "phase": 16,
  "name": "Phase Name",
  "description": "Phase description",
  "infrastructure": {
    "instance_type": "g5.12xlarge",
    "node_count": 2,
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "vllm_version": "v0.15.1",
    "venv_path": "/opt/dlami/nvme/venv/vllm-0.16",
    "gpu_count_per_node": 4,
    "tp_size": 1
  },
  "common_settings": {
    "max_tokens": 10,
    "warmup_iterations": 20,
    "measurement_iterations": 30,
    "gpu_memory_utilization": 0.9,
    "max_num_batched_tokens": 4096,
    "measurement_type": "online"
  },
  "layers": [
    {
      "id": "L0",
      "name": "Layer Name",
      "priority": "P0",
      "description": "Layer description",
      "patterns": [
        {
          "id": "p16-unified-4k-c1",
          "backend": "unified",
          "prompt_tokens": 4000,
          "concurrency": 1
        }
      ]
    }
  ]
}
```

### Pattern Fields

| Field | Required | Description |
|-------|----------|-------------|
| id | Yes | Unique ID with phase prefix (e.g., p16-unified-4k) |
| backend | Yes | "unified", "tcp", or "efa" |
| prompt_tokens | Yes | Number of prompt tokens |
| concurrency | Yes | Number of concurrent requests |
| prefix_cache | No | Override common_settings (true/false) |
| gpu_memory_utilization | No | Override common_settings |
| max_num_batched_tokens | No | Override common_settings |
| max_model_len | No | Override (auto-computed from prompt_tokens) |
| measurement_type | No | Override common_settings ("online"/"offline") |

### Naming Convention

Pattern IDs follow: `p{phase}-{layer-optional}-{backend}-{tokens}-c{concurrency}`

Examples:
- `p14-unified-4k` (Phase 14, unified, 4K tokens)
- `p15-L0-efa-4k-c1` (Phase 15, Layer 0, EFA, 4K tokens, c=1)
- `p16-tcp-20k-c4` (Phase 16, TCP, 20K tokens, c=4)

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| SCRIPTS_BUCKET | S3 bucket name (from CDK Output) | Yes |
| NODE1_ID | Instance ID of Node 1 | Yes (for deploy/run) |
| NODE2_ID | Instance ID of Node 2 | Yes (for deploy/run) |
| NODE1_PRIVATE | Private IP of Node 1 | Yes (for run) |
| NODE2_PRIVATE | Private IP of Node 2 | Yes (for run) |

## Troubleshooting

### Task definitions not generated

```bash
# Check if experiment plan exists
ls experiment-plans/

# List available plans
./generate_tasks.py --list

# Dry run to see what would be generated
./generate_tasks.py phase14 --dry-run
```

### SSM command fails

```bash
# Verify SSM agent is running on the instance
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$NODE1_ID" \
  --query 'InstanceInformationList[0].PingStatus'

# Check if instance has proper IAM role
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$NODE1_ID"

# Check recent command history
aws ssm list-commands \
  --instance-id "$NODE1_ID" \
  --max-results 5
```

### vLLM server not starting

```bash
# Check logs via SSM Session Manager
aws ssm start-session --target "$NODE1_ID"
# Then on the instance:
#   cat /tmp/vllm_*.log | tail -50
#   nvidia-smi
```

### Health check timeout

The health check waits up to 120 seconds. For large models (32B+),
initialization can take 180+ seconds. Check the vLLM logs for progress.

## Design Principles

1. **Phase namespace separation**: All JSON names, result files, and MLflow
   experiments include the phase number
2. **Auto-generated files are NOT version controlled**: Task definitions and
   results can be regenerated from experiment plans
3. **Unified interface**: Same commands for all phases
4. **Forward compatibility**: Adding Phase 16/17 does not affect existing phases
5. **Single task runner**: All remote execution goes through task_runner.sh
   (see setup/DESIGN.md)
6. **No SSH keys**: All file transfer and command execution via S3 + SSM
