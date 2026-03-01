#!/usr/bin/env python3
"""
Collect ib_write_lat (perftest) latency measurement results.

This script replaces collect_fi_rdm_pingpong.py to use perftest's ib_write_lat tool.
Measures latency for 4 message sizes: 64, 1024, 65536, 1048576 bytes.
"""

import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone


def parse_ib_write_lat_output(text: str) -> dict:
    """Parse ib_write_lat output to extract latency results."""
    results = {
        "tool": "ib_write_lat",
        "raw_output": text,
        "latency_data": [],
    }

    # Parse table data
    # Example line: " 65536       5000         7.42              5.23          7.51"
    lines = text.split('\n')
    for line in lines:
        if line.strip() and not line.startswith('#') and not line.startswith(' bytes'):
            parts = line.split()
            if len(parts) >= 4:
                try:
                    row = {
                        'bytes': int(parts[0]),
                        'iterations': int(parts[1]),
                        'latency_avg_us': float(parts[2]),
                        'latency_median_us': float(parts[3]) if len(parts) > 3 else None,
                        'latency_max_us': float(parts[4]) if len(parts) > 4 else None,
                    }
                    results['latency_data'].append(row)
                except (ValueError, IndexError):
                    pass

    return results


def main():
    parser = argparse.ArgumentParser(
        description='Collect ib_write_lat latency measurement results'
    )
    parser.add_argument('--pattern-id', required=True, help='Pattern ID')
    parser.add_argument('--phase', required=True, help='Phase number')
    parser.add_argument('--timestamp', required=True, help='Timestamp')
    parser.add_argument('--output', required=True, help='Output JSON file path')
    parser.add_argument('--node-role', required=True, help='Node role (server/client)')
    parser.add_argument('--peer-ip', required=True, help='Peer IP address')
    args = parser.parse_args()

    # Get hostname
    hostname = subprocess.getoutput('hostname')

    # Read output for each message size
    sizes = [
        ('64', 64, '/tmp/pingpong_64_raw.txt'),
        ('1k', 1024, '/tmp/pingpong_1k_raw.txt'),
        ('64k', 65536, '/tmp/pingpong_64k_raw.txt'),
        ('1m', 1048576, '/tmp/pingpong_1m_raw.txt'),
    ]

    measurements = {}
    for size_name, size_bytes, raw_file in sizes:
        if os.path.exists(raw_file):
            with open(raw_file, 'r') as f:
                raw_output = f.read()
        else:
            raw_output = '[SKIP]'

        parsed = parse_ib_write_lat_output(raw_output)
        measurements[f'size_{size_name}'] = {
            'command': f'ib_write_lat -d rdmap49s0 -s {size_bytes} -F',
            'message_size_bytes': size_bytes,
            'raw_output': parsed['raw_output'],
            'latency_data': parsed['latency_data'],
            'status': 'collected' if parsed['latency_data'] else 'skipped',
        }

    # Build result JSON
    result = {
        'pattern_id': args.pattern_id,
        'phase': args.phase,
        'tool': 'ib_write_lat',
        'timestamp': args.timestamp,
        'hostname': hostname,
        'node_role': args.node_role,
        'peer_ip': args.peer_ip,
        'measurements': measurements,
    }

    # Write output
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)

    print(f'[OK] Results saved to {args.output}')
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main())
