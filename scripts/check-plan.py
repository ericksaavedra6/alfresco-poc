#!/usr/bin/env python3
"""Reject destructive plans and any change to this POC's VM capacity or disks."""
import json
import sys


def disk_devices(instance):
    return sorted(
        (device for device in instance.get('device', []) if device['type'] == 'disk'),
        key=lambda device: device['name'],
    )


def validate(plan):
    errors = []
    for resource in plan.get('resource_changes', []):
        change = resource['change']
        address = resource['address']
        if 'delete' in change['actions']:
            errors.append(f'{address}: deletion/replacement is forbidden')
        if resource['type'] != 'lxd_instance' or change.get('after') is None:
            continue
        before, after = change.get('before'), change['after']
        if after.get('limits') != {'cpu': '4', 'memory': '10GB'}:
            errors.append(f'{address}: expected unchanged CPU=4 and memory=10GB')
        roots = [device for device in disk_devices(after) if device['name'] == 'root']
        if len(roots) != 1 or roots[0].get('properties', {}).get('size') != '150GB':
            errors.append(f'{address}: expected unchanged root disk=150GB')
        if before is not None:
            if before.get('limits') != after.get('limits'):
                errors.append(f'{address}: VM limits differ from the existing instance')
            if disk_devices(before) != disk_devices(after):
                errors.append(f'{address}: changing disk devices is forbidden')
    return errors


if __name__ == '__main__':
    failures = validate(json.load(sys.stdin))
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        sys.exit(1)
    print('Plan accepted: no deletions, replacements, capacity changes or disk changes')
