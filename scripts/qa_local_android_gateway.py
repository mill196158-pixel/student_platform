"""TLS and WebSocket gateway for the ordinary app on an isolated Android AVD.

Run with a private directory. A stop-gateway file in that directory ends the
session. The public CA belongs on the test device; the private key stays here.
"""
import asyncio
from datetime import datetime, timedelta, timezone
import ipaddress
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from uuid import uuid4

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


ORIGIN = "https://127.0.0.1:55443"
AUTH = "supabase_auth_student_platform_e2e"
NETWORK = "supabase_network_student_platform_e2e"


def start_local_auth(name):
    config = json.loads(subprocess.check_output(["docker", "inspect", AUTH]))[0]
    settings = dict(x.split("=", 1) for x in config["Config"]["Env"])
    if (config["Name"] != "/" + AUTH or NETWORK not in config["NetworkSettings"]["Networks"]
            or urlsplit(settings["GOTRUE_DB_DATABASE_URL"]).hostname != "supabase_db_student_platform_e2e"
            or settings["API_EXTERNAL_URL"] != "http://127.0.0.1:55321/auth/v1"):
        raise RuntimeError("Expected the dedicated local E2E database")
    allowed = {"GOTRUE_DB_DATABASE_URL", "GOTRUE_DB_DRIVER", "GOTRUE_API_HOST", "GOTRUE_API_PORT",
               "GOTRUE_EXTERNAL_EMAIL_ENABLED", "GOTRUE_MAILER_AUTOCONFIRM"}
    env = {k: v for k, v in settings.items() if k in allowed or k.startswith("GOTRUE_JWT_")}
    env.update(API_EXTERNAL_URL=ORIGIN + "/auth/v1", GOTRUE_JWT_ISSUER=ORIGIN + "/auth/v1",
               GOTRUE_SITE_URL=ORIGIN, GOTRUE_DISABLE_SIGNUP="true")
    args = ["docker", "run", "--detach", "--name", name, "--network", NETWORK,
            "--publish", "127.0.0.1:55444:9999"]
    for key in env:
        args.extend(("--env", key))
    return subprocess.check_output([*args, config["Image"]], env={**os.environ, **env},
                                   text=True).strip()


def certificates(folder):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Student local Android E2E")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=1))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]),
                           critical=False).sign(key, hashes.SHA256()))
    pem = folder / "ordinary_test_ca.pem"
    with pem.open("xb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with tempfile.NamedTemporaryFile(dir=folder, delete=False) as f:
        private = Path(f.name)
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                  serialization.NoEncryption()))
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(pem, private)
        return ctx
    finally:
        private.unlink()


async def pipe(reader, writer):
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()


async def connection(reader, writer):
    upstream = None
    uploading = None
    try:
        data = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 20)
        first, *headers = data[:-4].split(b"\r\n")
        method, target, version = first.split(b" ")
        if not target.startswith(b"/") or target.startswith(b"//"):
            return
        auth = target.startswith(b"/auth/v1/")
        upgrade = any(line.lower() == b"upgrade: websocket" for line in headers)
        if not upgrade:
            headers = [line for line in headers if not line.lower().startswith(b"connection:")]
            headers.append(b"Connection: close")
        source, upstream = await asyncio.open_connection("127.0.0.1", 55444 if auth else 55321)
        first = b" ".join([method, target.removeprefix(b"/auth/v1") if auth else target, version])
        upstream.write(b"\r\n".join([first, *headers, b"", b""]))
        await upstream.drain()
        uploading = asyncio.create_task(pipe(reader, upstream))
        await pipe(source, writer)
    except (OSError, asyncio.IncompleteReadError, ValueError, TimeoutError):
        pass
    finally:
        if uploading is not None:
            uploading.cancel()
            await asyncio.gather(uploading, return_exceptions=True)
        if upstream is not None:
            upstream.close()
        writer.close()


async def run(folder):
    if not folder.is_dir() or (folder / "stop-gateway").exists():
        raise RuntimeError("Use a fresh private directory")
    name = "student-ordinary-gotrue-" + uuid4().hex[:12]
    tls = certificates(folder)
    identity = start_local_auth(name)
    try:
        async with await asyncio.start_server(connection, "127.0.0.1", 55443, ssl=tls):
            print("Local Android gateway ready", flush=True)
            while not (folder / "stop-gateway").exists():
                await asyncio.sleep(.5)
    finally:
        current = subprocess.check_output(["docker", "inspect", "--format", "{{.Name}} {{.Id}}",
                                           name], text=True).strip()
        if current != "/" + name + " " + identity:
            raise RuntimeError("Local test Auth identity changed")
        subprocess.run(["docker", "rm", "-f", identity], check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    asyncio.run(run(Path(sys.argv[1]).resolve(strict=True)))
