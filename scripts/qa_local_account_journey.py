"""Exercise the ordinary login UI and restart it with the same local storage."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main(first, second, ca):
    configs = [json.loads(path.read_text(encoding="utf-8-sig")) for path in (first, second)]
    if not all(c["port"] == 55321 and c["email"] == c["login"] + "@student.local"
               and c["login"].startswith("e2e_") for c in configs):
        raise ValueError("Expected two local QA students")
    if configs[0]["recipientId"] == configs[1]["recipientId"] or configs[0]["anonKey"] != configs[1]["anonKey"]:
        raise ValueError("Expected distinct accounts on the same local backend")
    if b"-----BEGIN CERTIFICATE-----" not in ca.read_bytes() or b"PRIVATE KEY" in ca.read_bytes():
        raise ValueError("Supply a public QA certificate")
    # The disposable directory inherits the private account-config directory's ACL.
    with tempfile.TemporaryDirectory(prefix="auth-ui-", dir=first.parent) as folder:
        state = Path(folder)
        defines = state / "defines.json"
        defines.write_text(json.dumps({"SUPABASE_URL": "https://127.0.0.1:55443",
                                       "SUPABASE_ANON_KEY": configs[0]["anonKey"]}), encoding="utf-8")
        env = dict(os.environ, STUDENT_AUTH_LOCAL_FIRST=str(first), STUDENT_AUTH_LOCAL_SECOND=str(second),
                   STUDENT_AUTH_LOCAL_CA=str(ca), STUDENT_AUTH_LOCAL_STATE=str(state))
        for phase in ("login", "restore"):
            env["STUDENT_AUTH_LOCAL_PHASE"] = phase
            result = subprocess.run(["flutter.bat" if os.name == "nt" else "flutter", "test", "--no-pub",
                                     "--reporter=expanded", "--dart-define-from-file=" + str(defines),
                                     "test/ordinary_account_journey_local_test.dart"], cwd=ROOT, env=env)
            if result.returncode:
                return result.returncode
        return 0


if __name__ == "__main__":
    sys.exit(main(*(Path(arg).resolve(strict=True) for arg in sys.argv[1:])))
