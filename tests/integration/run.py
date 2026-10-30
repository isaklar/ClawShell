#!/usr/bin/env python3
"""Real Docker security integration suite. No production stack or credentials used."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

from fixture import build_config

SOURCE = Path(__file__).resolve().parents[2]
PROBE = SOURCE / 'tests/integration/probe.py'


def check(condition, message):
    if not condition:
        raise AssertionError(message)


class Stack:
    def __init__(self, work, artifacts):
        self.work = work
        self.project = 'clawshell-test-' + uuid.uuid4().hex[:12]
        self.artifacts = artifacts / self.project
        self.path = work / 'compose.json'
        self.results = []

    def command(self, *args, input=None, timeout=90):
        result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f'Command failed ({result.returncode}): {args}\n{result.stdout}\n{result.stderr}')
        return result.stdout.strip()

    def compose(self, *args, **kwargs):
        return self.command('docker', 'compose', '-p', self.project, '-f', str(self.path), *args, **kwargs)

    def exec(self, service, code, *args, user=None):
        options = ['exec', '-T']
        if user:
            options += ['--user', user]
        return self.compose(*options, service, 'python3', '-c', code, *args)

    def prepare(self):
        # Resolve production paths against a disposable layout, never the repo's
        # real state/secrets symlinks or an existing /opt/clawshell installation.
        layout = self.work / 'layout'
        (layout / 'compose').mkdir(parents=True)
        (layout / 'secrets').mkdir()
        for name in ('gateway_token', 'model_provider_api_key', 'github_agent_token'):
            (layout / 'secrets' / name).write_text('integration-placeholder')
        rendered = self.command('docker', 'compose', '--project-directory', str(layout / 'compose'),
            '--env-file', str(SOURCE / '.env.example'), '-f', str(SOURCE / 'compose/compose.yml'),
            '--profile', '*', 'config', '--format', 'json')
        production = json.loads(rendered)
        for name in ('allowlist.d', 'scope', 'engagement', 'workspaces'):
            (self.work / name).mkdir()
        (self.work / 'workspaces').chmod(0o777)
        (self.work / 'engagement').chmod(0o777)
        (self.work / 'engagement/target.txt').write_text('authorized target fixture')
        (self.work / 'engagement/target.txt').chmod(0o666)
        config, self.provider_ip, self.target_ip = build_config(production, SOURCE, self.work, self.project,
            os.environ.get('CLAWSHELL_TEST_UPLINK_SUBNET', '11.203.71.0/24'))
        (self.work / 'allowlist.conf').write_text(
            f'{self.provider_ip}:8080\nprovider.test:8080\nunstable-provider.test:8080\nprivate-provider.test:8080\n')
        (self.work / 'scope/active.conf').write_text('target.test:8080\nprivate-target.test:8080\nlocalhost:8080\n')
        self.path.write_text(json.dumps(config, indent=2))
        self.compose('config', '--quiet')

    def probe(self, mode, service='openclaw-gateway', **payload):
        return json.loads(self.compose('exec', '-T', service, 'python3', '/probe.py',
                                      mode, json.dumps(payload)))

    def http(self, url, proxy='http://quota-guard:8080', **kwargs):
        return self.probe('http', url=url, proxy=proxy, **kwargs)

    def control(self, service, port, path='/status', payload=None):
        # The control APIs must be loopback-only inside the boundary container.
        code = """import json,sys,urllib.request
payload = None if sys.argv[2] == 'null' else sys.argv[2].encode()
req = urllib.request.Request(sys.argv[1], data=payload, headers={'Content-Type':'application/json'})
print(urllib.request.urlopen(req,timeout=5).read().decode())"""
        return json.loads(self.exec(service, code, f'http://127.0.0.1:{port}{path}', json.dumps(payload)))

    def stats(self, service):
        return self.control(service, 8080, '/stats')

    def test_network(self):
        # A positive forwarded request proves connectivity before denial tests.
        positive = self.http(f'http://{self.provider_ip}:8080/ok')
        check(positive['status'] == 200 and json.loads(positive['body'])['fixture'] == 'clawshell-integration',
              f'Allowlisted upstream is not working: {positive}')
        before = self.stats('provider')
        denied = self.http('http://denied-provider.test:8080/forbidden')
        check(denied['status'] == 403 and json.loads(denied['body'])['reason'] == 'not_in_allowlist',
              f'Expected explicit quota-guard denial, not an arbitrary network failure: {denied}')
        check(before == self.stats('provider'), 'Denied request reached the provider')
        private = self.http('http://private-provider.test:8080/private')
        check(private['status'] == 403 and json.loads(private['body'])['reason'] == 'resolved_to_private_ip_ssrf_guard',
              f'Allowlisted hostname bypassed the private-address guard: {private}')
        for address in (self.provider_ip, self.target_ip):
            check(not self.probe('connect', host=address, port=8080)['connected'],
                  f'Gateway reached an upstream directly: {address}')
        check(not self.probe('connect', service='pentest-tools-mcp', host=self.target_ip, port=8080)['connected'],
              'MCP service bypassed target-gateway and reached target directly')
        # Assert real runtime network properties, not just the YAML contract.
        gateway = self.compose('ps', '-q', 'openclaw-gateway')
        runtime = json.loads(self.command('docker', 'inspect', gateway))[0]
        for network in runtime['NetworkSettings']['Networks']:
            details = json.loads(self.command('docker', 'network', 'inspect', network))[0]
            check(details['Internal'], f'Gateway acquired an external network at runtime: {network}')
        for service, port in (('quota-guard', 8088), ('target-gateway', 8089)):
            origin = 'pentest-tools-mcp' if service == 'target-gateway' else 'openclaw-gateway'
            check(self.probe('connect', service=origin, host=service, port=8080)['connected'],
                  f'{origin} cannot reach the {service} proxy; a negative control-port check would be meaningless')
            check(not self.probe('connect', service=origin, host=service, port=port)['connected'],
                  f'{service} loopback control API is exposed to Gateway')
        # Publishing the UI must still work with the control network internal.
        mapping = self.compose('port', 'gateway-ui', '18789')
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open('http://' + mapping, timeout=5) as response:
            check(response.status == 200, 'Internal control network broke published UI reachability')

    def test_filesystem(self):
        code = """import errno,json,pathlib,os
assert pathlib.Path('/home/node/workspace/engagement/target.txt').read_text() == 'authorized target fixture'
for path in ['/home/node/workspace/engagement/target.txt','/clawshell-root-write-probe']:
    try:
        with open(path,'w') as handle: handle.write('forbidden')
    except OSError as error:
        assert error.errno == errno.EROFS, (path,error)
    else:
        raise AssertionError('Write succeeded: '+path)
print('read-only checks passed')"""
        # Root can otherwise write the fixture file; EROFS proves the mount,
        # rather than Unix file permissions, is enforcing the boundary.
        self.exec('openclaw-gateway', code, user='0')
        self.exec('openclaw-gateway', "import pathlib; p=pathlib.Path('/home/node/workspace/reports/report.txt'); p.write_text('report'); assert p.read_text()=='report'")
        container = self.compose('ps', '-q', 'openclaw-gateway')
        details = json.loads(self.command('docker', 'inspect', container))[0]
        check(details['HostConfig']['ReadonlyRootfs'], 'Gateway root filesystem is writable')
        check('ALL' in details['HostConfig']['CapDrop'], 'Gateway retains Linux capabilities')
        check(any(item.startswith('no-new-privileges') for item in details['HostConfig']['SecurityOpt']),
              'Gateway allows privilege escalation')
        check(not details['HostConfig']['Privileged'], 'Gateway is privileged')
        for mount in details['Mounts']:
            check('docker.sock' not in mount['Source'] and 'docker.sock' not in mount['Destination'],
                  'Host Docker socket is mounted')

    def test_circuit(self):
        for host, endpoint, reason in ((self.provider_ip, '/quota', 'QUOTA_EXHAUSTED'),
                                       ('provider.test', '/auth', 'AUTH_FAILED')):
            first = self.http(f'http://{host}:8080{endpoint}')
            check(first['status'] in (401, 429), f'Provider failure did not reach quota-guard: {first}')
            state = self.control('quota-guard', 8088)['hosts'][host]
            check(state['state'] == 'OPEN' and state['reason'] == reason and state['manual_resume_required'],
                  f'Circuit failed to open: {state}')
            before = self.stats('provider')
            for _ in range(4):
                denied = self.http(f'http://{host}:8080{endpoint}')
                body = json.loads(denied['body'])
                check(denied['status'] == 503 and body.get('error') == 'circuit_open',
                      f'Expected circuit short-circuit: {denied}')
            check(before == self.stats('provider'), 'Open circuit continued forwarding to provider')
        check(self.stats('provider').get('GET /quota') == 1, 'Quota failure reached upstream more than once')
        check(self.stats('provider').get('GET /auth') == 1, 'Auth failure reached upstream more than once')
        for _ in range(2):
            self.http('http://unstable-provider.test:8080/unstable')
        state = self.control('quota-guard', 8088)['hosts']['unstable-provider.test']
        check(state['state'] == 'OPEN' and state['reason'] == 'PROVIDER_UNSTABLE',
              f'Transient failure threshold did not open circuit: {state}')

    def test_scope(self):
        self.control('target-gateway', 8089, '/control/engagement/start', {'engagement_id': 'integration'})
        def request(path, host='target.test', **kwargs):
            return self.http(f'http://{host}:8080{path}', proxy='http://target-gateway:8080', service='pentest-tools-mcp', **kwargs)
        allowed = request('/ok')
        check(allowed['status'] == 200, f'In-scope GET failed: {allowed}')
        cases = [('/out', 'out-of-scope.test', {}, 'out_of_scope'),
                 ('/x/%2e%2e/admin', 'target.test', {}, 'suspicious_path'),
                 ('/private', 'private-target.test', {}, 'blocked_internal_address:'),
                 ('/private', 'localhost', {}, 'blocked_internal_host'),
                 ('/change', 'target.test', {'method': 'POST'}, 'approval_required:'),
                 ('/change', 'target.test', {'headers': {'X-HTTP-Method-Override': 'DELETE'}}, 'approval_required:')]
        for path, host, kwargs, reason in cases:
            before = self.stats('target')
            denied = request(path, host=host, **kwargs)
            body = json.loads(denied['body'])
            check(denied['status'] == 403 and body.get('blocked_by') == 'target-gateway' and
                  body.get('reason', '').startswith(reason), f'Wrong policy denial for {path}: {denied}')
            check(before == self.stats('target'), f'Denied {path} reached target')
        self.control('target-gateway', 8089, '/control/approve', {'descriptor': 'POST target.test:8080/change'})
        check(request('/change', method='POST')['status'] == 200, 'Approved POST did not reach target')
        sibling = request('/other', method='POST')
        check(sibling['status'] == 403, 'Approval leaked to a different endpoint')
        # Exercise the real MCP transport and tool registration, not a stubbed import.
        positive = self.probe('mcp', url='http://pentest-tools-mcp:8765/mcp/', tool='http_request',
                              arguments={'url': 'http://target.test:8080/mcp'})
        check(positive.get('status') == 200, f'MCP cannot reach scoped target: {positive}')
        denied = self.probe('mcp', url='http://pentest-tools-mcp:8765/mcp/', tool='http_request',
                           arguments={'url': 'http://out-of-scope.test:8080/mcp-denied'})
        check(denied.get('gateway_decision') == 'out_of_scope', f'MCP lost policy decision: {denied}')
        # Backoff must suppress actual target traffic, not just log a warning.
        check(request('/throttle')['status'] == 429, 'Target backpressure fixture failed')
        before = self.stats('target')
        cooled = request('/must-not-forward')
        check(cooled['status'] == 429 and json.loads(cooled['body'])['reason'] == 'cooling_down',
              f'Target cooldown was not enforced: {cooled}')
        check(before == self.stats('target'), 'Cooldown request reached target')
        evidence = self.exec('target-gateway', "import pathlib;print(pathlib.Path('/logs/engagement-integration.log').read_text())")
        records = [json.loads(line) for line in evidence.splitlines()]
        check(any(r['decision'] == 'forward' for r in records), 'Forwarded evidence missing')
        check(any(r['decision'] == 'deny' and r['reason'] == 'out_of_scope' for r in records), 'Denied evidence missing')
        check(not any(r['decision'] == 'forward' and r['path'] == '/out' for r in records),
              'Denied request was logged as forwarded')

    def test_recovery(self):
        # Force a state save even when running this case on its own.
        self.http(f'http://{self.provider_ip}:8080/recovery-baseline')
        self.compose('stop', 'quota-guard')
        restored = json.loads(self.compose('run', '--rm', '-T', '--no-deps', 'recovery-worker', 'roundtrip'))
        self.compose('up', '-d', '--no-build', '--wait', '--wait-timeout', '90', 'quota-guard')
        status = self.control('quota-guard', 8088)
        check(status == restored['restored_state'], 'Real proxy did not reload the recovered state')
        check(restored['uid'] == 10001, 'Recovery did not preserve the proxy UID')

    def test_killswitch(self):
        for service in ('target-gateway', 'pentest-tools-mcp'):
            command = ['docker', 'compose', '-p', self.project, '-f', str(self.path),
                       'run', '--rm', '-T', '--no-deps', '-e', 'BLACKBOX_LIVE_TESTING=false', service]
            result = subprocess.run(command, text=True, capture_output=True, timeout=30)
            check(result.returncode != 0 and 'refusing to start' in result.stdout + result.stderr,
                  f'{service} did not enforce its kill switch: {result.stdout} {result.stderr}')

    def collect(self):
        self.artifacts.mkdir(parents=True, exist_ok=True)
        failed = any(result.get('status') == 'failed' for result in self.results)
        for name, arguments in [('compose.log', ('logs', '--no-color')), ('status.json', ('ps', '-a', '--format', 'json'))]:
            try:
                output = self.compose(*arguments)
            except Exception as exc:
                output = str(exc)
            (self.artifacts / name).write_text(output)
            if failed:
                # Preserve complete artifacts, but bound console output. Startup
                # tracebacks must be visible without downloading an artifact.
                print(f'--- Integration failure: {name} (last 300 lines) ---', file=sys.stderr)
                print('\n'.join(output.splitlines()[-300:]), file=sys.stderr, flush=True)
        (self.artifacts / 'results.json').write_text(json.dumps(self.results, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=('all', 'network', 'filesystem', 'circuit', 'scope', 'recovery', 'killswitch'), default='all')
    parser.add_argument('--artifacts', type=Path, default=Path('/tmp/clawshell-integration-artifacts'))
    args = parser.parse_args()
    if not shutil.which('docker'):
        parser.error('Docker is required; integration tests never silently skip')
    subprocess.run(['docker', 'info'], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['docker', 'compose', 'version'], check=True)
    def interrupted(signum, _frame):
        raise RuntimeError(f'Integration run interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    with tempfile.TemporaryDirectory(prefix='clawshell-integration-') as temporary:
        stack = Stack(Path(temporary), args.artifacts.resolve())
        prepared = False
        try:
            stack.prepare()
            prepared = True
            stack.compose('--profile', 'maintenance', 'build', '--pull', timeout=1200)
            stack.compose('run', '--rm', '-T', '--no-deps', 'recovery-worker', 'init')
            # Exercise the actual mitmproxy loader before starting dependent
            # services, so an addon import failure is reported at its source.
            for service, filename in (('quota-guard', 'quota_guard_addon.py'),
                                      ('target-gateway', 'target_gateway_addon.py')):
                stack.compose('run', '--rm', '-T', '--no-deps', '--entrypoint', 'python3', service,
                    '-c', 'import sys; from mitmproxy.addons.script import load_script; '
                    'module=load_script(sys.argv[1]); '
                    'assert module is not None and getattr(module, "addons", None), "Addon failed to load"',
                    '/app/addons/' + filename)
            stack.compose('up', '-d', '--no-build', '--wait', '--wait-timeout', '180', timeout=240)
            for name in ('network', 'filesystem', 'scope', 'killswitch', 'circuit', 'recovery'):
                if args.case not in ('all', name):
                    continue
                started = time.monotonic()
                getattr(stack, 'test_' + name)()
                stack.results.append({'case': name, 'status': 'passed', 'seconds': round(time.monotonic()-started, 2)})
                print(f'PASS {name}', flush=True)
        except Exception as exc:
            stack.results.append({'status': 'failed', 'error': str(exc)})
            raise
        finally:
            print(f'Integration diagnostics: {stack.artifacts}', flush=True)
            if prepared:
                try:
                    stack.collect()
                finally:
                    stack.compose('down', '--volumes', '--remove-orphans', timeout=90)
                    # Remove only this run's own image tags, never shared base images.
                    subprocess.run(['docker', 'image', 'rm', *[f'{stack.project}/{service}:test'
                        for service in ('quota-guard', 'target-gateway', 'pentest-tools-mcp', 'recovery-worker')]],
                        text=True, capture_output=True, timeout=60)
            else:
                stack.artifacts.mkdir(parents=True, exist_ok=True)
                (stack.artifacts / 'results.json').write_text(json.dumps(stack.results, indent=2))


if __name__ == '__main__':
    main()
