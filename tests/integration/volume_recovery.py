"""Exercise the real archive helper against persistent state used by quota-guard."""
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, '/')
import recovery

ROOT = Path('/fixture')
REPO = ROOT / 'repo'
STATE = ROOT / 'state/quota-guard'


def initialize():
    for name in ('state/openclaw', 'state/quota-guard', 'workspaces', 'repo/config/allowlist.d'):
        (ROOT / name).mkdir(parents=True, exist_ok=True)
    STATE.chmod(0o750)
    os.chown(STATE, 10001, 10001)
    os.chown(ROOT, 10001, 10001)
    for name in ('config/allowlist.conf', 'config/openclaw.json5'):
        (REPO / name).write_text('integration-only config')
    subprocess.run(['git', 'init', '-q', str(REPO)], check=True)
    subprocess.run(['git', '-C', str(REPO), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(REPO), '-c', 'user.name=Integration',
                    '-c', 'user.email=integration@example.invalid', 'commit', '-qm', 'fixture'], check=True)


def roundtrip():
    state_file = STATE / 'state.json'
    expected = state_file.read_bytes()
    metadata = (STATE.stat().st_uid, STATE.stat().st_gid, STATE.stat().st_mode & 0o777)
    (ROOT / 'workspaces/report.txt').write_text('original report')
    (ROOT / 'state/openclaw/cache').write_text('original application data')
    backup = ROOT / 'backup.tar'
    recovery.create(REPO, ROOT, backup)
    extraction = ROOT / 'extracted'
    recovery.unpack(backup, extraction)
    # Simulate a changed schema and new files after upgrade; stop the real
    # state writer before this script is called, then verify exact recovery.
    state_file.write_text('{"hosts":{},"active_task":null,"changed":true}')
    (STATE / 'new-schema-file').write_text('remove on rollback')
    (ROOT / 'workspaces/report.txt').write_text('changed report')
    (ROOT / 'state/unlisted-component').mkdir()
    recovery.restore(extraction, REPO, ROOT)
    assert state_file.read_bytes() == expected, 'State bytes were not restored'
    assert not (STATE / 'new-schema-file').exists(), 'New component file survived restore'
    assert (ROOT / 'state/unlisted-component').is_dir(), 'Restore deleted an unlisted component'
    assert (ROOT / 'workspaces/report.txt').read_text() == 'original report'
    assert (STATE.stat().st_uid, STATE.stat().st_gid, STATE.stat().st_mode & 0o777) == metadata
    assert state_file.stat().st_uid == 10001, 'State file ownership changed'
    print(json.dumps({'restored_state': json.loads(expected), 'uid': metadata[0], 'mode': oct(metadata[2])}))


if __name__ == '__main__':
    {'init': initialize, 'roundtrip': roundtrip}[sys.argv[1]]()
