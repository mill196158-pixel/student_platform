# Admin image processing: isolated Web smoke, 6 November 2026

This is a local synthetic smoke test of the current image picker preparation
code. It is not a deployment, production upload, complete editor test or
release approval. Existing server objects were not changed.

A separate headless Chrome process used a new test-only profile and a
localhost server. External hostname resolution was blocked. The server
configured Flutter's bootstrap to use the CanvasKit files in the local build;
the production worker and compiled application code were not patched. The
fixture called `LocalAdminImagePicker.prepareSelected` directly and did not
open the OS file chooser or upload anything.

On this one synthetic fixture set:

| Input | Result |
| --- | --- |
| 256×256 PNG with transparency, 262,556 bytes | 891-byte PNG; output dimensions and every decoded RGBA pixel matched; transparency was retained. |
| 2200×2200 JPEG, 19,880,950 bytes | 1,725,140-byte JPEG, 1600×1600; MIME and filename matched the result. |
| Oversized JPEG with EXIF orientation 6 | Rejected by the legacy optimisation path; input was not changed. |

The synthetic input file hashes were unchanged after the run. These examples
do not prove that lossy JPEG encoding preserves a QR code, fine text or image
quality, nor that an unrelated encoder cannot return different pixels at the
same dimensions. The legacy large-JPEG Web path is lossy and remains a known
risk for QR codes and diagrams. Other browser configurations and full editor
interaction remain separate validation requirements.

The status callback from the actual Flutter fixture reported success, but its
captured screenshot was a single background colour; the visual Flutter UI was
**not verified**. Flutter's separate Chrome test harness also failed to finish
even for a minimal `1 + 1` test. Do not interpret this smoke as proof of full
Web UI compatibility or responsiveness.

Local evidence under `design_preview/optimizer_qa/`:

- `admin_web_smoke_report.json` — SHA-256 `badca171db994dfbbc44aaa4847b18d93ad631c3b1b888e599b27af77f797281`.
- `admin_web_smoke.cjs` — SHA-256 `127c10d21383a2f6d91aec332aaa32307720d7598484399c1cfe2988f4060b65`.
- `qa_admin_optimizer_fixture.dart` — SHA-256 `03a214b9713c8e5cdf612201582c9514222d1a2d77bf21e2064d9217c767a0f1`.
- Source and built `admin_photo_optimizer_worker.js` — identical SHA-256
  `6913623a32dccfb92047c19ee6661790d2bda0422406689bb4fdb91827056fff`.
- `admin_web_fixture_20261106_b/main.dart.js` — SHA-256
  `04d1f69017c1991b5ef74bf298ee56f9f948e358da922f8c55a5c38e4b3b42b5`.
- `admin_web_inputs_20261106/` contains only generated test images;
  `admin_web_fixture_smoke.png` is the non-evidentiary blank screenshot.

The report and evidence review do not mark any Content Platform checklist item
done and do not authorize a production deployment or publication.
