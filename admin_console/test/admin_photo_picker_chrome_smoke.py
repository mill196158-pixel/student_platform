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
from PIL import Image, ImageChops, PngImagePlugin

build = Path(sys.argv[1]).resolve()
assert (build / 'index.html').is_file()
done = threading.Event()
photo = Image.effect_noise((2600, 2100), 45).convert('RGB')
buffer = io.BytesIO()
photo.save(buffer, format='JPEG', quality=96, subsampling=0)
synthetic_jpeg = buffer.getvalue()
alpha_source = Image.effect_noise((1500, 1000), 40).convert('RGBA')
alpha_source.putalpha(Image.linear_gradient('L').resize(alpha_source.size))


def encode(value, fmt, **kwargs):
    output = io.BytesIO()
    value.save(output, format=fmt, **kwargs)
    return output.getvalue()


png_info = PngImagePlugin.PngInfo()
png_info.add_text('note', 'synthetic')
synthetic_inputs = {
    '/synthetic.jpg': synthetic_jpeg,
    '/synthetic-png': encode(alpha_source, 'PNG', compress_level=0),
    '/synthetic-webp': encode(alpha_source, 'WEBP', lossless=True),
    '/synthetic-metadata': encode(alpha_source, 'PNG', compress_level=0, pnginfo=png_info),
    '/synthetic-animated': encode(alpha_source, 'WEBP', save_all=True,
        append_images=[Image.new('RGBA', alpha_source.size, (255, 0, 0, 80))], duration=100, loop=0),
}
outputs = {}


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path in synthetic_inputs:
            content = synthetic_inputs[path]
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
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

    def do_POST(self):
        parsed = urlparse(self.path)
        name = parsed.query.removeprefix('name=')
        length = int(self.headers.get('Content-Length', '0'))
        if parsed.path != '/capture' or name not in ('png', 'webp') or length > 5 * 1024 * 1024:
            self.send_error(400)
            return
        outputs[name] = self.rfile.read(length)
        self.send_response(204)
        self.end_headers()

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
        for name in ('png', 'webp'):
            assert report[name + 'After'] < report[name + 'Before'], report
            assert report[name + 'Original'] and report[name + 'Mime'] == 'image/webp', report
            assert report[name + 'OriginalMime'] == 'image/' + name, report
            decoded = Image.open(io.BytesIO(outputs[name])).convert('RGBA')
            assert decoded.size == alpha_source.size
            assert ImageChops.difference(decoded.getchannel('A'), alpha_source.getchannel('A')).getbbox() is None
        assert report['metadataFallback'] and report['animatedFallback'], report
        assert report['cancelled'] and report['overlapBlocked'] and report['workerRecovered'], report
        print(json.dumps(report))
finally:
    server.shutdown()
    server.server_close()
