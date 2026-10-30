"""Load addons the way mitmproxy 11's script loader does, not as normal imports."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import _stubs

SOURCE = Path(__file__).resolve().parents[2]


class ScriptLoadingTests(unittest.TestCase):
    def test_addons_load_without_sys_modules_registration(self):
        _stubs.install_mitmproxy_stub()
        for component, filename, prefix in (
            ('target-gateway', 'target_gateway_addon', 'TARGET_GATEWAY'),
            ('quota-guard', 'quota_guard_addon', 'QUOTA_GUARD'),
        ):
            with self.subTest(component=component), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                environment = {f'{prefix}_{name}_DIR': str(root / name.lower())
                               for name in ('STATE', 'LOG', 'SCOPE')}
                name = f'__mitmproxy_script__.{filename}'
                self.assertNotIn(name, sys.modules)
                path = SOURCE / component / 'addons' / (filename + '.py')
                spec = importlib.util.spec_from_file_location(name, path)
                module = importlib.util.module_from_spec(spec)
                # mitmproxy 11 load_script calls exec_module without registering
                # the module. Dataclass string annotations must not depend on it.
                with patch.dict(os.environ, environment):
                    spec.loader.exec_module(module)
                self.assertEqual(len(module.addons), 1)
                self.assertNotIn(name, sys.modules)
