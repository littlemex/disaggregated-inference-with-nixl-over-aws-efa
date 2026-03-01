#!/usr/bin/env python3
"""
Collect NCCL all_reduce_perf test results.
"""
import argparse
import json
import subprocess
import os
import re


def main():
    parser = argparse.ArgumentParser(description='Collect NCCL test results')
    parser.add_argument('--pattern-id', required=True, help='Pattern ID')
    parser.add_argument('--phase', required=True, help='Phase number')
    parser.add_argument('--timestamp', required=True, help='Timestamp')
    parser.add_argument('--output', required=True, help='Output JSON file path')
    parser.add_argument('--min-size', default='1M', help='NCCL min size')
    parser.add_argument('--max-size', default='1G', help='NCCL max size')
    parser.add_argument('--factor', default='2', help='NCCL factor')
    parser.add_argument('--ngpus', default='4', help='Number of GPUs')
    args = parser.parse_args()

    result = {
        'pattern_id': args.pattern_id,
        'phase': args.phase,
        'tool': 'nccl-tests',
        'timestamp': args.timestamp,
        'hostname': subprocess.getoutput('hostname'),
        'config': {
            'min_size': args.min_size,
            'max_size': args.max_size,
            'factor': args.factor,
            'ngpus': args.ngpus
        },
        'measurements': {}
    }

    raw_file = '/tmp/nccl_allreduce_raw.txt'
    if os.path.exists(raw_file):
        with open(raw_file) as f:
            raw_output = f.read().strip()
        result['measurements']['raw_output'] = raw_output

        # Parse NCCL output table
        data_rows = []
        for line in raw_output.split('\n'):
            line = line.strip()
            if line.startswith('#') or line.startswith('nccl') or not line:
                continue
            parts = line.split()
            if len(parts) >= 8:
                try:
                    row = {
                        'size_bytes': int(parts[0]),
                        'count': int(parts[1]),
                        'type': parts[2],
                        'redop': parts[3],
                        'time_us': float(parts[4]),
                        'algbw_gbps': float(parts[5]),
                        'busbw_gbps': float(parts[6])
                    }
                    data_rows.append(row)
                except (ValueError, IndexError):
                    pass

        if data_rows:
            result['measurements']['allreduce_data'] = data_rows
            result['measurements']['max_algbw_gbps'] = max(r['algbw_gbps'] for r in data_rows)
            result['measurements']['max_busbw_gbps'] = max(r['busbw_gbps'] for r in data_rows)
        result['measurements']['status'] = 'collected'
    else:
        result['measurements']['status'] = 'no_output'

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)

    print(f"[OK] Results saved to {args.output}")


if __name__ == '__main__':
    main()
