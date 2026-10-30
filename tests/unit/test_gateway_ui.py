"""The UI ingress relays opaque bytes only to its configured Gateway socket."""
import importlib.util
from pathlib import Path
import socket
import socketserver
import threading
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('gateway_ui', SOURCE / 'scripts/gateway_ui.py')
gateway_ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway_ui)


class GatewayUITests(unittest.TestCase):
    def serve(self, server):
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def cleanup():
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        self.addCleanup(cleanup)
        return server.server_address

    def upstream(self):
        connected = threading.Event()
        received = []
        class Echo(socketserver.BaseRequestHandler):
            def handle(self):
                connected.set()
                self.request.settimeout(5)
                while True:
                    data = self.request.recv(65536)
                    if not data:
                        self.request.sendall(b'tail-after-half-close')
                        return
                    received.append(data)
                    self.request.sendall(data)
        server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Echo)
        server.daemon_threads = True
        address = self.serve(server)
        return address, connected, received

    def relay(self, upstream, limit=None):
        patcher = patch.object(gateway_ui, 'UPSTREAM', upstream)
        patcher.start()
        self.addCleanup(patcher.stop)
        if limit is not None:
            patcher = patch.object(gateway_ui, 'MAX_CONNECTIONS', limit)
            patcher.start()
            self.addCleanup(patcher.stop)
        return self.serve(gateway_ui.Server(('127.0.0.1', 0), gateway_ui.Handler))

    def test_binary_transparency_and_response_after_client_half_close(self):
        upstream, _, received = self.upstream()
        address = self.relay(upstream)
        payload = b'GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n\x81\x00\xff\x01'
        with socket.create_connection(address, timeout=3) as client:
            client.sendall(payload)
            result = b''
            while len(result) < len(payload):
                result += client.recv(65536)
            self.assertEqual(result, payload)
            client.shutdown(socket.SHUT_WR)
            tail = b''
            while data := client.recv(65536):
                tail += data
            self.assertEqual(tail, b'tail-after-half-close')
        self.assertEqual(b''.join(received), payload)

    def test_connect_host_input_cannot_choose_a_different_upstream(self):
        upstream, _, received = self.upstream()
        address = self.relay(upstream)
        request = b'CONNECT forbidden.invalid:443 HTTP/1.1\r\nHost: forbidden.invalid\r\n\r\n'
        with socket.create_connection(address, timeout=3) as client:
            client.sendall(request)
            client.shutdown(socket.SHUT_WR)
            response = b''
            while data := client.recv(65536):
                response += data
        self.assertEqual(b''.join(received), request)
        self.assertEqual(response, request + b'tail-after-half-close')

    def test_concurrency_limit_closes_extra_connection(self):
        upstream, connected, _ = self.upstream()
        address = self.relay(upstream, limit=1)
        with socket.create_connection(address, timeout=3) as first:
            self.assertTrue(connected.wait(timeout=3))
            with socket.create_connection(address, timeout=3) as second:
                self.assertEqual(second.recv(1), b'')
            first.shutdown(socket.SHUT_WR)
            while first.recv(65536):
                pass
