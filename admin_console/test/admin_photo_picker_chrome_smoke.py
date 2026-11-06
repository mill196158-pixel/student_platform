"""Run the built synthetic picker fixture in a separate headless Chrome."""
import functools
import html
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from PIL import Image

build = Path(sys.argv[1]).resolve()
assert (build / 'index.html').is_file()
done = threading.Event()
photo = Image.effect_noise((2600, 2100), 45).convert('RGB')
buffer = io.BytesIO()
photo.save(buffer, format='JPEG', quality=96, subsampling=0)
synthetic_jpeg = buffer.getvalue()


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/synthetic.jpg':
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Content-Length', str(len(synthetic_jpeg)))
            self.end_headers()
            self.wfile.write(synthetic_jpeg)
            return
        if path in ('/done', '/hold'):
            if path == '/done':
                done.set()
            else:
                done.wait(45)
            payload = b'ok'
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if path == '/':
            payload = (build / 'index.html').read_bytes().replace(
                b'</body>', b'<img src="/hold" style="display:none"></body>')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        super().do_GET()

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(build)))
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='admin_picker_qa_') as directory:
        Path(directory).resolve().relative_to(Path(tempfile.gettempdir()).resolve())
        chrome = os.environ.get('CHROME_BIN', r'C:\Program Files\Google\Chrome\Application\chrome.exe')
        command = [chrome, '--headless=new', '--disable-gpu', '--no-first-run',
                   '--disable-background-networking', '--disable-sync', '--no-proxy-server',
                   '--user-data-dir=' + directory, '--dump-dom',
                   f'http://127.0.0.1:{server.server_port}/']
        result = subprocess.run(command, capture_output=True, text=True, timeout=90,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        match = re.search(r'data-admin-photo-report="([^"]*)"', result.stdout)
        if result.returncode or not match:
            raise RuntimeError(f'QA report unavailable; Chrome exit={result.returncode}')
        report = json.loads(html.unescape(match.group(1)))
        assert 'error' not in report, report
        assert 4 * 1024 * 1024 < report['before'] <= 5 * 1024 * 1024, report
        assert report['eligible'] and report['after'] < report['before'], report
        assert report['originalSame'] and report['windowsTarget'], report
        assert report['mime'] == 'image/jpeg' and report['ticks'] > 0, report
        assert report['mean'] < 20, report
        print(json.dumps(report))
finally:
    server.shutdown()
    server.server_close()
