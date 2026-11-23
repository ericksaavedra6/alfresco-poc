import copy
import datetime
import importlib.util
import pathlib
import re
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_plan', ROOT / 'scripts/check-plan.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class ResourceProtectionTests(unittest.TestCase):
    def setUp(self):
        self.instance = {
            'limits': {'cpu': '4', 'memory': '10GB'},
            'device': [
                {'name': 'root', 'type': 'disk', 'properties': {'size': '150GB', 'pool': 'local', 'path': '/'}},
                {'name': 'microk8s-certs-dir', 'type': 'disk', 'properties': {'source': '/var/lib/alfresco-poc/microk8s-certs', 'path': '/mnt/microk8s-certs'}},
            ],
            'config': {'user.user-data': 'previous bootstrap'},
        }
        self.plan = {'resource_changes': [{
            'address': 'lxd_instance.alfresco_app',
            'type': 'lxd_instance',
            'change': {'actions': ['update'], 'before': copy.deepcopy(self.instance), 'after': copy.deepcopy(self.instance)},
        }]}
        self.change = self.plan['resource_changes'][0]['change']

    def test_allows_cloud_init_update(self):
        self.change['after']['config']['user.user-data'] = 'fixed bootstrap'
        self.assertEqual(guard.validate(self.plan), [])

    def test_rejects_delete_and_replacement(self):
        for actions in (['delete'], ['delete', 'create'], ['create', 'delete']):
            with self.subTest(actions=actions):
                self.change['actions'] = actions
                self.assertTrue(guard.validate(self.plan))

    def test_rejects_cpu_and_memory_changes(self):
        for key, value in (('cpu', '8'), ('memory', '16GB')):
            with self.subTest(key=key):
                self.change['after'] = copy.deepcopy(self.instance)
                self.change['after']['limits'][key] = value
                self.assertTrue(guard.validate(self.plan))

    def test_rejects_disk_resize(self):
        self.change['after']['device'][0]['properties']['size'] = '200GB'
        self.assertTrue(guard.validate(self.plan))

    def test_rejects_disk_removal_and_host_mount_change(self):
        self.change['after']['device'].pop()
        self.assertTrue(guard.validate(self.plan))
        self.change['after'] = copy.deepcopy(self.instance)
        self.change['after']['device'][1]['properties']['source'] = '/different-directory'
        self.assertTrue(guard.validate(self.plan))

    def test_device_order_is_irrelevant(self):
        self.change['after']['device'].reverse()
        self.assertEqual(guard.validate(self.plan), [])


class NodeConfigurationTests(unittest.TestCase):
    def test_repeated_configuration_preserves_existing_sans(self):
        script = (ROOT / 'scripts/bootstrap-instance.sh').read_text()
        match = re.search(r'python3 - "\$data" "\$NODE_IP" "\$API_ADDRESS" <<\'PY\'\n(.*?)\nPY', script, re.S)
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'args').mkdir()
            (root / 'certs').mkdir()
            (root / 'args/kubelet').write_text('--node-ip=10.0.0.1\n--node-ip=10.0.0.2\n--other-flag=yes\n')
            csr = root / 'certs/csr.conf.template'
            csr.write_text('[ alt_names ]\nDNS.1 = kubernetes\nIP.1 = 127.0.0.1\nIP.2 = 10.152.183.1\nIP.3 = 10.0.0.99\n[ next_section ]\nkey = value\n')
            command = [sys.executable, '-', folder, '10.146.220.55', '192.168.50.100']
            subprocess.run(command, input=match.group(1), text=True, check=True)
            first = csr.read_text()
            subprocess.run(command, input=match.group(1), text=True, check=True)
            self.assertEqual(csr.read_text(), first)
            self.assertIn('IP.3 = 10.0.0.99', first)
            self.assertIn('IP.4 = 10.146.220.55', first)
            self.assertIn('IP.5 = 192.168.50.100', first)
            kubelet = (root / 'args/kubelet').read_text()
            self.assertEqual(kubelet.count('--node-ip='), 1)
            self.assertIn('--other-flag=yes', kubelet)

    def test_fresh_heartbeat_passes_and_stale_heartbeat_fails(self):
        script = (ROOT / 'scripts/verify-instance.sh').read_text()
        checker = script.split("-o json | python3 -c '\n", 1)[1].split("\n'", 1)[0]
        for age, expected in ((5, 0), (300, 1)):
            with self.subTest(age=age):
                renewed = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)
                leases = {'items': [{'metadata': {'name': 'test-node'}, 'spec': {'renewTime': renewed.isoformat()}}]}
                result = subprocess.run([sys.executable, '-c', checker], input=json.dumps(leases), text=True, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_empty_heartbeat_list_is_not_accepted(self):
        script = (ROOT / 'scripts/verify-instance.sh').read_text()
        checker = script.split("-o json | python3 -c '\n", 1)[1].split("\n'", 1)[0]
        result = subprocess.run([sys.executable, '-c', checker], input='{"items": []}', text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
