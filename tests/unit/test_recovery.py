"""Recovery archive and image snapshot tests: no host writes or Docker needed."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('recovery', Path(__file__).resolve().parents[2] / 'scripts/lib/recovery.py')
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'repo'
        self.root = self.base / 'host'
        for name in ['config/allowlist.d', 'config/agent-workspaces']:
            (self.repo / name).mkdir(parents=True)
        for name in ['state/openclaw', 'state/quota-guard', 'state/caveman',
                     'state/target-gateway', 'state/local-llm', 'workspaces']:
            (self.root / name).mkdir(parents=True)
        for name in ['config/allowlist.conf', 'config/openclaw.json5']:
            (self.repo / name).write_text('original')
        (self.root / 'state/quota-guard/state.json').write_text('original state')
        (self.root / 'workspaces/report.md').write_text('original report')
        (self.root / 'state/local-llm/weights').write_text('huge cache')
        self.archive = self.base / 'backup.tar'
        self.extracted = self.base / 'extracted'

    def create(self, metadata=False):
        with patch.object(recovery, 'run', return_value='a' * 40):
            recovery.create(self.repo, self.root, self.archive, metadata)
        return recovery.unpack(self.archive, self.extracted)

    def test_roundtrip_preserves_unarchived_components_modes_and_caches(self):
        (self.root / 'workspaces/report.md').chmod(0o640)
        (self.root / 'state/quota-guard').chmod(0o750)
        manifest = self.create()
        self.assertIn('state/caveman', manifest['paths'])
        self.assertIn('state/target-gateway', manifest['paths'])
        self.assertNotIn('state/local-llm', manifest['paths'])
        (self.root / 'state/quota-guard/state.json').write_text('changed')
        (self.root / 'state/quota-guard/new').write_text('remove this')
        (self.root / 'state/new-service').mkdir()
        (self.repo / 'config/agent-workspaces/custom').write_text('keep')
        recovery.restore(self.extracted, self.repo, self.root)
        self.assertEqual((self.root / 'state/quota-guard/state.json').read_text(), 'original state')
        self.assertFalse((self.root / 'state/quota-guard/new').exists())
        self.assertEqual((self.root / 'state/quota-guard').stat().st_mode & 0o777, 0o750)
        self.assertTrue((self.root / 'state/new-service').exists())
        self.assertTrue((self.repo / 'config/agent-workspaces/custom').exists())
        self.assertEqual((self.root / 'state/local-llm/weights').read_text(), 'huge cache')
        self.assertEqual((self.root / 'workspaces/report.md').stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.root / 'workspaces/report.md').stat().st_uid,
                         (self.extracted / 'workspaces/report.md').stat().st_uid)

    def test_missing_required_source_is_fatal(self):
        (self.repo / 'config/openclaw.json5').unlink()
        with self.assertRaisesRegex(ValueError, 'Required backup path missing'):
            self.create()

    def test_special_files_cannot_be_silently_omitted(self):
        import os
        os.mkfifo(self.root / 'state/openclaw/pipe')
        with self.assertRaisesRegex(ValueError, 'Unsupported special file'):
            self.create()

    def test_metadata_only_does_not_replace_workspaces(self):
        manifest = self.create(metadata=True)
        self.assertNotIn('workspaces', manifest['paths'])
        (self.root / 'workspaces/report.md').write_text('keep current')
        recovery.restore(self.extracted, self.repo, self.root)
        self.assertEqual((self.root / 'workspaces/report.md').read_text(), 'keep current')

    def hostile_archive(self, entries, paths=None):
        with tarfile.open(self.archive, 'w') as tar:
            payload = json.dumps({'format': 1, 'paths': paths or ['state/openclaw']}).encode()
            member = tarfile.TarInfo('manifest.json')
            member.size = len(payload)
            tar.addfile(member, io.BytesIO(payload))
            directory = tarfile.TarInfo('state/openclaw')
            directory.type = tarfile.DIRTYPE
            tar.addfile(directory)
            for member in entries:
                tar.addfile(member)
        with self.assertRaises((ValueError, tarfile.TarError)):
            recovery.unpack(self.archive, self.extracted)

    def test_traversal_rejected(self):
        self.hostile_archive([tarfile.TarInfo('state/openclaw/../../escape')])
        self.assertFalse((self.base / 'escape').exists())

    def test_external_symlink_rejected(self):
        member = tarfile.TarInfo('state/openclaw/link')
        member.type, member.linkname = tarfile.SYMTYPE, '/etc'
        self.hostile_archive([member])

    def test_link_to_omitted_secrets_rejected(self):
        member = tarfile.TarInfo('state/openclaw/link')
        member.type, member.linkname = tarfile.SYMTYPE, '../../secrets'
        self.hostile_archive([member])

    def test_undeclared_path_rejected(self):
        self.hostile_archive([tarfile.TarInfo('config/overwrite')])

    def test_duplicate_member_rejected(self):
        self.hostile_archive([tarfile.TarInfo('state/openclaw')])

    def test_missing_declared_component_rejected(self):
        self.hostile_archive([], ['state/openclaw', 'workspaces'])

    def test_model_cache_cannot_be_restore_target(self):
        self.hostile_archive([], ['state/local-llm'])


class SnapshotTests(unittest.TestCase):
    def test_snapshot_uses_running_image_ids_and_preserves_activation(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            config = {'name': 'clawshell', 'services': {
                name: {'image': 'upstream:moving', 'build': {'context': '.'},
                       'profiles': ['optional']} for name in
                ['quota-guard', 'openclaw-gateway', 'sandbox-dind', 'openclaw-cli']}}
            source = base / 'before.json'
            output = base / 'rollback.json'
            source.write_text(json.dumps(config))
            def fake_run(*args):
                if args[1] == 'ps':
                    return '' if args[-1].endswith('openclaw-cli') else 'container'
                return 'sha256:old'
            with patch.object(recovery, 'run', side_effect=fake_run), \
                 patch.object(recovery.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'sha256:cli\n')) as docker:
                recovery.snapshot(source, output)
            result = json.loads(output.read_text())
            self.assertEqual(json.loads((base / 'services.json').read_text()),
                             ['quota-guard', 'openclaw-gateway', 'sandbox-dind'])
            for service in result['services'].values():
                self.assertNotIn('build', service)
                self.assertNotIn('profiles', service)
                self.assertEqual(service['pull_policy'], 'never')
                self.assertTrue(service['image'].startswith('clawshell/rollback:'))
            self.assertTrue(any(call.args[0][:3] == ['docker', 'tag', 'sha256:old']
                                for call in docker.call_args_list))

    def test_readiness_requires_healthy_selected_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / 'config.json'
            config.write_text(json.dumps({'services': {'local-llm': {
                'container_name': 'llm', 'healthcheck': {'test': ['CMD', 'true']}}}}))
            state = [{'State': {'Status': 'running', 'Health': {'Status': 'starting'}}}]
            with patch.object(recovery.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(state))):
                self.assertFalse(recovery.ready(config, 'local-llm'))
