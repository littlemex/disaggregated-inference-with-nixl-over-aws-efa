#!/usr/bin/env python3
"""
Collect ib_write_bw (perftest) bandwidth measurement results.

This script replaces collect_fi_rdm_bw.py to use perftest's ib_write_bw tool.
"""

import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone


def parse_ib_write_bw_output(text: str) -> dict:
    """Parse ib_write_bw output to extract bandwidth results."""
    results = {
        "tool": "ib_write_bw",
        "raw_output": text,
        "bandwidth_data": [],
    }

    # Parse table data
    # Example line: " 65536       41943         8.00              0.00      5244.60"
    lines = text.split('\n')
    for line in lines:
        if line.strip() and not line.startswith('#') and not line.startswith(' bytes'):
            parts = line.split()
            if len(parts) >= 5:
                try:
                    row = {
                        'bytes': int(parts[0]),
                        'iterations': int(parts[1]),
                        'bandwidth_avg_mbps': float(parts[3]),
                        'msg_rate': float(parts[4]) if len(parts) > 4 else None,
                    }
                    results['bandwidth_data'].append(row)
                except (ValueError, IndexError):
                    pass

    # Calculate max bandwidth
    if results['bandwidth_data']:
        results['max_bandwidth_mbps'] = max(r['bandwidth_avg_mbps'] for r in results['bandwidth_data'])

    return results


def main():
    parser = argparse.ArgumentParser(
        description='Collect ib_write_bw bandwidth measurement results'
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

    # Read ib_write_bw output
    raw_file = '/tmp/ib_write_bw_raw.txt'
    if os.path.exists(raw_file):
        with open(raw_file, 'r') as f:
            raw_output = f.read()
    else:
        raw_output = '[ERROR] Output file not found'

    # Parse results
    parsed = parse_ib_write_bw_output(raw_output)

    # Build result JSON
    result = {
        'pattern_id': args.pattern_id,
        'phase': args.phase,
        'tool': 'ib_write_bw',
        'timestamp': args.timestamp,
        'hostname': hostname,
        'node_role': args.node_role,
        'peer_ip': args.peer_ip,
        'measurements': parsed,
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
