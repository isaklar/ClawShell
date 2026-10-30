"""A startup failure must expose container logs before fixture cleanup."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

DIRECTORY = Path(__file__).resolve().parents[1] / 'integration'
spec = importlib.util.spec_from_file_location('integration_run', DIRECTORY / 'run.py')
runner = importlib.util.module_from_spec(spec)
with patch.object(sys, 'path', [str(DIRECTORY), *sys.path]):
    spec.loader.exec_module(runner)


class DiagnosticsTests(unittest.TestCase):
    def test_failed_run_saves_full_logs_and_prints_bounded_console_tail(self):
        with tempfile.TemporaryDirectory() as directory:
            stack = runner.Stack(Path(directory), Path(directory) / 'artifacts')
            stack.results = [{'status': 'failed', 'error': 'startup failure'}]
            logs = '\n'.join(['earlier log'] * 350 + ['target-gateway: addon import failed'])
            output = io.StringIO()
            with patch.object(stack, 'compose', side_effect=[logs, 'container status']), contextlib.redirect_stderr(output):
                stack.collect()
            self.assertEqual((stack.artifacts / 'compose.log').read_text(), logs)
            self.assertIn('target-gateway: addon import failed', output.getvalue())
            self.assertIn('container status', output.getvalue())
            self.assertLess(output.getvalue().count('earlier log'), 350)

    def test_collection_error_does_not_hide_original_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            stack = runner.Stack(Path(directory), Path(directory) / 'artifacts')
            stack.results = [{'status': 'failed', 'error': 'startup failure'}]
            with patch.object(stack, 'compose', side_effect=RuntimeError('Docker unavailable')), contextlib.redirect_stderr(io.StringIO()):
                stack.collect()
            self.assertIn('Docker unavailable', (stack.artifacts / 'compose.log').read_text())
            self.assertIn('startup failure', (stack.artifacts / 'results.json').read_text())
