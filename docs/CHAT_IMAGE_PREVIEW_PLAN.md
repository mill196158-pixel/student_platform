# Chat image previews: original plus thumbnail

Status: design for review only. No migration, deployment, existing-file rewrite, or production data change is included.

The user clarified that **two server copies are not required**: uploading a compressed copy is acceptable provided the original file on the device is not changed. The original-plus-preview contract below is an optional future design for faster initial display and full-quality opening, not a prerequisite imposed by that clarification.

Automatic lossy JPEG upload remains unresolved. Gallery selection or camera EXIF does not establish that an image is an ordinary photograph: it can contain a QR code, drawing, or document. Current client code has no verified classifier that safely distinguishes every such case. Until a reviewed selection/provenance method is available, uncertain JPEGs must remain unchanged; no automatic JPEG compression is claimed here.

## Current boundary

The chat upload path records one file key, URL, MIME type and size in `chat_files`. A smaller lossy JPEG cannot simultaneously be the unchanged full-quality original. A gallery image may itself be a QR code, drawing, or screenshot; its source does not prove it is a photograph. New static PNG uploads can be recompressed losslessly; that does not solve JPEG thumbnails.

## Proposed contract

1. Keep the existing original object and its current `chat_files` fields unchanged. Add an optional, separately authorised preview reference with its own object key, MIME, byte length, dimensions and immutable revision/hash. Existing rows without a preview must continue to work on old and new clients.
2. On a new image upload, finish the original upload and confirmation first. Generate a bounded preview independently; never overwrite or delete the original. An unavailable or failed preview leaves the original usable and retryable.
3. Authorise a preview with the same chat membership, session and revocation rules as its original. A signed original URL must not be used as a preview identifier or persisted in client state. Confirm ownership and bind the two objects server-side; a caller must not attach a preview from a different chat or account.
4. Show a locally cached preview in the message list; fetch the original only when opened or explicitly saved. Cache keys must include project, account/session and immutable object revision. Revoke or hide access on a known denial without destroying data needed for rollback.
5. For JPEG previews, apply EXIF orientation to the preview only and preserve the original bytes and metadata. Use conservative size/quality limits. Gallery selection alone does not establish photo content: uncertain QR/screenshots/graphics use a lossless preview or the original. A detector cannot prove absence of a QR code; always provide access to the full original.
6. Ensure an interrupted upload cannot publish an orphaned/mismatched pair. Use idempotent per-operation identifiers and explicit states; cleanup only confirmed unreferenced preview objects. Existing forward/retry pipelines retain their current original-file semantics.

## Validation before any rollout

Use an isolated backend and synthetic files to check backward compatibility, membership changes, logout/account switches, concurrent replacement, interrupted upload and recovery, missing previews, byte hashes, EXIF orientation, transparency/animation passthrough, QR scans, accessibility and decode costs. Test Android and iOS cold/warm/offline viewing and compare time-to-first-image and bytes transferred for representative photographs. Review and approve migration and server authorization separately before any production change; keep original objects and a rollback path throughout.
