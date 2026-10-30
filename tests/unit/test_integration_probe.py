"""Positive/negative HTTP controls and MCP session handling used by Docker tests."""
import importlib.util
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import unittest
import urllib.error

SOURCE = Path(__file__).resolve().parents[2]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SOURCE / 'tests/integration' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe = load('integration_probe', 'probe.py')
mock_http = load('integration_mock_http', 'mock_http.py')


class ProbeTests(unittest.TestCase):
    def server(self, handler):
        server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def cleanup():
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        self.addCleanup(cleanup)
        return f'http://127.0.0.1:{server.server_port}'

    def test_upstream_error_status_and_counter_survive_http_error(self):
        url = self.server(mock_http.Handler)
        before = json.loads(probe.request(url + '/stats')['body']).get('GET /quota', 0)
        response = probe.request(url + '/quota')
        self.assertEqual(response['status'], 429)
        self.assertEqual(json.loads(response['body'])['fixture'], 'clawshell-integration')
        after = json.loads(probe.request(url + '/stats')['body'])['GET /quota']
        self.assertEqual(after, before + 1)

    def test_terminal_quota_and_retryable_throttle_have_distinct_reset_signals(self):
        url = self.server(mock_http.Handler)
        quota = probe.request(url + '/quota')
        throttle = probe.request(url + '/throttle')
        self.assertEqual(quota['status'], 429)
        self.assertNotIn('Retry-After', quota['headers'])
        self.assertEqual(throttle['status'], 429)
        self.assertEqual(throttle['headers']['Retry-After'], '60')

    def test_network_error_cannot_masquerade_as_policy_denial(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), mock_http.Handler)
        port = server.server_port
        server.server_close()
        with self.assertRaises(urllib.error.URLError):
            probe.request(f'http://127.0.0.1:{port}/unreachable')

    def test_mcp_client_negotiates_session_and_decodes_sse_tool_result(self):
        calls = []
        class MCPHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                message = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                calls.append((message['method'], self.headers.get('Mcp-Session-Id')))
                if message['method'] == 'notifications/initialized':
                    self.send_response(202)
                    self.end_headers()
                    return
                result = {
                    'initialize': {'protocolVersion': '2025-03-26'},
                    'tools/list': {'tools': [{'name': 'http_request'}]},
                    'tools/call': {'content': [{'type': 'text', 'text': json.dumps(
                        {'status': 403, 'gateway_decision': 'out_of_scope'})}]},
                }[message['method']]
                # Include an SSE comment before the event to exercise real framing.
                body = (': keepalive\n\nevent: message\ndata: ' + json.dumps(
                    {'jsonrpc': '2.0', 'id': message['id'], 'result': result}) + '\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Mcp-Session-Id', 'integration-session')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_DELETE(self):
                calls.append(('DELETE', self.headers.get('Mcp-Session-Id')))
                self.send_response(204)
                self.end_headers()

        url = self.server(MCPHandler)
        result = probe.mcp(url, 'http_request', {'url': 'http://out-of-scope.test'})
        self.assertEqual(result['gateway_decision'], 'out_of_scope')
        self.assertEqual(calls[0], ('initialize', None))
        self.assertEqual([name for name, _ in calls],
                         ['initialize', 'notifications/initialized', 'tools/list', 'tools/call', 'DELETE'])
        self.assertTrue(all(session == 'integration-session' for _, session in calls[1:]))
