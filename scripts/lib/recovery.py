#!/usr/bin/env python3
"""Private deployment snapshots and bounded, path-validated recovery archives."""
import io
import json
import posixpath
import os
import stat
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile

EXCLUDED_STATE = {'local-llm', 'local-llm-amd', 'update-history.json'}


def run(*args):
    return subprocess.check_output(args, text=True, timeout=15).strip()


def safe_filter(member, destination):
    checked = tarfile.data_filter(member, destination)
    # Backups run/restore as root. Preserve per-component numeric ownership;
    # never apply a blanket chown to quota-guard/DinD with distinct UIDs.
    if checked is not None:
        checked.uid, checked.gid = member.uid, member.gid
        checked.mode = member.mode & 0o777
    return checked


def validate_source(path):
    def check(entry):
        mode = entry.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
            raise ValueError(f'Unsupported special file in backup: {entry}')

    def walk_error(error):
        raise error

    check(path)
    if path.is_dir():
        for directory, dirs, files in os.walk(path, onerror=walk_error):
            for child in dirs + files:
                check(Path(directory) / child)


def create(repo, root, output, metadata=False):
    repo, root = Path(repo), Path(root)
    required = [root / 'state/openclaw', root / 'state/quota-guard',
                root / 'workspaces', repo / 'config/allowlist.conf',
                repo / 'config/openclaw.json5', repo / 'config/allowlist.d']
    for path in required:
        if not path.exists():
            raise ValueError(f'Required backup path missing: {path}')
    paths = [('config/allowlist.conf', repo / 'config/allowlist.conf'),
             ('config/openclaw.json5', repo / 'config/openclaw.json5'),
             ('config/allowlist.d', repo / 'config/allowlist.d')]
    paths += [(f'state/{p.name}', p) for p in sorted((root / 'state').iterdir())
              if p.name not in EXCLUDED_STATE]
    if not metadata:
        paths.append(('workspaces', root / 'workspaces'))
    manifest = {'format': 1, 'paths': [name for name, _ in paths],
                'commit': run('git', '-C', str(repo), 'rev-parse', 'HEAD'),
                'excluded': sorted(EXCLUDED_STATE), 'metadata_only': metadata}
    with tarfile.open(output, 'w') as archive:
        payload = json.dumps(manifest, indent=2).encode()
        entry = tarfile.TarInfo('manifest.json')
        entry.size, entry.mode = len(payload), 0o600
        archive.addfile(entry, io.BytesIO(payload))
        for name, path in paths:
            # tarfile silently skips sockets; a recovery backup must fail rather
            # than quietly omit live/unsupported files.
            source = path.resolve() if path.is_symlink() else path
            validate_source(source)
            archive.add(path.resolve() if path.is_symlink() else path, arcname=name)
        if metadata:
            payload = json.dumps({p.name: {
                'commit': run('git', '-C', str(p), 'rev-parse', 'HEAD')}
                for p in (root / 'workspaces').iterdir() if (p / '.git').exists()}).encode()
            entry = tarfile.TarInfo('workspaces-metadata.json')
            entry.size, entry.mode = len(payload), 0o600
            archive.addfile(entry, io.BytesIO(payload))


def unpack(source, destination):
    destination = Path(destination)
    with tarfile.open(source) as archive:
        manifest = json.load(archive.extractfile('manifest.json'))
        paths = manifest.get('paths', [])
        if manifest.get('format') != 1 or not paths or len(paths) != len(set(paths)):
            raise ValueError('Unsupported or invalid backup manifest')
        for name in paths:
            parts = PurePosixPath(name).parts
            if not (name in {'config/allowlist.conf', 'config/openclaw.json5',
                             'config/allowlist.d', 'workspaces'} or
                    (len(parts) == 2 and parts[0] == 'state' and
                     parts[1] not in EXCLUDED_STATE and not parts[1].startswith('.'))):
                raise ValueError(f'Undeclared restore destination: {name}')
        seen = set()
        for member in archive.getmembers():
            name = member.name.rstrip('/')
            if name in seen or any(p in {'.', '..'} for p in name.split('/')):
                raise ValueError(f'Duplicate or unsafe archive path: {name}')
            seen.add(name)
            if name not in {'manifest.json', 'workspaces-metadata.json'} and not any(
                    name == p or name.startswith(p + '/') for p in paths):
                raise ValueError(f'Unexpected archive member: {name}')
            component = next((p for p in paths if name == p or name.startswith(p + '/')), None)
            if member.issym() or member.islnk():
                target = (posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
                          if member.issym() else posixpath.normpath(member.linkname))
                if not component or not (target == component or target.startswith(component + '/')):
                    raise ValueError(f'Link escapes its restored component: {name}')
            if name in paths:
                file_component = name in {'config/allowlist.conf', 'config/openclaw.json5'}
                if (file_component and not member.isfile()) or (not file_component and not member.isdir()):
                    raise ValueError(f'Invalid component type: {name}')
            # Check all entries before extracting any data.
            safe_filter(member, str(destination))
        if not set(paths).issubset(seen):
            raise ValueError('Backup is missing declared paths')
        archive.extractall(destination, numeric_owner=True, filter=safe_filter)
    return manifest


def restore(extracted, repo, root):
    extracted, repo, root = Path(extracted), Path(repo), Path(root)
    manifest = json.loads((extracted / 'manifest.json').read_text())
    for name in manifest['paths']:
        target = (repo if name.startswith('config/') else root) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        # Delete only this declared component, never the entire state/config tree.
        # cp -a preserves owner, modes, links and times of the validated extraction.
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)
        subprocess.run(['cp', '-a', str(extracted / name), str(target)], check=True)


def snapshot(config_path, output):
    config = json.loads(Path(config_path).read_text())
    active = []
    for name, service in config['services'].items():
        containers = run('docker', 'ps', '-q', '--filter', 'label=com.docker.compose.project=clawshell',
                         '--filter', f'label=com.docker.compose.service={name}').splitlines()
        image = None
        if containers:
            image = run('docker', 'inspect', '-f', '{{.Image}}', containers[0])
            active.append(name)
        else:
            result = subprocess.run(['docker', 'image', 'inspect', '-f', '{{.Id}}', service['image']],
                                    text=True, capture_output=True, timeout=15)
            if result.returncode == 0:
                image = result.stdout.strip()
        if image:
            tag = f'clawshell/rollback:{Path(output).parent.name}-{name}'
            subprocess.run(['docker', 'tag', image, tag], check=True)
            service['image'] = tag
        elif name in active:
            raise ValueError(f'Cannot snapshot image for {name}')
        service.pop('build', None)
        service['pull_policy'] = 'never'
        # Explicit service selection is the saved activation set.
        service.pop('profiles', None)
    if not {'quota-guard', 'sandbox-dind', 'openclaw-gateway'}.issubset(active):
        raise ValueError('Core stack must be running before update/restore')
    Path(output).write_text(json.dumps(config, indent=2))
    Path(output).with_name('services.json').write_text(json.dumps(active))


def ready(config_path, *services):
    config = json.loads(Path(config_path).read_text())
    for name in services:
        service = config['services'][name]
        result = subprocess.run(['docker', 'inspect', service['container_name']],
                                text=True, capture_output=True, timeout=15)
        if result.returncode:
            return False
        state = json.loads(result.stdout)[0]['State']
        if state.get('Status') != 'running':
            return False
        if 'healthcheck' in service and not service['healthcheck'].get('disable', False):
            if state.get('Health', {}).get('Status') != 'healthy':
                return False
    # The existing Gateway healthcheck only starts Node. Probe its HTTP server
    # too, without model traffic or credentials in command arguments.
    run('docker', 'exec', 'clawshell-openclaw-gateway', 'node', '-e',
        "fetch('http://127.0.0.1:18789/', {signal: AbortSignal.timeout(3000)})"
        ".then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))")
    run('docker', 'exec', 'clawshell-sandbox-dind', 'docker', 'info')
    # A successful response with a valid shape is required, not just running.
    status = json.loads(run('docker', 'exec', 'clawshell-quota-guard', 'python3', '-c',
        "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8088/status',timeout=3).read().decode())"))
    return isinstance(status.get('hosts'), dict) and 'active_task' in status


if __name__ == '__main__':
    try:
        command, *args = sys.argv[1:]
        if command == 'create':
            create(*args[:3], metadata='--metadata-only' in args[3:])
        elif command == 'unpack':
            unpack(*args)
        elif command == 'restore':
            restore(*args)
        elif command == 'snapshot':
            snapshot(*args)
        elif command == 'ready':
            sys.exit(0 if ready(*args) else 1)
        else:
            raise ValueError(f'Unknown command: {command}')
    except Exception as exc:
        print(f'Recovery error: {exc}', file=sys.stderr)
        sys.exit(1)
