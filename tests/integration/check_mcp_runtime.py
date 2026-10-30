#!/usr/bin/env python3
"""Test actual SDK imports, server startup and MCP calls without Docker or stubs."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.metadata import version
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

from probe import mcp

SOURCE = Path(__file__).resolve().parents[2]


class ProxyFixture(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.requests.append(self.path)
        denied = self.path == 'http://fixture.invalid/denied'
        payload = ({'blocked_by': 'target-gateway', 'reason': 'out_of_scope'} if denied
                   else {'fixture': 'mcp-runtime-check'})
        body = json.dumps(payload).encode()
        self.send_response(403 if denied else 200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    # Import the real SDK before starting anything. This must not run in the
    # unit-test process, whose MCP module is deliberately replaced by stubs.
    from mcp.server.fastmcp import FastMCP
    assert FastMCP.__module__.startswith('mcp.server.fastmcp')
    print('Runtime versions: ' + ', '.join(f'{name}={version(name)}' for name in
          ('mcp', 'httpx', 'pydantic', 'pydantic-settings')), flush=True)
    proxy = ThreadingHTTPServer(('127.0.0.1', 0), ProxyFixture)
    thread = threading.Thread(target=proxy.serve_forever, daemon=True)
    thread.start()
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    process = None
    try:
        with tempfile.TemporaryFile(mode='w+') as logs:
            environment = dict(os.environ, BLACKBOX_LIVE_TESTING='true', MCP_HOST='127.0.0.1',
                MCP_PORT=str(port), MCP_HTTP_TIMEOUT='3',
                TARGET_GATEWAY_PROXY=f'http://127.0.0.1:{proxy.server_port}')
            process = subprocess.Popen([sys.executable, str(SOURCE / 'pentest-tools-mcp/server.py')],
                env=environment, stdin=subprocess.DEVNULL, stdout=logs, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 20
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f'MCP server exited during startup ({process.returncode})')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=0.5):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise TimeoutError('MCP server did not become ready')
                        time.sleep(0.1)
                endpoint = f'http://127.0.0.1:{port}/mcp/'
                allowed = mcp(endpoint, 'http_request', {'url': 'http://fixture.invalid/allowed'})
                assert allowed['status'] == 200, allowed
                assert json.loads(allowed['body_preview']) == {'fixture': 'mcp-runtime-check'}, allowed
                denied = mcp(endpoint, 'http_request', {'url': 'http://fixture.invalid/denied'})
                assert denied['status'] == 403 and denied.get('gateway_decision') == 'out_of_scope', denied
                assert ProxyFixture.requests == ['http://fixture.invalid/allowed', 'http://fixture.invalid/denied']
                print('PASS: real MCP import, startup, initialization, tool listing, forwarding and denial propagation')
            except Exception:
                logs.seek(0)
                print(logs.read(), file=sys.stderr, flush=True)
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    finally:
        proxy.shutdown()
        proxy.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    main()
