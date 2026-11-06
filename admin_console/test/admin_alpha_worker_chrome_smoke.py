"""Exercise the real alpha worker in isolated headless Chrome, synthetic only."""
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

from PIL import Image, ImageChops, PngImagePlugin

worker = (Path(__file__).resolve().parents[1] / 'web' / 'admin_alpha_optimizer_worker.js').read_bytes()
if os.environ.get('ALPHA_QA_DIAGNOSTIC') == '1':
    worker = worker.replace(b'self.postMessage(null);', b'self.postMessage({error:String(_)});')
    worker = worker.replace(b"if (!webpSize(new Uint8Array(result))) throw new Error('output format');", b"if (!webpSize(new Uint8Array(result))) { const z=new Uint8Array(result); let p=12,s=[]; while(p+8<=z.length){const n=new DataView(z.buffer).getUint32(p+4,true);s.push(fourcc(z,p)+':'+n+':'+z[p+8]);p+=8+n+(n&1);} throw new Error('output format '+s.join(',')); }")
base = Image.effect_noise((1500, 1000), 40).convert('RGBA')
alpha = Image.linear_gradient('L').resize(base.size)
base.putalpha(alpha)


def encode(image, fmt, **kwargs):
    result = io.BytesIO()
    image.save(result, format=fmt, **kwargs)
    return result.getvalue()


png = encode(base, 'PNG', compress_level=0)
webp = encode(base, 'WEBP', lossless=True)
metadata = PngImagePlugin.PngInfo()
metadata.add_text('note', 'synthetic')
metadata_png = encode(base, 'PNG', compress_level=0, pnginfo=metadata)
animated = encode(base, 'WEBP', save_all=True, append_images=[Image.new('RGBA', base.size, (255, 0, 0, 80))], duration=100, loop=0)
apng = encode(base, 'PNG', save_all=True, append_images=[Image.new('RGBA', base.size, (0, 0, 255, 80))], duration=100, loop=0)
icc_webp = encode(base, 'WEBP', lossless=True, icc_profile=b'synthetic-profile')
large = Image.effect_noise((2000, 1200), 40).convert('RGBA')
large.putalpha(Image.linear_gradient('L').resize(large.size))
resized = encode(large, 'PNG', compress_level=0)
sources = {'png': png, 'webp': webp, 'metadata': metadata_png, 'animated': animated,
           'apng': apng, 'icc': icc_webp, 'resize': resized}
outputs = {}
done = threading.Event()
html = b'''<!doctype html><body><div id="result">pending</div><script>
async function run() {
  const report = {};
  for (const name of ['png','webp','metadata','animated','apng','icc','resize']) {
    const input = await (await fetch('/input?name='+name)).arrayBuffer();
    const result = await new Promise(resolve => {
      const worker = new Worker('/worker.js');
      worker.onmessage = e => { worker.terminate(); resolve(e.data); };
      worker.onerror = () => { worker.terminate(); resolve(null); };
      worker.postMessage(input, [input]);
    });
    report[name] = result instanceof ArrayBuffer ? result.byteLength : result;
    if (result instanceof ArrayBuffer) await fetch('/output?name='+name, {method:'POST', body:result});
  }
  document.querySelector('#result').textContent = JSON.stringify(report);
  await fetch('/done');
}
run().catch(async () => { document.querySelector('#result').textContent='FAILED'; await fetch('/done'); });
</script><img src="/hold" style="display:none"></body>'''


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == '/done':
            done.set()
        if parsed.path == '/hold':
            done.wait(45)
        name = parse_qs(parsed.query).get('name', [''])[0]
        payload, kind = {
            '/': (html, 'text/html'), '/worker.js': (worker, 'text/javascript'),
            '/input': (sources.get(name, b''), 'application/octet-stream'),
            '/done': (b'ok', 'text/plain'), '/hold': (b'ok', 'text/plain'),
        }.get(parsed.path, (b'', 'text/plain'))
        self.send_response(200 if payload else 404)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        name = parse_qs(urlparse(self.path).query).get('name', [''])[0]
        n = int(self.headers.get('Content-Length', '0'))
        if name not in sources or n > 5 * 1024 * 1024:
            self.send_error(400)
            return
        outputs[name] = self.rfile.read(n)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='admin_alpha_qa_') as directory:
        Path(directory).resolve().relative_to(Path(tempfile.gettempdir()).resolve())
        chrome = os.environ.get('CHROME_BIN', r'C:\Program Files\Google\Chrome\Application\chrome.exe')
        command = [chrome, '--headless=new', '--disable-gpu', '--no-first-run', '--disable-background-networking',
                   '--disable-sync', '--no-proxy-server', '--user-data-dir=' + directory, '--dump-dom',
                   f'http://127.0.0.1:{server.server_port}/']
        result = subprocess.run(command, capture_output=True, text=True, timeout=90,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        match = re.search(r'<div id="result">(\{.*?\})</div>', result.stdout, re.DOTALL)
        if result.returncode or not match:
            raise RuntimeError(f'Worker report unavailable: exit={result.returncode}; DOM={result.stdout[-500:]}')
        report = json.loads(match.group(1))
        assert all(report[name] is None for name in ['metadata','animated','apng','icc']), report
        for name in ['png', 'webp']:
            assert report[name] is not None and report[name] < len(sources[name]), report
            decoded = Image.open(io.BytesIO(outputs[name])).convert('RGBA')
            assert decoded.size == base.size
            assert ImageChops.difference(decoded.getchannel('A'), base.getchannel('A')).getbbox() is None
        resized_output = Image.open(io.BytesIO(outputs['resize'])).convert('RGBA')
        assert resized_output.size == (1600, 960) and resized_output.getchannel('A').getextrema() == (0, 255)
        print(json.dumps({'png': [len(png), report['png']], 'webp': [len(webp), report['webp']],
                          'resizedPng': [len(resized), report['resize']], 'alpha': 'exact',
                          'metadata': 'fallback', 'animated': 'fallback'}))
finally:
    server.shutdown()
    server.server_close()
