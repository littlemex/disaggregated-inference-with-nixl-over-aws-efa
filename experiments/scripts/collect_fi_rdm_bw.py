#!/usr/bin/env python3
"""
Collect EFA RDMA bandwidth test results from fi_rdm_bw.
"""
import argparse
import json
import subprocess
import os
import re


def main():
    parser = argparse.ArgumentParser(description='Collect fi_rdm_bw results')
    parser.add_argument('--pattern-id', required=True, help='Pattern ID')
    parser.add_argument('--phase', required=True, help='Phase number')
    parser.add_argument('--timestamp', required=True, help='Timestamp')
    parser.add_argument('--output', required=True, help='Output JSON file path')
    parser.add_argument('--node-role', required=True, choices=['server', 'client'], help='Node role')
    parser.add_argument('--peer-ip', default='', help='Peer IP address')
    args = parser.parse_args()

    result = {
        'pattern_id': args.pattern_id,
        'phase': args.phase,
        'tool': 'fi_rdm_bw',
        'timestamp': args.timestamp,
        'hostname': subprocess.getoutput('hostname'),
        'node_role': args.node_role,
        'peer_ip': args.peer_ip,
        'measurements': {}
    }

    raw_file = '/tmp/fi_rdm_bw_raw.txt'
    if os.path.exists(raw_file):
        with open(raw_file) as f:
            raw_output = f.read().strip()
        result['measurements']['raw_output'] = raw_output

        # Parse bandwidth values from output
        bw_values = []
        for line in raw_output.split('\n'):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    size = int(parts[0])
                    bw = float(parts[-1])
                    bw_values.append({'message_size_bytes': size, 'bandwidth_mbps': bw})
                except (ValueError, IndexError):
                    pass

        if bw_values:
            result['measurements']['bandwidth_data'] = bw_values
            result['measurements']['max_bandwidth_mbps'] = max(v['bandwidth_mbps'] for v in bw_values)
        result['measurements']['status'] = 'collected'
    else:
        result['measurements']['status'] = 'no_output'

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)

    print(f"[OK] Results saved to {args.output}")


if __name__ == '__main__':
    main()
