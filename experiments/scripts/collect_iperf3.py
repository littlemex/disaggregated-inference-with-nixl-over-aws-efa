#!/usr/bin/env python3
"""
Collect TCP bandwidth test results from iperf3.
"""
import argparse
import json
import subprocess
import os


def main():
    parser = argparse.ArgumentParser(description='Collect iperf3 results')
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
        'tool': 'iperf3',
        'timestamp': args.timestamp,
        'hostname': subprocess.getoutput('hostname'),
        'node_role': args.node_role,
        'measurements': {}
    }

    if args.node_role == 'server':
        # Server-side results
        result['measurements']['role'] = 'server'
        result['measurements']['status'] = 'collected'
        result['measurements']['note'] = 'Server-side results. Client-side has detailed bandwidth data.'

        raw_file = '/tmp/iperf3_server_raw.txt'
        if os.path.exists(raw_file):
            with open(raw_file) as f:
                result['measurements']['raw_output'] = f.read().strip()[:10000]
    else:
        # Client-side results
        result['peer_ip'] = args.peer_ip

        for p_count, raw_file in [('1', '/tmp/iperf3_p1_raw.json'),
                                    ('4', '/tmp/iperf3_p4_raw.json'),
                                    ('8', '/tmp/iperf3_p8_raw.json')]:
            entry = {'parallel_streams': int(p_count), 'duration_sec': 30}
            if os.path.exists(raw_file):
                try:
                    with open(raw_file) as f:
                        iperf_data = json.load(f)
                    if 'end' in iperf_data and 'sum_sent' in iperf_data['end']:
                        entry['bits_per_second'] = iperf_data['end']['sum_sent'].get('bits_per_second', 0)
                        entry['gbps'] = round(entry['bits_per_second'] / 1e9, 2)
                        entry['bytes_transferred'] = iperf_data['end']['sum_sent'].get('bytes', 0)
                    if 'end' in iperf_data and 'sum_received' in iperf_data['end']:
                        entry['received_bits_per_second'] = iperf_data['end']['sum_received'].get('bits_per_second', 0)
                        entry['received_gbps'] = round(entry['received_bits_per_second'] / 1e9, 2)
                    entry['status'] = 'collected'
                    entry['raw_json'] = iperf_data
                except (json.JSONDecodeError, KeyError) as e:
                    entry['status'] = 'parse_error'
                    entry['error'] = str(e)
                    with open(raw_file) as f:
                        entry['raw_output'] = f.read().strip()[:5000]
            else:
                entry['status'] = 'no_output'
            result['measurements'][f'parallel_{p_count}'] = entry

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(result, f, indent=2)

    print(f"[OK] Results saved to {args.output}")


if __name__ == '__main__':
    main()
