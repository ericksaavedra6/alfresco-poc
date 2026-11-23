#!/usr/bin/env python3
"""Reject destructive plans and any change to this POC's VM capacity or disks."""
import json
import sys
import argparse
import pathlib


def disk_devices(instance):
    return sorted(
        (device for device in (instance.get('device') or []) if device['type'] == 'disk'),
        key=lambda device: device['name'],
    )


def has_unknown(value):
    if isinstance(value, dict):
        return any(has_unknown(item) for item in value.values())
    if isinstance(value, list):
        return any(has_unknown(item) for item in value)
    return value is True


def validate(plan, resources=None):
    errors = []
    if resources is not None:
        if resources.get('name') != 'alfresco-poc-app' or resources.get('limits') != {'cpu': '4', 'memory': '10GB'}:
            errors.append('Live LXD baseline does not match the protected VM capacity')
        live_roots = [disk for disk in resources.get('disks', []) if disk['name'] == 'root']
        if len(live_roots) != 1 or live_roots[0].get('properties', {}).get('size') != '150GB':
            errors.append('Live LXD baseline does not match the protected 150GB root disk')
    for resource in plan.get('resource_changes', []):
        change = resource['change']
        address = resource['address']
        if 'delete' in change['actions']:
            errors.append(f'{address}: deletion/replacement is forbidden')
        if resource['type'] != 'lxd_instance' or change.get('after') is None:
            continue
        before, after = change.get('before'), change['after']
        if has_unknown(change.get('after_unknown', {}).get('device', False)):
            errors.append(f'{address}: unknown device configuration is forbidden')
        if after.get('limits') != {'cpu': '4', 'memory': '10GB'}:
            errors.append(f'{address}: expected unchanged CPU=4 and memory=10GB')
        roots = [device for device in disk_devices(after) if device['name'] == 'root']
        # Imported instances can have empty device state. In that case devices
        # must stay empty/ignored, with hardware checked directly against LXD.
        imported_devices_ignored = (
            resources is not None and before is not None
            and not disk_devices(before) and not disk_devices(after)
        )
        if not imported_devices_ignored and (len(roots) != 1 or roots[0].get('properties', {}).get('size') != '150GB'):
            errors.append(f'{address}: expected unchanged root disk=150GB')
        if before is not None:
            if before.get('limits') != after.get('limits'):
                errors.append(f'{address}: VM limits differ from the existing instance')
            if disk_devices(before) != disk_devices(after):
                errors.append(f'{address}: changing disk devices is forbidden')
    return errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--resources', type=pathlib.Path, required=True)
    args = parser.parse_args()
    failures = validate(json.load(sys.stdin), json.loads(args.resources.read_text()))
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        sys.exit(1)
    print('Plan accepted: no deletions, replacements, capacity changes or disk changes')
