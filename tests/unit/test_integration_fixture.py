"""Validate that fixture adaptation cannot silently mask production boundaries."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('integration_fixture', SOURCE / 'tests/integration/fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def production():
    services = {}
    for name, networks in {
        'quota-guard': ['egress', 'uplink'],
        'gateway-ui': ['control', 'ui'],
        'openclaw-gateway': ['egress', 'control', 'mcp'],
        'openclaw-cli': ['egress', 'control'],
        'sandbox-dind': ['sandbox'],
        'target-gateway': ['target', 'target-uplink'],
        'pentest-tools-mcp': ['mcp', 'target'],
    }.items():
        services[name] = {'image': 'production:tag', 'container_name': 'clawshell-' + name,
                          'networks': {n: {} for n in networks},
                          'secrets': ['production-credential'], 'environment': {'SECRET': 'must-not-leak'},
                          'volumes': [{'type':'bind', 'source':'/real/host/path', 'target':'/app'},
                                      {'type':'bind', 'source':'/real/engagement',
                                       'target':'/home/node/workspace/engagement', 'read_only': True}],
                          'profiles': ['production']}
    services['gateway-ui']['ports'] = [{'target': 18789, 'published': '18789'}]
    return {'services': services, 'networks': {
        name: {'driver': 'bridge', 'internal': name not in ('uplink', 'target-uplink', 'ui'),
               'name': 'production-' + name}
        for name in {n for service in services.values() for n in service['networks']}}}


class FixtureTests(unittest.TestCase):
    def build(self, source=None, **kwargs):
        with tempfile.TemporaryDirectory() as temp:
            return fixture.build_config(source or production(), SOURCE, Path(temp), 'clawshell-test-unit', **kwargs)

    def test_no_credentials_or_production_mounts_or_fixed_names(self):
        config, _, _ = self.build()
        for service in config['services'].values():
            self.assertNotIn('secrets', service)
            self.assertNotIn('container_name', service)
            self.assertNotIn('SECRET', service.get('environment', {}))
            self.assertNotIn('/real/host/path', str(service.get('volumes', [])))
        self.assertNotIn('secrets', config)
        for network in config['networks'].values():
            self.assertNotIn('name', network)

    def test_external_control_network_is_rejected_before_adaptation(self):
        config = production()
        config['networks']['control']['internal'] = False
        with self.assertRaisesRegex(ValueError, 'unmediated external network'):
            self.build(config)

    def test_cli_can_share_the_isolated_gateway_namespace(self):
        config = production()
        del config['services']['openclaw-cli']['networks']
        config['services']['openclaw-cli']['network_mode'] = 'service:openclaw-gateway'
        self.build(config)

    def test_host_network_mode_is_rejected(self):
        config = production()
        config['services']['openclaw-cli']['network_mode'] = 'host'
        with self.assertRaisesRegex(ValueError, 'unsupported shared/host network mode'):
            self.build(config)

    def test_production_writable_engagement_cannot_be_masked_by_fixture(self):
        config = production()
        config['services']['openclaw-gateway']['volumes'][1]['read_only'] = False
        with self.assertRaisesRegex(ValueError, 'engagement inputs read-only'):
            self.build(config)

    def test_production_host_socket_mount_cannot_be_masked_by_fixture(self):
        config = production()
        config['services']['openclaw-gateway']['volumes'].append(
            {'type': 'bind', 'source': '/var/run/docker.sock', 'target': '/socket'})
        with self.assertRaisesRegex(ValueError, 'sensitive host mount'):
            self.build(config)

    def test_ingress_port_is_published_on_relay_not_gateway(self):
        config, _, _ = self.build()
        self.assertFalse(config['services']['openclaw-gateway'].get('ports'))
        self.assertEqual(config['services']['gateway-ui']['ports'], ['127.0.0.1::18789'])
        self.assertIn('ui', config['services']['gateway-ui']['networks'])
        self.assertNotIn('ui', config['services']['openclaw-gateway']['networks'])

    def test_agent_cannot_join_ingress_external_network(self):
        config = production()
        config['services']['pentest-tools-mcp']['networks']['ui'] = {}
        with self.assertRaisesRegex(ValueError, 'unmediated external network'):
            self.build(config)

    def test_exposed_proxy_control_ports_rejected(self):
        config = production()
        config['services']['quota-guard']['ports'] = [{'target': 8088, 'published': '8088'}]
        with self.assertRaisesRegex(ValueError, 'publishes a boundary'):
            self.build(config)

    def test_existing_external_docker_networks_rejected(self):
        config = production()
        config['networks']['uplink']['external'] = True
        with self.assertRaisesRegex(ValueError, 'project-owned bridge'):
            self.build(config)

    def test_probe_preserves_production_network_membership(self):
        source = production()
        config, _, _ = self.build(source)
        self.assertEqual(config['services']['openclaw-gateway']['networks'],
                         source['services']['openclaw-gateway']['networks'])
        self.assertEqual(config['services']['pentest-tools-mcp']['networks'],
                         source['services']['pentest-tools-mcp']['networks'])
        self.assertTrue(config['networks']['fixture-upstream']['internal'])

    def test_publicly_classified_uplink_is_required_for_real_ssrf_guard(self):
        with self.assertRaisesRegex(ValueError, 'globally classified'):
            self.build(subnet='192.168.77.0/24')

    def test_recovery_worker_cannot_access_network_or_host_socket(self):
        config, _, _ = self.build()
        worker = config['services']['recovery-worker']
        self.assertEqual(worker['network_mode'], 'none')
        self.assertEqual(worker['volumes'], ['recovery-data:/fixture'])
