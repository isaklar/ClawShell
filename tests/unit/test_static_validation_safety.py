"""Compose validation must not replace an existing deployment's local links."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]


class StaticValidationSafetyTests(unittest.TestCase):
    def test_compose_validation_leaves_existing_state_and_secrets_links_untouched(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            repo = base / 'repo'
            for name in ('scripts', 'tests', 'compose', 'config/allowlist.d', 'bin'):
                (repo / name).mkdir(parents=True)
            shutil.copy(SOURCE / 'tests/test-static-validation.sh', repo / 'tests/test-static-validation.sh')
            (repo / 'scripts/install.sh').write_text('#!/bin/bash\n# Phase 1/1\necho "${MODEL_PROVIDER}"\n')
            (repo / '.env.example').write_text('MODEL_PROVIDER=local-gpu\n')
            (repo / '.gitignore').write_text('secrets/\nstate/\nworkspaces/\nlogs/\nbackups/\n')
            (repo / 'config/allowlist.conf').write_text('github.com:443\napi.github.com:443\n')
            for name in ('README.md', '.gitkeep'):
                (repo / 'config/allowlist.d' / name).touch()
            (repo / 'compose/compose.yml').write_text('services: {}\n')
            expected = {}
            for name in ('state', 'secrets', 'workspaces', 'logs', 'backups'):
                destination = base / ('existing-' + name)
                destination.mkdir()
                (destination / 'preserve').write_text(name)
                (repo / name).symlink_to(destination, target_is_directory=True)
                expected[name] = destination
            for args in [('init', '-q'), ('add', '.')]:
                subprocess.run(['git', '-C', str(repo), *args], check=True)
            docker = repo / 'bin/docker'
            docker.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$DOCKER_LOG"\n')
            docker.chmod(0o755)
            log = base / 'docker.log'
            result = subprocess.run(['bash', str(repo / 'tests/test-static-validation.sh')],
                text=True, capture_output=True, env=dict(os.environ,
                    PATH=str(repo / 'bin') + ':' + os.environ['PATH'], DOCKER_LOG=str(log)))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('--project-directory', log.read_text())
            for name, destination in expected.items():
                self.assertTrue((repo / name).is_symlink(), name)
                self.assertEqual((repo / name).resolve(), destination)
                self.assertEqual((destination / 'preserve').read_text(), name)
