"""Derive a credential-free test stack from rendered production Compose config."""
from copy import deepcopy
import ipaddress
from pathlib import Path

SERVICES = ('quota-guard', 'openclaw-gateway', 'target-gateway', 'pentest-tools-mcp')


def validate_topology(production):
    for name in ('openclaw-gateway', 'openclaw-cli', 'sandbox-dind', 'pentest-tools-mcp'):
        service = production['services'][name]
        mode = service.get('network_mode')
        if mode:
            if mode != 'service:openclaw-gateway':
                raise ValueError(f'{name} has an unsupported shared/host network mode: {mode}')
            service = production['services']['openclaw-gateway']
        for network in service['networks']:
            if production['networks'][network].get('internal') is not True:
                raise ValueError(f'{name} has an unmediated external network: {network}')
    for name in ('openclaw-gateway', 'openclaw-cli'):
        service = production['services'][name]
        mounts = service.get('volumes', [])
        engagement = [mount for mount in mounts if mount.get('target') == '/home/node/workspace/engagement']
        if not engagement or any(not mount.get('read_only') for mount in engagement):
            raise ValueError(f'{name} must mount engagement inputs read-only')
        for mount in mounts:
            source, target = mount.get('source', ''), mount.get('target', '')
            if ('docker.sock' in source or 'docker.sock' in target or
                    source in ('/', '/run', '/var/run', '/var/lib/docker', '/etc/shadow', '/root/.ssh')):
                raise ValueError(f'{name} exposes a sensitive host mount: {source}')
    for name in ('quota-guard', 'target-gateway', 'pentest-tools-mcp'):
        if production['services'][name].get('ports'):
            raise ValueError(f'{name} publishes a boundary/control port')
    for name, network in production['networks'].items():
        if network.get('external') or network.get('driver', 'bridge') != 'bridge':
            raise ValueError(f'Integration runner requires project-owned bridge networks: {name}')


def build_config(production, source, work, project, subnet='11.203.71.0/24'):
    validate_topology(production)
    source, work = Path(source), Path(work)
    network = ipaddress.ip_network(subnet)
    if network.version != 4 or network.prefixlen != 24 or not network[10].is_global:
        raise ValueError('Test uplink must be a globally classified IPv4 /24; see tests/integration/README.md')
    provider_ip, target_ip = str(network[10]), str(network[11])
    services = {name: deepcopy(production['services'][name]) for name in SERVICES}
    required_networks = {name for service in services.values() for name in service['networks']}
    networks = {name: deepcopy(production['networks'][name]) for name in required_networks}
    for value in networks.values():
        value.pop('name', None)
    # External targets live on a Docker-internal simulated uplink. This is
    # intentionally separate from the application's actual egress networks.
    # Gateway/MCP network policies are copied unchanged, never weakened for tests.
    networks['fixture-upstream'] = {'internal': True, 'ipam': {'config': [{'subnet': subnet}]}}
    for name, service in services.items():
        service.pop('container_name', None)
        service.pop('profiles', None)
        service.pop('restart', None)
        service.pop('ports', None)
        service.pop('secrets', None)
        service['environment'] = {}
        if name != 'openclaw-gateway':
            service['build'] = {'context': str(source / name)}
            service['image'] = f'{project}/{name}:test'
        if 'healthcheck' in service:
            service['healthcheck'].update(interval='2s', timeout='3s', retries=30, start_period='3s')
    qg = services['quota-guard']
    qg['volumes'] = [
        'recovery-data:/state', 'qg-logs:/logs',
        f'{work}/allowlist.conf:/config/allowlist.conf:ro', f'{work}/allowlist.d:/allowlist.d:ro']
    qg['networks']['fixture-upstream'] = {}
    qg['extra_hosts'] = {'provider.test': provider_ip, 'private-provider.test': '127.0.0.1', 'unstable-provider.test': provider_ip, 'denied-provider.test': provider_ip}
    qg['environment'] = {'QUOTA_GUARD_FAILURE_THRESHOLD': '2',
                         'QUOTA_GUARD_STATE_DIR': '/state/state/quota-guard'}
    target = services['target-gateway']
    target['volumes'] = ['target-state:/state', 'target-logs:/logs', f'{work}/scope:/scope:ro']
    target['networks']['fixture-upstream'] = {}
    target['extra_hosts'] = {'target.test': target_ip, 'private-target.test': '127.0.0.1', 'out-of-scope.test': target_ip}
    target['environment'] = {'BLACKBOX_LIVE_TESTING': 'true', 'TARGET_RATE_DEFAULT': '1000'}
    mcp = services['pentest-tools-mcp']
    mcp['volumes'] = [f'{source}/tests/integration/probe.py:/probe.py:ro']
    mcp['environment'] = {'BLACKBOX_LIVE_TESTING': 'true', 'TARGET_GATEWAY_PROXY': 'http://target-gateway:8080'}
    gateway = services['openclaw-gateway']
    gateway['image'] = 'python:3.12-slim'
    gateway.pop('depends_on', None)
    gateway['entrypoint'] = ['python3', '-m', 'http.server', '18789', '--bind', '0.0.0.0', '--directory', '/tmp']
    gateway.pop('command', None)
    gateway['healthcheck'] = {'test': ['CMD', 'python3', '-c',
        "import urllib.request;urllib.request.urlopen('http://127.0.0.1:18789',timeout=2)"],
        'interval': '2s', 'timeout': '3s', 'retries': 30}
    gateway['ports'] = ['127.0.0.1::18789']
    gateway['volumes'] = [f'{source}/tests/integration/probe.py:/probe.py:ro',
                          f'{work}/engagement:/home/node/workspace/engagement:ro',
                          f'{work}/workspaces:/home/node/workspace/reports']
    mock_base = {'image': 'python:3.12-slim', 'read_only': True, 'tmpfs': ['/tmp'],
                 'cap_drop': ['ALL'], 'security_opt': ['no-new-privileges:true'], 'user': '1000:1000',
                 'volumes': [f'{source}/tests/integration/mock_http.py:/mock_http.py:ro'],
                 'entrypoint': ['python3', '/mock_http.py'],
                 'healthcheck': {'test': ['CMD', 'python3', '-c',
                   "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/stats',timeout=2)"],
                   'interval': '2s', 'timeout': '3s', 'retries': 30}}
    for name, address in [('provider', provider_ip), ('target', target_ip)]:
        services[name] = deepcopy(mock_base)
        services[name]['networks'] = {'fixture-upstream': {'ipv4_address': address}}
    services['recovery-worker'] = {
        'build': {'context': str(source), 'dockerfile': 'tests/integration/Dockerfile.recovery'},
        'image': f'{project}/recovery-worker:test', 'network_mode': 'none',
        'profiles': ['maintenance'], 'volumes': ['recovery-data:/fixture']}
    return {'name': project, 'services': services, 'networks': networks,
            'volumes': {name: {} for name in ('recovery-data', 'qg-logs', 'target-state', 'target-logs')}}, provider_ip, target_ip
