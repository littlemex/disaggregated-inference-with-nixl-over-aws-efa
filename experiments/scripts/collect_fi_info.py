#!/usr/bin/env python3
"""
Collect EFA device information using fi_info and ibv_devices.
"""
import argparse
import json
import subprocess
import os


def main():
    parser = argparse.ArgumentParser(description='Collect EFA device information')
    parser.add_argument('--pattern-id', required=True, help='Pattern ID')
    parser.add_argument('--phase', required=True, help='Phase number')
    parser.add_argument('--timestamp', required=True, help='Timestamp')
    parser.add_argument('--output', required=True, help='Output JSON file path')
    args = parser.parse_args()

    result = {
        'pattern_id': args.pattern_id,
        'phase': args.phase,
        'tool': 'fi_info',
        'timestamp': args.timestamp,
        'hostname': subprocess.getoutput('hostname'),
        'measurements': {}
    }

    # fi_info output
    fi_info_file = '/tmp/fi_info_efa_raw.txt'
    if os.path.exists(fi_info_file):
        with open(fi_info_file) as f:
            result['measurements']['fi_info_efa'] = {
                'command': 'fi_info -p efa',
                'output': f.read().strip(),
                'status': 'collected'
            }

    # ibv_devices output
    ibv_file = '/tmp/ibv_devices_raw.txt'
    if os.path.exists(ibv_file):
        with open(ibv_file) as f:
            result['measurements']['ibv_devices'] = {
                'command': 'ibv_devices',
                'output': f.read().strip(),
                'status': 'collected'
            }

    # EFA device count
    try:
        efa_count = subprocess.getoutput('fi_info -p efa 2>/dev/null | grep -c efa || echo 0')
        result['measurements']['efa_device_count'] = int(efa_count.strip())
    except:
        result['measurements']['efa_device_count'] = 0

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)

    print(f"[OK] Results saved to {args.output}")


if __name__ == '__main__':
    main()
