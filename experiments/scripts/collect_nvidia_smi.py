#!/usr/bin/env python3
"""
Collect GPU information using nvidia-smi.
"""
import argparse
import json
import subprocess
import os
import re


def main():
    parser = argparse.ArgumentParser(description='Collect GPU information')
    parser.add_argument('--pattern-id', required=True, help='Pattern ID')
    parser.add_argument('--phase', required=True, help='Phase number')
    parser.add_argument('--timestamp', required=True, help='Timestamp')
    parser.add_argument('--output', required=True, help='Output JSON file path')
    args = parser.parse_args()

    result = {
        'pattern_id': args.pattern_id,
        'phase': args.phase,
        'tool': 'nvidia-smi',
        'timestamp': args.timestamp,
        'hostname': subprocess.getoutput('hostname'),
        'measurements': {}
    }

    # nvidia-smi -q output
    q_file = '/tmp/nvidia_smi_q_raw.txt'
    if os.path.exists(q_file):
        with open(q_file) as f:
            q_output = f.read().strip()
        result['measurements']['nvidia_smi_query'] = {
            'command': 'nvidia-smi -q',
            'output': q_output[:20000],
            'status': 'collected'
        }

        # Parse basic info
        gpu_count = len(re.findall(r'GPU \d+', q_output))
        driver_match = re.search(r'Driver Version\s*:\s*(\S+)', q_output)
        cuda_match = re.search(r'CUDA Version\s*:\s*(\S+)', q_output)
        gpu_name_match = re.search(r'Product Name\s*:\s*(.+)', q_output)

        result['measurements']['summary'] = {
            'gpu_count': gpu_count if gpu_count > 0 else 'unknown',
            'driver_version': driver_match.group(1) if driver_match else 'unknown',
            'cuda_version': cuda_match.group(1) if cuda_match else 'unknown',
            'gpu_name': gpu_name_match.group(1).strip() if gpu_name_match else 'unknown'
        }

    # nvidia-smi topo -m output
    topo_file = '/tmp/nvidia_smi_topo_raw.txt'
    if os.path.exists(topo_file):
        with open(topo_file) as f:
            result['measurements']['topology'] = {
                'command': 'nvidia-smi topo -m',
                'output': f.read().strip(),
                'status': 'collected'
            }

    # nvidia-smi dmon output
    dmon_file = '/tmp/nvidia_smi_dmon_raw.txt'
    if os.path.exists(dmon_file):
        with open(dmon_file) as f:
            result['measurements']['dmon'] = {
                'command': 'nvidia-smi dmon -s pucvmet -d 1',
                'sample_duration_sec': 5,
                'output': f.read().strip(),
                'status': 'collected'
            }

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)

    print(f"[OK] Results saved to {args.output}")


if __name__ == '__main__':
    main()
