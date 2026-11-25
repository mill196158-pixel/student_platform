"""Run the ordinary project-chat and attachment journey with a private local schema.

The local PDF fixture uses ReportLab and is served only on loopback.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from uuid import uuid4
import hashlib
import sys

from reportlab.pdfgen.canvas import Canvas

from qa_local_schema_suite import ROOT, run_suite


def main():
    with TemporaryDirectory(prefix="project-sheets-", dir=ROOT / "build") as tmp:
        folder = Path(tmp)
        for name in ("project", "control"):
            canvas = Canvas(str(folder / f"{name}.pdf"), pagesize=(420, 300))
            canvas.drawString(40, 160, f"QA SHEET - {name.upper()} COURSE")
            canvas.save()
        handler = partial(SimpleHTTPRequestHandler, directory=tmp)
        with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                def setup(schema, accounts):
                    fields = ("group", "year", "term", "curriculum_project", "curriculum_control",
                              "off_project", "off_control", "team_project", "team_control",
                              "chat_project", "chat_control", "file_project", "file_control")
                    ids = {key: str(uuid4()) for key in fields}
                    template = (ROOT / "scripts/qa_project_chat_fixture.sql").read_text("utf-8")
                    migration = (ROOT / "supabase/migrations/20260825202929_academic_plan_import_persistence.sql").read_text("utf-8")
                    start = migration.index("create or replace function private.academic_assessment_types_canonical(")
                    end = migration.index("create or replace function private.academic_workload_is_valid", start)
                    template = migration[start:end].replace("private.", schema + ".") + template
                    params = dict(ids, student=accounts[0], login=schema,
                                  base=f"http://127.0.0.1:{server.server_port}", schema=schema)
                    for key, value in params.items():
                        template = template.replace(":" + key + ":", value)
                    digest = hashlib.sha256((folder / "project.pdf").read_bytes()).hexdigest()
                    return template, dict(ids, pdfHash=digest)

                return run_suite("projectchat", setup,
                                 "integration_test/ordinary_project_chat_local_test.dart",
                                 "STUDENT_PROJECT_CHAT_LOCAL", required_markers=(
                                     "PASS ordinary login, materials, actual course assessment, exact team, native PDF and SHA-256",
                                     "PASS 036 two system Back requests restored",))
            finally:
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    sys.exit(main())
