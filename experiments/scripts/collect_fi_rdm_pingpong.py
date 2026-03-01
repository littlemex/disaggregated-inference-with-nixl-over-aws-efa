#!/usr/bin/env python3
"""
Collect EFA latency test results from fi_rdm_pingpong.
"""
import argparse
import json
import subprocess
import os


def main():
    parser = argparse.ArgumentParser(description='Collect fi_rdm_pingpong results')
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
        'tool': 'fi_rdm_pingpong',
        'timestamp': args.timestamp,
        'hostname': subprocess.getoutput('hostname'),
        'node_role': args.node_role,
        'peer_ip': args.peer_ip,
        'measurements': {}
    }

    sizes = {
        '64': '/tmp/pingpong_64_raw.txt',
        '1024': '/tmp/pingpong_1k_raw.txt',
        '65536': '/tmp/pingpong_64k_raw.txt',
        '1048576': '/tmp/pingpong_1m_raw.txt'
    }

    for size_label, raw_file in sizes.items():
        if os.path.exists(raw_file):
            with open(raw_file) as f:
                raw_output = f.read().strip()
            entry = {
                'command': f'fi_rdm_pingpong -p efa -S {size_label}',
                'message_size_bytes': int(size_label),
                'raw_output': raw_output,
                'status': 'collected'
            }
            # Parse latency from output (typical format: 'bytes #sent #recv latency')
            for line in raw_output.split('\n'):
                parts = line.split()
                if len(parts) >= 4:
                    try:
                        latency = float(parts[-1])
                        entry['latency_usec'] = latency
                    except (ValueError, IndexError):
                        pass
            result['measurements'][f'size_{size_label}'] = entry
        else:
            result['measurements'][f'size_{size_label}'] = {'status': 'no_output'}

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)

    print(f"[OK] Results saved to {args.output}")


if __name__ == '__main__':
    main()
