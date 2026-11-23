#!/usr/bin/env python3
"""Read only VM capacity/disks from LXD, omitting all cloud-init/credential data."""
import argparse
import json
import pathlib
import sys


def snapshot(response):
    instance = response.get('metadata', response)
    config = instance.get('expanded_config', instance.get('config', {}))
    devices = instance.get('expanded_devices', instance.get('devices', {}))
    return {
        'name': instance['name'],
        'limits': {'cpu': config.get('limits.cpu'), 'memory': config.get('limits.memory')},
        'disks': sorted([
            {'name': name, 'type': 'disk', 'properties': {key: value for key, value in device.items() if key != 'type'}}
            for name, device in devices.items() if device.get('type') == 'disk'
        ], key=lambda device: device['name']),
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--compare', type=pathlib.Path)
    args = parser.parse_args()
    actual = snapshot(json.load(sys.stdin))
    if args.compare:
        if actual != json.loads(args.compare.read_text()):
            raise SystemExit('LXD CPU, memory or disk configuration changed from the protected baseline')
        print('LXD capacity and disk devices are unchanged')
    else:
        json.dump(actual, sys.stdout)
        print()
