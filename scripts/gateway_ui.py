#!/usr/bin/env python3
"""Fixed-destination TCP ingress for the isolated Gateway UI/API.

This is a transparent relay (including WebSocket traffic), not an HTTP CONNECT
or SOCKS proxy. Client input cannot select its upstream address or port.
"""
import select
import socket
import socketserver
import threading

UPSTREAM = ('openclaw-gateway', 18789)
LISTEN = ('0.0.0.0', 18789)
MAX_CONNECTIONS = 64


def relay(client, upstream):
    client.settimeout(30)
    upstream.settimeout(30)
    readers = [client, upstream]
    while readers:
        ready, _, _ = select.select(readers, [], [], 300)
        if not ready:
            return
        for source in ready:
            destination = upstream if source is client else client
            data = source.recv(65536)
            if data:
                destination.sendall(data)
            else:
                readers.remove(source)
                destination.shutdown(socket.SHUT_WR)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with socket.create_connection(UPSTREAM, timeout=5) as upstream:
                relay(self.request, upstream)
        except OSError:
            # A disconnected/unready upstream closes only this client session.
            return


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = MAX_CONNECTIONS

    def __init__(self, address, handler):
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        super().__init__(address, handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


if __name__ == '__main__':
    with Server(LISTEN, Handler) as server:
        server.serve_forever()
