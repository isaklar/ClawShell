#!/usr/bin/env python3
"""Docker simulator for isolated maintenance integration tests."""
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['TEST_HOST'])
repo = Path(os.environ['TEST_REPO'])
state_path = root / 'docker.json'
state = json.loads(state_path.read_text())
a = sys.argv[1:]
with (root / 'docker.log').open('a') as log:
    log.write(json.dumps(a) + '\n')


def save():
    state_path.write_text(json.dumps(state))


def config():
    version = (repo / 'version').read_text().strip()
    names = ['quota-guard', 'openclaw-gateway', 'sandbox-dind', 'openclaw-cli']
    if os.environ.get('MODEL_PROVIDER') == 'local-gpu':
        names.append('local-llm-amd' if os.environ.get('LOCAL_LLM_BACKEND') == 'amd-rocm' else 'local-llm')
    if os.environ.get('CAVEMAN_PROXY_ENABLED') == 'true':
        names.append('caveman-proxy')
    return {'name': 'clawshell', 'services': {name: {
        'container_name': f'clawshell-{name}', 'image': f'test/{name}:{version}',
        **({'build': {'context': str(repo)}} if name == 'quota-guard' else {}),
        **({'profiles': ['cli']} if name == 'openclaw-cli' else {}),
        'healthcheck': {'test': ['CMD', 'true']}}
        for name in names}}


if a[0] == 'compose':
    path = Path(a[a.index('-f') + 1])
    if path.suffix == '.json':
        cfg = json.loads(path.read_text())
    else:
        cfg = config()
    command = next(x for x in a if x in {'ps', 'config', 'pull', 'build', 'up', 'stop'})
    if command == 'ps':
        names = [n for n, s in state['containers'].items() if s['running']]
        if '--services' in a:
            print('\n'.join(names))
        else:
            print('\n'.join('clawshell-' + n for n in names))
    elif command == 'config':
        if '--services' in a:
            print('\n'.join(n for n in cfg['services'] if n != 'openclaw-cli'))
        else:
            print(json.dumps(cfg))
    elif command == 'pull':
        sys.exit(1 if os.environ.get('FAIL_PULL') == '1' else 0)
    elif command == 'build':
        sys.exit(1 if os.environ.get('FAIL_BUILD') == '1' else 0)
    elif command == 'up':
        if os.environ.get('FAIL_UP') == '1' and path.suffix != '.json':
            sys.exit(1)
        names = [x for x in a[a.index('up') + 1:] if x in cfg['services']]
        if not names:
            names = [n for n in cfg['services'] if n != 'openclaw-cli']
        for name in names:
            image = cfg['services'][name]['image']
            state['containers'][name] = {'running': True, 'image': state['tags'].get(image, image)}
        if os.environ.get('MUTATE_STATE') == '1' and path.suffix != '.json':
            (root / 'state/openclaw/data').write_text('new schema')
        save()
    elif command == 'stop':
        for entry in state['containers'].values():
            entry['running'] = False
        save()
elif a[0] == 'ps':
    services = [n for n, s in state['containers'].items() if s['running']]
    match = next((x.split('=', 1)[1] for x in a if x.startswith('label=com.docker.compose.service=')), None)
    if match:
        services = [n for n in services if n == match.split('=')[-1]]
    print('\n'.join('clawshell-' + n for n in services))
elif a[0] == 'inspect':
    name = a[-1].removeprefix('clawshell-')
    entry = state['containers'].get(name)
    if not entry:
        sys.exit(1)
    if '-f' in a:
        print(('running' if entry['running'] else 'exited') if a[a.index('-f')+1] == '{{.State.Status}}' else entry['image'])
    else:
        bad = os.environ.get('FAIL_READY_ALL') == '1' or (os.environ.get('FAIL_READY_NEW') == '1' and entry['image'].endswith(':new'))
        print(json.dumps([{'State': {'Status': 'running' if entry['running'] else 'exited',
                                    'Health': {'Status': 'unhealthy' if bad else 'healthy'}}}]))
elif a[:2] == ['image', 'inspect']:
    print(state['tags'].get(a[-1], a[-1]))
elif a[0] == 'tag':
    state['tags'][a[2]] = a[1]
    save()
elif a[0] in {'stop', 'start'}:
    for container in a[1:]:
        state['containers'][container.removeprefix('clawshell-')]['running'] = a[0] == 'start'
    save()
elif a[0] == 'exec':
    if a[1] == 'clawshell-quota-guard':
        if os.environ.get('FAIL_STATUS') == '1':
            sys.exit(1)
        print(json.dumps({'hosts': {}, 'active_task': None}) if os.environ.get('DEFAULT_STATUS') == '1' else (root / 'state/quota-guard/state.json').read_text())
else:
    sys.exit(f'Unsupported fake Docker call: {a}')
