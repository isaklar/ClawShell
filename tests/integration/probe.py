"""Run inside a non-root probe container; only Python's standard library is needed."""
import json
import socket
import sys
import urllib.error
import urllib.request


def request(url, proxy=None, method='GET', data=None, headers=None):
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({'http': proxy, 'https': proxy} if proxy else {}))
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        response = opener.open(req, timeout=4)
    except urllib.error.HTTPError as exc:
        response = exc
    with response:
        body = response.read().decode()
        return {'status': response.status, 'headers': dict(response.headers), 'body': body}


def mcp(url, tool, arguments):
    headers = {'Accept': 'application/json, text/event-stream', 'Content-Type': 'application/json'}
    next_id = 0

    def rpc(method, params, notification=False):
        nonlocal next_id
        next_id += 1
        body = {'jsonrpc': '2.0', 'method': method, 'params': params}
        if not notification:
            body['id'] = next_id
        response = request(url, method='POST', data=json.dumps(body).encode(), headers=headers)
        if response['status'] >= 300:
            raise RuntimeError(f'MCP HTTP failure: {response}')
        session = next((v for k, v in response['headers'].items() if k.lower() == 'mcp-session-id'), None)
        if session:
            headers['Mcp-Session-Id'] = session
        if notification:
            return None
        payload = response['body']
        content_type = next((v for k,v in response['headers'].items() if k.lower() == 'content-type'), '')
        if 'text/event-stream' in content_type:
            messages = [json.loads(line[5:].strip()) for line in payload.splitlines() if line.startswith('data:')]
            result = next(message for message in messages if message.get('id') == next_id)
        else:
            result = json.loads(payload)
        if 'error' in result:
            raise RuntimeError(f'MCP JSON-RPC failure: {result}')
        return result['result']

    initialized = rpc('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                    'clientInfo': {'name': 'clawshell-integration', 'version': '1'}})
    headers['MCP-Protocol-Version'] = initialized['protocolVersion']
    rpc('notifications/initialized', {}, notification=True)
    try:
        tools = rpc('tools/list', {})
        if tool not in {item['name'] for item in tools['tools']}:
            raise RuntimeError(f'Missing MCP tool: {tool}')
        result = rpc('tools/call', {'name': tool, 'arguments': arguments})
        if result.get('isError'):
            raise RuntimeError(f'MCP tool failure: {result}')
        return json.loads(next(item['text'] for item in result['content'] if item['type'] == 'text'))
    finally:
        response = request(url, method='DELETE', headers=headers)
        if response['status'] not in (200, 202, 204, 405):
            raise RuntimeError(f'MCP session cleanup failed: {response}')


if __name__ == '__main__':
    command, payload = sys.argv[1], json.loads(sys.argv[2])
    if command == 'http':
        print(json.dumps(request(**payload)))
    elif command == 'connect':
        try:
            with socket.create_connection((payload['host'], payload['port']), timeout=2):
                print(json.dumps({'connected': True}))
        except OSError:
            print(json.dumps({'connected': False}))
    elif command == 'mcp':
        print(json.dumps(mcp(**payload)))
    else:
        raise SystemExit(f'Unknown probe: {command}')
