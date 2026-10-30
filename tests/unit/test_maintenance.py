"""Run the real maintenance scripts against temp Git repos and simulated Docker."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('zstd') and shutil.which('jq') and shutil.which('flock'),
                     'requires zstd, jq and flock')
class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.repo, self.host = base / 'repo', base / 'host'
        self.repo.mkdir()
        self.host.mkdir()
        shutil.copytree(SOURCE / 'scripts', self.repo / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
        for path in (self.repo / 'scripts').rglob('*'):
            if path.suffix == '.sh':
                text = path.read_text().replace('/opt/clawshell', str(self.host))
                text = text.replace('if [[ "${EUID}" -ne 0 ]]; then', 'if false; then')
                path.write_text(text)
        (self.repo / 'compose').mkdir()
        (self.repo / 'compose/compose.yml').write_text('name: clawshell\n')
        for name in ['config/allowlist.d', 'config/agent-workspaces']:
            (self.repo / name).mkdir(parents=True)
        for name in ['config/allowlist.conf', 'config/openclaw.json5']:
            (self.repo / name).write_text('original')
        for name in ['state/openclaw', 'state/quota-guard/tasks', 'workspaces']:
            (self.host / name).mkdir(parents=True)
        (self.host / 'state/quota-guard/state.json').write_text(json.dumps({'hosts': {}, 'active_task': None}))
        (self.host / 'state/openclaw/data').write_text('old schema')
        (self.host / 'workspaces/report').write_text('report')
        (self.repo / '.env').write_text('MODEL_PROVIDER=openai\nCAVEMAN_PROXY_ENABLED=false\nUPDATE_HEALTH_TIMEOUT=1\n')
        (self.repo / '.env.example').write_text('MODEL_PROVIDER=openai\n')
        (self.repo / '.gitignore').write_text('.env\n')
        (self.repo / 'version').write_text('old')
        self.bin = base / 'bin'
        self.bin.mkdir()
        shutil.copy(SOURCE / 'tests/fixtures/maintenance-docker.py', self.bin / 'docker')
        (self.bin / 'docker').chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        TEST_HOST=str(self.host), TEST_REPO=str(self.repo))
        (self.host / 'docker.json').write_text(json.dumps({'tags': {}, 'containers': {
            name: {'running': True, 'image': f'test/{name}:old'}
            for name in ['quota-guard', 'openclaw-gateway', 'sandbox-dind']}}))
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Test')
        self.git('add', '.')
        self.git('commit', '-qm', 'old')
        self.old = self.git('rev-parse', 'HEAD').strip()
        (self.repo / 'version').write_text('new')
        self.git('add', 'version')
        self.git('commit', '-qm', 'new')
        self.new = self.git('rev-parse', 'HEAD').strip()
        self.git('reset', '--hard', self.old)
        # A local bare remote exercises real fetch/upstream resolution.
        remote = base / 'remote.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
        self.git('remote', 'add', 'origin', str(remote))
        self.git('push', '-q', 'origin', f'{self.new}:refs/heads/main')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, stderr=subprocess.DEVNULL)

    def script(self, name, *args, env=None, input=None):
        result = subprocess.run(['bash', str(self.repo / 'scripts' / name), *args],
                                text=True, input=input, capture_output=True,
                                env=dict(self.env, **(env or {})), timeout=30)
        self.output = result.stdout + result.stderr
        return result

    def update(self, **env):
        return self.script('update.sh', f'--to={self.new}', env=env)

    def assert_recovered(self):
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.old, self.output)
        state = json.loads((self.host / 'docker.json').read_text())
        self.assertTrue(all(s['running'] and s['image'].endswith(':old') for s in state['containers'].values()), self.output)
        self.assertFalse((self.host / 'deployments/pending.json').exists(), self.output)
        self.assertEqual((self.host / 'state/openclaw/data').read_text(), 'old schema')

    def test_update_then_offline_rollback(self):
        self.assertEqual(self.update().returncode, 0, self.output)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.new)
        self.assertTrue((self.host / 'deployments/latest.json').exists())
        (self.host / 'state/openclaw/data').write_text('changed after deployment')
        result = self.script('update.sh', '--rollback', env={'FAIL_PULL': '1', 'FAIL_BUILD': '1'}, input='y\n')
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_recovered()

    def test_build_failure_recovers_previous_images(self):
        self.assertNotEqual(self.update(FAIL_BUILD='1').returncode, 0, self.output)
        self.assert_recovered()

    def test_start_failure_recovers_data_and_images(self):
        self.assertNotEqual(self.update(FAIL_UP='1').returncode, 0, self.output)
        self.assert_recovered()

    def test_failed_readiness_recovers_migrated_data(self):
        self.assertNotEqual(self.update(FAIL_READY_NEW='1', MUTATE_STATE='1').returncode, 0, self.output)
        self.assert_recovered()

    def test_pull_failure_recovers(self):
        self.assertNotEqual(self.update(FAIL_PULL='1').returncode, 0)
        self.assert_recovered()

    def test_pending_update_requires_explicit_recovery(self):
        deployments = self.host / 'deployments'
        deployments.mkdir()
        (deployments / 'pending.json').write_text('{}')
        self.assertNotEqual(self.update().returncode, 0)
        self.assertIn('interrupted update', self.output)

    def test_manual_rollback_health_failure_exits_nonzero(self):
        self.assertEqual(self.update().returncode, 0, self.output)
        result = self.script('update.sh', '--rollback', env={'FAIL_READY_ALL': '1'}, input='y\n')
        self.assertNotEqual(result.returncode, 0)

    def test_interrupted_update_recovers_on_next_invocation(self):
        self.assertNotEqual(self.update(FAIL_READY_ALL='1').returncode, 0)
        self.assertTrue((self.host / 'deployments/pending.json').exists(), self.output)
        self.assertTrue((self.host / 'maintenance-required').exists(), self.output)
        result = self.script('update.sh', '--rollback', input='y\n')
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_recovered()

    def test_exclusive_maintenance_lock_blocks_update(self):
        import fcntl
        with (self.host / 'maintenance.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertNotEqual(self.update().returncode, 0)
        self.assertIn('Another backup', self.output)

    def test_gpu_and_caveman_profile_readiness_failure_recovers(self):
        with (self.repo / '.env').open('a') as env:
            env.write('MODEL_PROVIDER=local-gpu\nLOCAL_LLM_BACKEND=amd-rocm\nCAVEMAN_PROXY_ENABLED=true\n')
        state_path = self.host / 'docker.json'
        state = json.loads(state_path.read_text())
        for name in ['local-llm-amd', 'caveman-proxy']:
            state['containers'][name] = {'running': True, 'image': f'test/{name}:old'}
        state_path.write_text(json.dumps(state))
        self.assertNotEqual(self.update(FAIL_READY_NEW='1').returncode, 0)
        self.assert_recovered()
        calls = [json.loads(line) for line in (self.host / 'docker.log').read_text().splitlines()]
        build = next(a for a in calls if 'build' in a)
        self.assertIn('local-gpu-amd', build)
        self.assertIn('caveman-proxy', build)

    def test_running_task_blocks_update(self):
        (self.host / 'state/quota-guard/state.json').write_text(json.dumps({'hosts': {}, 'active_task': {'task_id': 'x'}}))
        self.assertNotEqual(self.update().returncode, 0)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.old)
        self.assertFalse((self.host / 'backups').exists())

    def test_unreachable_task_status_blocks_update(self):
        self.assertNotEqual(self.update(FAIL_STATUS='1').returncode, 0)
        self.assertIn('Cannot verify task status', self.output)

    def test_dirty_tree_is_rejected(self):
        (self.repo / 'version').write_text('custom')
        self.assertNotEqual(self.update().returncode, 0)
        self.assertIn('dirty', self.output)

    def test_check_does_not_change_deployment(self):
        result = self.script('update.sh', '--check', f'--to={self.new}')
        self.assertEqual(result.returncode, 0, self.output)
        self.assert_recovered()
        self.assertFalse((self.host / 'backups').exists())

    def test_corrupted_archive_refused_before_stopping(self):
        self.assertEqual(self.script('backup.sh').returncode, 0, self.output)
        archive = next((self.host / 'backups').glob('*.tar.zst'))
        archive.write_bytes(b'corrupt')
        before = (self.host / 'docker.log').read_text()
        self.assertNotEqual(self.script('restore.sh', str(archive), input='y\n').returncode, 0)
        self.assertIn('checksum mismatch', self.output)
        self.assertEqual((self.host / 'docker.log').read_text(), before)

    def test_missing_checksum_refused(self):
        archive = self.host / 'missing.tar.zst'
        archive.write_bytes(b'archive')
        self.assertNotEqual(self.script('restore.sh', str(archive)).returncode, 0)
        self.assertIn('Missing checksum', self.output)

    def test_backup_and_restore_roundtrip(self):
        self.assertEqual(self.script('backup.sh').returncode, 0, self.output)
        archive = next((self.host / 'backups').glob('*.tar.zst'))
        (self.host / 'state/openclaw/data').write_text('changed')
        (self.host / 'state/untouched').mkdir()
        self.assertEqual(self.script('restore.sh', str(archive), input='y\n').returncode, 0, self.output)
        self.assertEqual((self.host / 'state/openclaw/data').read_text(), 'old schema')
        self.assertTrue((self.host / 'state/untouched').exists())

    def test_failed_restore_has_offline_recovery(self):
        self.assertEqual(self.script('backup.sh').returncode, 0, self.output)
        archive = next((self.host / 'backups').glob('*.tar.zst'))
        (self.host / 'state/openclaw/data').write_text('pre-restore data')
        result = self.script('restore.sh', str(archive), env={'FAIL_READY_ALL': '1'}, input='y\n')
        self.assertNotEqual(result.returncode, 0, self.output)
        self.assertTrue((self.host / 'restores/pending.json').exists())
        self.assertTrue((self.host / 'maintenance-required').exists())
        # Simulate a fully stopped stack, then recover without pulling/building.
        state_path = self.host / 'docker.json'
        state = json.loads(state_path.read_text())
        for container in state['containers'].values():
            container['running'] = False
        state_path.write_text(json.dumps(state))
        result = self.script('restore.sh', '--recover', input='y\n',
                             env={'FAIL_PULL': '1', 'FAIL_BUILD': '1'})
        self.assertEqual(result.returncode, 0, self.output)
        self.assertEqual((self.host / 'state/openclaw/data').read_text(), 'pre-restore data')
        self.assertFalse((self.host / 'restores/pending.json').exists())
        self.assertFalse((self.host / 'maintenance-required').exists())

    def test_never_used_stack_can_be_backed_up(self):
        (self.host / 'state/quota-guard/state.json').unlink()
        # The real control API returns default state before its first task.
        self.env['DEFAULT_STATUS'] = '1'
        self.assertEqual(self.script('backup.sh').returncode, 0, self.output)

    def test_missing_required_backup_source_resumes_services(self):
        (self.repo / 'config/openclaw.json5').unlink()
        self.assertNotEqual(self.script('backup.sh').returncode, 0)
        state = json.loads((self.host / 'docker.json').read_text())
        self.assertTrue(all(s['running'] for s in state['containers'].values()), self.output)
        self.assertFalse(list((self.host / 'backups').glob('*.tar.zst')))
