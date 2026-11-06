"""Run the actual web worker in an isolated headless Chrome on synthetic data.

Requires Pillow and Chrome; uses only a loopback server and a temporary profile.
"""
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from PIL import Image

worker = (Path(__file__).resolve().parents[1] / 'web' /
          'admin_photo_optimizer_worker.js').read_bytes()
photo = Image.effect_noise((2600, 2100), 45).convert('RGB')
image_bytes = io.BytesIO()
photo.save(image_bytes, format='JPEG', quality=96, subsampling=0)
source = image_bytes.getvalue()

done = threading.Event()
html = b'''<!doctype html><body><div id="result">pending</div><script>
async function run() {
  const source = await (await fetch('/synthetic.jpg')).arrayBuffer();
  const worker = new Worker('/worker.js');
  worker.onmessage = async e => {
    if (!(e.data instanceof ArrayBuffer)) { document.querySelector('#result').textContent='FAILED'; await fetch('/done'); return; }
    const original = await createImageBitmap(new Blob([source], {type:'image/jpeg'}));
    const result = await createImageBitmap(new Blob([e.data], {type:'image/jpeg'}));
    const canvas = new OffscreenCanvas(result.width, result.height), ctx = canvas.getContext('2d');
    ctx.drawImage(original, 0, 0, result.width, result.height);
    const a = ctx.getImageData(0, 0, result.width, result.height).data;
    ctx.drawImage(result, 0, 0);
    const b = ctx.getImageData(0, 0, result.width, result.height).data;
    let err = 0, count = 0;
    for (let i=0; i<a.length; i+=16) { err+=Math.abs(a[i]-b[i])+Math.abs(a[i+1]-b[i+1])+Math.abs(a[i+2]-b[i+2]); count+=3; }
    document.querySelector('#result').textContent=JSON.stringify({before:source.byteLength,after:e.data.byteLength,width:result.width,height:result.height,mean:err/count});
    original.close(); result.close(); worker.terminate();
    await fetch('/done');
  };
  worker.onerror = async () => { document.querySelector('#result').textContent='FAILED'; await fetch('/done'); };
  worker.postMessage(source.slice(0));
}
run().catch(async () => { document.querySelector('#result').textContent='FAILED'; await fetch('/done'); });
</script><img src="/hold"></body>'''


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/done':
            done.set()
        if path == '/hold':
            done.wait(30)
        payload, kind = {
            '/': (html, 'text/html'),
            '/worker.js': (worker, 'text/javascript'),
            '/synthetic.jpg': (source, 'image/jpeg'),
            '/done': (b'ok', 'text/plain'),
            '/hold': (b'ok', 'text/plain'),
        }.get(path, (b'', 'application/octet-stream'))
        self.send_response(200 if payload else 404)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='admin_photo_worker_') as directory:
        # Ensure any temporary profile cleanup stays inside the OS temp area.
        Path(directory).resolve().relative_to(Path(tempfile.gettempdir()).resolve())
        chrome = os.environ.get('CHROME_BIN', r'C:\Program Files\Google\Chrome\Application\chrome.exe')
        command = [chrome, '--headless=new', '--disable-gpu', '--no-first-run',
                   '--disable-background-networking', '--disable-sync', '--no-proxy-server',
                   '--user-data-dir=' + directory,
                   '--dump-dom', f'http://127.0.0.1:{server.server_port}/']
        result = subprocess.run(command, capture_output=True, text=True, timeout=60,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        match = re.search(r'<div id="result">(\{.*?\})</div>', result.stdout, re.DOTALL)
        if result.returncode or not match:
            raise RuntimeError(f'Headless worker result={result.returncode}; DOM tail={result.stdout[-500:]}')
        values = json.loads(match.group(1))
        assert values['before'] > 512 * 1024
        assert values['after'] < values['before']
        assert max(values['width'], values['height']) == 1600
        assert values['mean'] < 20
        print(json.dumps(values))
finally:
    server.shutdown()
    server.server_close()
