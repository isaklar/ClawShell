"""Local-only upstream fixture; counters distinguish forwarding from short circuits."""
import json
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock

COUNTS = Counter()
LOCK = Lock()


class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        if self.path == '/stats':
            with LOCK:
                payload = dict(COUNTS)
            status = 200
        else:
            with LOCK:
                COUNTS[f'{self.command} {self.path}'] += 1
            payload = {'fixture': 'clawshell-integration', 'path': self.path}
            status = {'/auth': 401, '/quota': 429, '/throttle': 429, '/unstable': 503}.get(self.path, 200)
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        # Terminal quota exhaustion has no trustworthy reset; /throttle models
        # a retryable rate limit so both circuit modes have distinct fixtures.
        if self.path == '/throttle' or status == 503:
            self.send_header('Retry-After', '60')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    do_GET = do_HEAD = do_POST = do_DELETE = handle_request

    def log_message(self, *_args):
        pass


if __name__ == '__main__':
    ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
