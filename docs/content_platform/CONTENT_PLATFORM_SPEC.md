# Content Platform Spec (Stages 14–21)

Date: **2026-07-29**  
Branch: `feature/content-platform` (base `origin/refactor/chat-tab`)  
Worktree: `/Users/annasuvorova/student_platform_content`  
Remote Supabase (read-only confirmed): `gwdanmwluhrcfxbnplwd`  
Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`

Implementation contract. Does **not** replace `docs/master_roadmap.md`.  
Acceptance: `ACCEPTANCE_CHECKLIST.md`. Active work: `docs/agent_coordination/CURRENT_TASK.md`.

---

## 0. Session constraints

Owner-authorized Stage 14–19 migrations and `content-media`, `subject-media`,
`vacancy-media` deploys are completed. From this point, no **further** remote
migration apply, Edge deploy or GitHub push (including force) without an
explicit owner command; no real-data import; no `service_role` in Flutter Web;
no deletion of existing production data; no edits to already-applied
migrations; no duplicate roadmap.

Owner-authorized Stage 19.1 foundation apply completed on `2026-08-25`
(`20260825102603_academic_ingestion_identity_foundation`,
`20260825102845_academic_process_calendar_foundation`). No curriculum/calendar
data was imported; both server dry-runs remain explicitly apply-disabled.

Local commits after Codex **APPROVE** are allowed.

---

## 1. Remote summary (audit baseline + current state)

### Remote DB (`gwdanmwluhrcfxbnplwd`)

| Area | Live |
|---|---|
| News | `news_posts`, `news_versions`, `news_views`, `news_media_cleanup_queue`; audience enum **`all`\|`group`** only |
| Reviews 13.6 | `entity_reviews`, `review_tags`, `review_reports`, `review_moderation_actions`, `app_feature_flags` |
| Subject profiles / imports | `subject_student_profiles`, `subject_import_*`, `teacher_import_*` |
| Content Platform Stages 14–19 | Applied: `content_items*`, vacancies, points ledger, reference tables, placements/templates and Import Studio |

### Live RBAC permission codes (confirmed)

`content.read`, `content.write`, `content.publish`, `moderation.read`, `moderation.write`, `moderation.action`, `academic.read`, `subjects.write`, `teachers.write`, `students.read`, `students.write`, `students.suspend`, `groups.write`, `terms.manage`, `dashboard.view`, `audit.read`, `roles.manage`.

### App surfaces

| Surface | State |
|---|---|
| News | Production; shared renderer in `packages/student_ui` |
| Home «Застрял с заданием?» | Hardcoded `_HelpCard` |
| Profile «Лента» | Hardcoded `_demoFeed` |
| Reference / vacancies | Hardcoded `_helpItems` / `_demoJobs` |
| Reviews mobile | Backend exists; authoring UI largely missing |
| Points | None |
| Import | CLI + admin XLSX for teachers/subjects/students |

### Reuse decisions

1. Do **not** overload `news_posts` for promo / reference / vacancies / profile feed.
2. Reuse news security patterns (DEFINER RPCs, FORCE RLS, revoke client DML, versions, private signed media).
3. Extend news audience via junctions + locked legacy semantics (Stage 15.2).
4. Extend `entity_reviews` for moderation + points; no second reviews system.
5. Vacancies = dedicated domain model.
6. Subject content extends existing profile tables + private assets; IDs only.
7. Import Studio wraps existing academic import paths; no Web `service_role`.

---

## 2. Stage 14 — Managed Content foundation (locked DDL contract)

### 2.1 Concepts

content item · approved template · placement · audience · asset · version · origin (`demo|admin|import|user_submission`) · allowlisted events.

### 2.2 Stage 14 permission scope

Stage 14 RPCs use **only** live keys: `content.read` / `content.write` / `content.publish` via `private.require_admin_permission(...)`.  
No new permission codes in Stage 14.

### 2.3 Tables

```
content_templates
  key text not null
  schema_version int not null
  title text not null
  allowed_placements text[] not null
  schema_doc jsonb not null default '{}'::jsonb   -- Admin docs only; NOT runtime engine
  is_active boolean not null default true
  primary key (key, schema_version)
  -- Immutability enforcement (required):
  -- Once (key, schema_version) is referenced by any content_items OR content_item_versions
  -- snapshot, UPDATE/DELETE of schema_doc / allowed_placements / validator semantics is forbidden.
  -- Evolution = INSERT a new schema_version. Enforced by trigger + SQL security assertion.

content_items
  id uuid PK default gen_random_uuid()
  template_key text not null
  schema_version int not null
  -- FK (template_key, schema_version) → content_templates
  status text not null check (status in ('draft','published','archived'))
  origin text not null check (origin in ('demo','admin','import','user_submission'))
  title text not null default ''
  payload jsonb not null default '{}'::jsonb
  priority int not null default 0
  starts_at timestamptz null
  ends_at timestamptz null
  is_hidden boolean not null default false
  audience_mode text not null
    check (audience_mode in ('all','groups','users','groups_and_users'))
  version_number int not null default 1
  row_version int not null default 1              -- optimistic concurrency
  created_by / updated_by / published_by uuid null
  published_at timestamptz null
  created_at / updated_at timestamptz not null default now()
  check (ends_at is null or starts_at is null or ends_at > starts_at)
  -- NO sort_order on content_items (ordering lives on placements only)

content_item_versions
  id uuid PK
  content_item_id uuid not null references content_items(id) on delete cascade
  version_number int not null
  snapshot jsonb not null
  created_by uuid null
  created_at timestamptz not null default now()
  unique (content_item_id, version_number)

content_item_placements
  content_item_id uuid not null references content_items(id) on delete cascade
  placement text not null check (placement in ('home_promo','profile_feed','reference'))
  sort_order int not null default 0              -- SOLE order source per placement
  primary key (content_item_id, placement)

content_item_audience_groups
  content_item_id uuid not null references content_items(id) on delete cascade
  group_id uuid not null references groups(id) on delete cascade
  primary key (content_item_id, group_id)

content_item_audience_users
  content_item_id uuid not null references content_items(id) on delete cascade
  user_id uuid not null references users(id) on delete cascade
  primary key (content_item_id, user_id)

content_assets
  id uuid PK
  content_item_id uuid not null references content_items(id) on delete cascade
  storage_bucket text not null
  storage_path text not null
  mime_type text not null
  byte_size bigint not null check (byte_size >= 0)
  checksum text null
  created_by uuid null
  created_at timestamptz not null default now()
  unique (storage_bucket, storage_path)
  -- Stage 14: FK to content_items only (no polymorphic owner_kind).
  -- Later domains (vacancy/subject) get their own asset tables or Stage-gated extension.

content_media_cleanup_queue
  id uuid PK
  storage_bucket text not null
  storage_path text not null
  source_content_item_id uuid null
  source_title text null
  enqueued_at timestamptz not null default now()
  attempts int not null default 0
  last_error text null
  processed_at timestamptz null

content_item_dismissals
  content_item_id uuid not null references content_items(id) on delete cascade
  user_id uuid not null references users(id) on delete cascade
  dismissed_at timestamptz not null default now()
  can_reshow_after timestamptz null
  primary key (content_item_id, user_id)

content_item_events
  id uuid PK
  content_item_id uuid not null references content_items(id) on delete cascade
  user_id uuid not null references users(id) on delete cascade
  event_type text not null check (event_type in ('impression','click'))
  event_hour timestamptz not null   -- UTC hour bucket set by RPC only
  created_at timestamptz not null default now()
  unique (content_item_id, user_id, event_type, event_hour)
  -- record_content_event computes event_hour in UTC; direct client DML forbidden

content_audit_log
  id uuid PK
  actor_user_id uuid null
  action text not null
  entity_type text not null
  entity_id uuid null
  meta jsonb not null default '{}'::jsonb   -- ids/status only; no PII dumps
  created_at timestamptz not null default now()
```

Every table: `ENABLE` + `FORCE` RLS; `REVOKE ALL` from PUBLIC/anon/authenticated; table DML only `service_role`; client via RPCs.

### 2.4 Ordering

Mobile/admin lists for a placement sort by:

1. `content_item_placements.sort_order` ASC  
2. `content_items.priority` DESC  
3. `published_at` DESC NULLS LAST  

`admin_reorder_content_placement(
  p_placement text,
  p_ordered_ids uuid[],
  p_expected_row_versions int[]
)` requires equal-length arrays, rejects duplicate IDs, locks affected
`content_items` in deterministic UUID order, validates every expected
`row_version`, updates only placement `sort_order`, and increments
`content_items.row_version` for every affected item. Any mismatch rolls back
the whole reorder.

Sort order is stored only on placement rows; item `row_version` changes only as a concurrency token.

### 2.5 Audience mode consistency

| mode | Junction invariant | Match |
|---|---|---|
| `all` | both junctions empty | every eligible authenticated student |
| `groups` | ≥1 group; users empty | active enrollment in any listed group |
| `users` | ≥1 user; groups empty | explicit user row |
| `groups_and_users` | ≥1 group and ≥1 user | OR of group membership and explicit user |

Publish rejects empty targeted audience (resolved count = 0).  
Setter is transactional: replace junctions + set mode + bump `row_version`.  
Single helper `private.content_item_visible_to_user(item_id, user_id)` shared by mobile list and admin preview count.

### 2.6 Optimistic concurrency

Mutating admin RPCs that touch an existing item take `p_expected_row_version int` (single-item) or `p_expected_row_versions int[]` (reorder). Mismatch → conflict error and full rollback. Success increments `row_version`.  
Applies to: update draft, set placements, set audience, publish, unpublish, archive, restore version, reorder.  
Exception: `admin_create_content_draft` has no prior row_version.

### 2.7 Payload validation (fail-closed; no pg_jsonschema)

Remote has **no** `pg_jsonschema`. Runtime validator:

`private.validate_content_payload(template_key, schema_version, payload) returns void`

Implemented as **versioned PL/pgSQL** per-template field checks (required keys, types, max lengths, enums, CTA allowlist).  
This is **not** a JSON Schema engine. `schema_doc` is UI documentation only — never executed as a schema engine.  
Unknown template / inactive / wrong schema_version / extra unknown keys → exception.  
Publish re-validates.

**Asset-in-payload invariant (publish + restore):** every `*_asset_id` / asset ref inside payload/blocks must:

1. exist in `content_assets`;
2. belong to the **same** `content_item_id`;
3. pass the template MIME/type rule for that field.

Missing/foreign/wrong-MIME asset → loud failure (no silent drop).

CTA rules v1:

- internal route from fixed allowlist (e.g. `/diary`, `/info`, `/chat/...` patterns approved in migration); **or**
- `https:` URL (host allowlist starts empty / product-approved list in migration constants).

### 2.8 Templates v1

| key | schema_version | allowed_placements | Payload (validated) |
|---|---|---|---|
| `home_promo_v1` | 1 | `{home_promo}` | title, subtitle, icon_key, gradient_colors[2..4], image_asset_id?, cta_label, cta_route?, cta_url?, dismissible, reshow_after_hours? |
| `profile_feed_card_v1` | 1 | `{profile_feed}` | title, subtitle, image_asset_id?, cta_label, cta_route?, cta_url? |
| `reference_article_v1` | 1 | `{reference}` | **Legacy/compat:** requires `category` (string), `icon_key`, `short_text`, blocks[] (`text\|image\|file\|link\|cta`), optional `cta`. Category string is **not** identity SoT once categories table exists. |
| `reference_article_v1` | 2 | `{reference}` | **Canonical for new Admin writes:** `icon_key`, `short_text`, blocks[] (`text\|image\|file\|link\|cta`), optional top-level `cta`. **No** client-controlled `category` field — category SoT is `reference_categories` FK. Server may denormalize category title into read models only. |

Placement must be ∈ `allowed_placements`.

### 2.9 Version snapshot + restore

Snapshot JSON includes: payload, template_key, schema_version, schedule, priority, is_hidden, audience_mode, placements[], audience_group_ids[], audience_user_ids[], asset_ids[].  
Restore creates a **new** `version_number`, writes draft fields from snapshot, bumps `row_version`; does **not** auto-publish. Missing referenced asset → loud failure.

### 2.10 Events / privacy

- Allowlist: `impression`, `click` only.
- Dedupe: unique `(user, item, event_type, event_hour)` where `event_hour` is a UTC hour bucket written by RPC (not `date_trunc` expression index on timestamptz).
- Caller must currently be allowed to see the item.
- Retention target: raw 30 days then purge (function prepared; cron later).
- No device fingerprint / location / free-text / CTA URL stored in events.

### 2.11 Safe delete (chosen rule)

Two different operations — do not mix:

1. **Individual asset deletion** is forbidden while the current item (any status) still references that asset in payload/blocks or `content_assets` row for the item. Detach via a new draft version first if needed.
2. **`admin_safe_delete_content`** (`content.publish`) may delete an **archived** item, its version history and assets **transactionally** after queueing storage cleanup:
   1. status must be `archived`;
   2. enqueue all asset paths into `content_media_cleanup_queue`;
   3. delete item (cascades versions/placements/audience/assets/events/dismissals);
   4. write audit log.

Edge drain of the cleanup queue was subsequently deployed as part of the
owner-authorized Stage 14–19 rollout.

### 2.12 RPCs

Admin: `admin_list_content_items`, `admin_get_content_item`, `admin_create_content_draft`, `admin_update_content_draft`, `admin_set_content_placements`, `admin_set_content_audience`, `admin_preview_content_audience`, `admin_publish_content`, `admin_unpublish_content`, `admin_archive_content`, `admin_list_content_versions`, `admin_restore_content_version`, `admin_reorder_content_placement`, `admin_safe_delete_content`.

Mobile: `get_my_content_for_placement`, `dismiss_content_item`, `record_content_event`.

### 2.13 Storage

Private bucket `content-media`; Edge `content-media` deployed; signed
upload/download; MIME/size whitelist; path `content/{actor}/{uuid}.ext`.
Every signed URL re-checks authorization.

### 2.14 Demo governance (14.1)

- `origin=demo`; Admin filter «Демо»; archive/delete via Admin.
- Successful server empty/delete ⇒ no hardcoded resurrection for that slot.
- Server error ⇒ error/last-good-cache; never silent demo-as-live.
- Keep current hardcoded UI until migration/replacement ready; dual-read must label demos.

---

## 3. Stage 15 — Home / News / Profile

### 15.1 Home promo

Managed `home_promo` + `home_promo_v1`; shared `StudentHomePromoCard` in `packages/student_ui`; Admin preview = same widget; cache-first + resume/pull-to-refresh; dismiss via `content_item_dismissals`.

### 15.2 News audience (locked semantics)

Add `news_audience_groups`, `news_audience_users` (composite PKs, lookup indexes, FORCE RLS, no client DML). Do **not** rewrite the news backend.

**Legacy column projection** (enum stays `all|group` for compatibility):

- Junctions empty → existing legacy semantics (`all` / single `group` + `audience_group_id`).
- Any junction exists → `audience_type` projected as `'group'` (never `'all'` with junctions).
- Groups / mixed → `audience_group_id` = first deduplicated group id (old clients).
- Users-only → `audience_group_id = NULL` with `audience_type='group'` (legacy readers see no single-group match; new resolver uses junctions).
- Cross-table invariants via deferred constraint triggers (CHECK cannot inspect junctions).

**Shared resolver** `private.news_audience_matches_user(post_id, user_id)` used by:

- `get_my_published_news`
- `mark_news_seen`
- admin recipient preview (counts only, no PII list)
- any visibility gate used before signed media for news

Match rules:

1. `audience_type='all'` **and** both junctions empty → all **eligible** students.
2. `audience_type='group'` + `audience_group_id` set **and** junctions empty → that group (legacy).
3. If **any** junction row exists → junctions are the **sole** match source (legacy columns ignored for matching). Match = group membership OR explicit user.
4. Eligibility uniform everywhere: active user + active non-ended enrollment. Blocked / transferred / unknown / unenrolled never match.

**Transactional `admin_set_news_audience`** (`content.write`, draft-only, locks row + `expected_version`):

- `all` → clear junctions; `audience_type='all'`; `audience_group_id=null`
- `groups` → ≥1 group; clear users; project first group + full group junctions; `audience_type='group'`
- `users` / `groups_and_users` → non-empty junctions; never leave `audience_type='all'` with junctions
- Audit meta: mode + counts only (not user-id arrays)

**Lifecycle coverage** (not only the setter):

- `admin_update_news_draft` rejects direct audience-field patches (use setter only).
- Snapshots include normalized audience ids/mode; restore + duplicate copy junctions transactionally.
- Publish rejects invalid/empty targeted audiences.
- Published posts: unpublish → edit audience → publish.

**Client dual-read (fail-closed writes):**

- Missing new RPCs: legacy all/single-group editing remains; multi-group/user controls disabled with explicit compatibility state; never silent collapse into legacy fields.
- Cache/image bytes user-scoped; evict/replace on logout, account switch, audience revocation, archive/unpublish, successful refresh. Test A→B same device + revoked-audience stale cache.

Hidden/archived/unpublished never leak via RPC/cache/signed URL.

### 15.3 Profile feed

Placement `profile_feed` only by explicit admin choice; **no auto-copy from news**.

Locked contracts (Codex plan):

- Feed is a **list**: parse/cache all valid `profile_feed_card_v1` rows in server order; one malformed row must not hide siblings; no per-card N+1.
- Cache scoped by authenticated user; clear on logout/account switch.
- Dual-read: missing RPC → labeled demo; successful empty → hide feed (no demo resurrection); hard error → last-good cache or error (never demo-as-live).
- Managed `impression` once per visible card + `click` before CTA; never for demo.
- Admin create/list require `template_key=profile_feed_card_v1` **and** placement `profile_feed` via explicit action only.
- `image_asset_id` edit disabled until signed asset path; preserve existing ids; no raw paths / broken images.
- No new SQL if Stage 14 seed already present.

---

## 4. Stage 16 — Subjects & reference

### 16.1 Subject card editor

Text/links/ordering foundation for the student-facing subject card. Binary images/files upload stays in **16.2** (no editable `image_asset_id` in 16.1; §Q image/file checkboxes stay open).

#### Locked contracts (Codex plan)

**Field ownership**

| Aggregate | Owns |
|---|---|
| `subject_catalog` | name, full description, department, control form, requirements, learning outcomes, useful links, status |
| `subject_student_profiles` | short description, what to expect, how to pass / prep tips, useful materials note, common pitfalls, relevance date, section order |
| `subject_offering_student_profiles` | offering-specific notes only (`local_description`, `teacher_specific_note`, `assessment_note`, `workload_note`, `semester_tips`) |
| `curriculum_subjects` (via offering) | `hours_total`, `credits` — **SoT**; never duplicated onto `subject_student_profiles` |
| `offering_teachers` | teacher links by `(subject_offering_id, teacher_id)` only |

**Merge (offering → effective card):** blank override strings normalize to `NULL`. `NULL` inherits catalog/profile. Same mapping in SQL `get_subject_card`, Dart model, Admin Preview, and Mobile renderer.

| Offering field | Merge rule |
|---|---|
| `local_description` | Overrides effective `description` |
| `semester_tips` | Overrides effective `how_to_pass` |
| `teacher_specific_note` | Additive offering-only section (not an override) |
| `assessment_note` | Additive offering-only section |
| `workload_note` | Additive offering-only section |

Lookups/writes use `subject_id` / `subject_catalog_id` / `subject_offering_id` — **name is never a key**.

**Hours/credits:** resolved only through selected `subject_offering_id` → curriculum. Without offering → show unavailable; no invented catalog defaults. Editing hours/credits is a separate ID-bound curriculum operation, not the catalog profile setter.

**Teachers:** editable only when an offering is explicitly selected; persist only via transactional RPC writing `offering_teachers`. No offering → picker disabled/read-only; never persist teacher names or synthesize catalog-level teacher links.

**Section order:** fixed allowlist of keys (shared Dart + SQL). Reject unknown keys and duplicates. Omitted supported keys append in default order.

Default allowlist (order):  
`short_description`, `description`, `learning_outcomes`, `what_to_expect`, `how_to_pass`, `requirements`, `useful_materials_note`, `useful_links`, `common_pitfalls`, `teachers`, `hours_credits`, `relevance_date`, `teacher_specific_note`, `assessment_note`, `workload_note`.

Additive offering-only keys appear only when the offering has a non-null value; if omitted from a stored order they append after `relevance_date` in the default relative order above.

**Concurrency / versions / audit**

- Every edited aggregate requires optimistic concurrency (`row_version` / expected version).
- Catalog+profile update locks rows, updates atomically, increments version, writes one complete `subject_versions` snapshot including all 16.1 fields; restore is transactional and includes new fields.
- Offering overrides have their own version/audit contract; not silently folded into catalog history.

**RPC / access**

- Admin Web writes only through `SECURITY DEFINER` RPCs gated by `subjects.write`; revoke `PUBLIC`/`anon`.
- Mobile reads via one chatty-safe RPC e.g. `get_subject_card(p_subject_offering_id)` returning merged typed payload + teacher IDs; validates authenticated student access to that offering; must not leak another group’s override.

**Shared UI**

- Typed `SubjectCardPayload` + `StudentSubjectCardPreview` in `packages/student_ui` (fail-closed; no HTML/JS).
- Admin visual editor (list + form + phone preview) reuses the same preview widget.
- Links editable in 16.1; images/files deferred to 16.2.

### 16.2 Subject files

Private signed subject media for card images/files. No Base64 in DB.
`subject-media` is deployed; further deploys remain owner-gated.

**Status:** implementation Codex **APPROVE_WITH_NOTES** (no open P0/P1);
remote apply and `subject-media` deploy completed. Residual: owner-controlled
physical Storage finalize e2e.

#### Locked contracts (Codex plan)

**Signed-media boundary (not Postgres-minted URLs)**

| Step | Actor | Contract |
|---|---|---|
| request upload | Admin Edge | Re-auth `subjects.write`; reserve upload intent + path; return short-lived signed upload URL |
| finalize upload | Admin Edge + RPC | Verify actual `storage.objects` row (bucket/path/MIME/size) before registering metadata; client-supplied size/MIME/checksum are not authoritative |
| request download | Student/Admin Edge | Re-auth every read; return short-lived signed URL; bind asset↔catalog/offering access |
| cleanup worker | Local Edge/worker | Claim/retry/complete queue; idempotent; never expose paths to clients |

**Asset model**

- Owner XOR: `subject_catalog_id` XOR `subject_offering_id` (real FKs).
- `asset_kind`: at least `hero_image` | `attachment`.
- Version chain keyed by stable `logical_asset_id` (one current version per logical asset).
- Hero: at most one current hero per owner; image MIME only.
- Attachments: multiple independent chains; approved image/document MIME.
- MIME/size whitelist server-side; max 20 MiB (aligned with draft).
- Descriptors in `get_subject_card`: ids + presentation metadata only — never bucket/path/checksum/signed URLs.

**Concurrency / cleanup / delete**

- First insert locks owning `subject_catalog` / `subject_offerings` row (not only empty asset set).
- Owner FKs: prefer `ON DELETE RESTRICT` + audited safe-delete (mandatory cleanup enqueue in the same transaction before metadata removal).
- **Safe-delete rule:** a **current** asset may be deleted directly **only when** its effective catalog/offering presentation is unpublished; deletion enqueues cleanup and removes metadata in one transaction. If the effective presentation is published, require supersede or unpublish first. Historical unreferenced versions remain deletable with cleanup enqueue.
- Download/list auth reuses Stage 16.1 offering access/publication helpers (no drifted reimplementation).
- Permissions: Admin write=`subjects.write`; Admin list/download=`subjects.read` or write; students=authenticated offering access only; revoke `PUBLIC`/`anon`; no direct client Storage DML.

**Card payload / cache**

- `get_subject_card` returns current asset descriptors (hero + attachments) in the same response — not a separate Mobile round-trip.
- Upload intents: short-lived, actor/owner-bound, single-use, finalize-idempotent.
- Signed-URL client cache: store `expiresAt`, user-scoped, refresh before expiry, clear on logout/access denial; never treat expired URL as offline content.

### 16.3 Reference

Managed reference section on the Info tab. No arbitrary HTML/JS.

#### Locked contracts (Codex plan)

1. **Articles** reuse Stage 14 `content_items` with `template_key=reference_article_v1` and placement `reference` only — no separate article table.
2. **Categories SoT:** `reference_categories` (`id`, stable `key`, `title`, `icon_key`, `status`, `sort_order`, `row_version`). Article↔category via FK join table (one category per article).
3. **Schema versions:** new Admin writes use **`schema_version=2`** (no client `category` in payload). Stage 14 **`schema_version=1`** remains readable/valid for compatibility; its `category` string is never identity. Server may denormalize published category title into Mobile/Admin read models.
4. **Publish gates:** published category + placement `reference` + valid payload (v1 or v2) + valid linked assets.
5. **Ordering:** article order = `content_item_placements.sort_order`; category order = concurrency-safe category reorder RPC (expected `row_version`).
6. **Payload:** typed `icon_key`, `short_text`, allowlisted blocks `text|image|file|link|cta` only; optional top-level CTA; no HTML/JS.
7. **Admin auth:** draft save = `content.write` + expected versions; publish/archive/restore = `content.publish`; audience/preview via Stage 14 resolver.
8. **Version/restore:** snapshots include `reference_category_id`. Restore recreates association transactionally with payload/audience/placement, creates a **new** content version, fails loudly if category UUID is missing. Restore-to-draft may keep an archived category; **publish** still requires a **published** category.
9. **Media:** `content_assets` + local **content-media** signed Edge boundary (upload intent → finalize from Storage metadata → authorized download → leased cleanup). Do **not** reuse subject-media ownership/paths; never return storage paths to clients.
10. **Mobile read:** one batched RPC returns visible categories + articles (no N+1; no signed URLs in card payload).
11. **Cache:** user-scoped, cache-first; access denial clears cache; successful empty does **not** resurrect demo; missing RPC may show only explicitly labeled legacy/demo fallback.
12. **Corrections:** `submit_content_correction` only for deliverable **reference** articles (`reference_article_v1` + placement `reference`); concurrency-safe anti-spam (advisory/row lock per reporter); reporter PII never returned to Admin list clients.
13. **Correction lifecycle (exact):** `content_corrections.content_item_id` becomes **nullable** `ON DELETE SET NULL` with **immutable snapshots** (`item_title`, `template_key`, `schema_version` captured at submit). `admin_safe_delete_content` **rejects** while any **open** correction exists for the item. After all corrections are closed, delete may proceed and journal rows remain (with null `content_item_id` + snapshots).
14. **Resolve:** reject requires reason; all resolve/lifecycle actions audited.

**Status:** contracts and implementation Codex **APPROVE**; remote apply and
`content-media` deploy completed. Further apply/deploy/push remains
owner-gated; signed-upload intent/finalize residuals stay explicitly tracked.

---

## 5. Stage 17 — Vacancies

Dedicated tables: `vacancies`, versions, audience junctions, assets, reports, moderation actions.  
Status: `draft → submitted → in_moderation → approved/published → expired|archived|rejected`.  
User submit never auto-publishes. Demo: `origin=demo` + «Пример» or non-production audience.

---

## 6. Stage 18 — Reviews, points, unified moderation

Extend 13.6 with moderation statuses for publish-after-approve.  
`student_points_ledger`: +1 on approve, unique per `review_id`, compensating −1 on violation removal; not money.  
Cannot moderate own review. Unified Admin Moderation queue.

---

## 7. Stage 19 — Import Studio

Admin hub + domain validators; template → map → dry-run → diff → confirm apply → batch id → idempotent re-run → safe rollback where possible.  
Curriculum chain uses IDs. No auto current-term flip. No Autumn 2026 without owner. Web: RPC/Edge only.

### 7.1 Multi-format academic ingestion

Academic ingestion is one linked flow with three distinct responsibilities:

1. `curriculum_plan`: what subjects and controls belong to each semester;
2. `academic_process_calendar`: when study, session and GIA periods occur for
   a year/program/plan/group audience;
3. `schedule`: concrete lessons and exams inside published process periods.

Locked identity rules:

- `educational_programs` identifies direction + profile + qualification + study
  form independently of admission year;
- `curriculum_plans` identifies one admission cohort and source/version of that
  program;
- groups link explicitly to a reviewed plan;
- plan-backed curriculum rows use a stable source occurrence key and never
  match globally by subject + semester;
- legacy rows with no plan remain readable and are not inferred/backfilled.

Locked group-recognition rules:

- complete group-name aliases and program-code aliases are separate registries;
  a program alias maps directly to `educational_programs.id`;
- durable group identity is educational program + admission year + parallel
  number + an exceptional discriminator; a display name is not identity;
- for the approved pattern `1-СбПГС-2`, the left number is the parallel, the
  middle token is a reviewed program alias, and the right number is the course;
- the client selects `academic_year_id`; the server derives
  `admission_year = academic_year.start_year - course_number + 1`;
- only Unicode case, spaces, dash variants and approved parentheses variants
  normalize automatically; fuzzy matching and arbitrary letter removal are
  forbidden;
- unknown shape/program, semantic duplicate, inactive program, absent plan or
  multiple reviewed/active plans remain explicit classifications;
- `group_naming_profiles` is not inference truth and is not auto-backfilled;
- Stage 19.1b Slice 1 stores a durable idempotent preview and displays it in
  Admin Web, but cannot create or mutate groups, accounts, enrollments,
  profiles, plans, offerings, group spaces, teams, chats or schedules.

Locked ingestion rules:

- XLSX, text PDF and scanned image/PDF are separate versioned adapters;
- all extraction output is an editable draft with raw/normalized value,
  parser version, warning/confidence and source page/region;
- coordinate-aware PDF adapters group one source subject with one or more
  semester occurrences and typed assessment records (`exam`, `credit`,
  `graded_credit`, `course_project`, `course_work`, `control_work`);
- aggregate source hours/credits remain subject-level and are never multiplied
  across semester occurrences;
- semester, workload and typed controls remain editable; each material edit
  clears review confirmation and invalidates any prior server preview;
- section headings terminate source row bands; unresolved or duplicate
  assessment markers remain visible blockers and cannot be cleared by ordinary
  review confirmation;
- browser extraction is untrusted; server dry-run owns validation and matching;
- unsupported/scanned sources fail closed to `manual_required` or
  `ocr_unavailable`, never to an empty successful import;
- plan v2 apply consumes only a durable, unexpired preview owned by the caller
  and bound to the exact draft-plan row version and normalized payload hash;
- apply requires source review plus exact plan-code confirmation, is atomic and
  idempotent, never deletes omitted occurrences, and rejects archived subject
  matches;
- extraction never changes current term, offerings, teams or chats.

Academic-process calendar contract:

- one calendar series belongs to an academic year and exactly one audience
  shape: global, educational program, reviewed curriculum plan, or confirmed
  group;
- versions are append-only in practice; published/archived metadata and periods
  are immutable at the database boundary, including concurrent edits;
- course + half-year derive semester server-side; a client semester value is
  ignored;
- global/program audiences fail closed if any resolved plan/group would exceed
  its nominal semesters; no group-name inference is allowed;
- inclusive period overlaps follow the explicit server matrix; equal types
  conflict, study/session may overlap practice, and `other` requires a note;
- browser file hashes are untrusted (`source_verified=false`);
- Admin accepts an image/PDF as the official review source, but Web OCR is not
  claimed; periods remain explicitly editable and server dry-run is mandatory;
- foundation dry-run cannot apply, publish, switch the current term, create
  offerings, or create teams/chats.

---

## 8. Stage 20 — AI (spec only)

File later: `AI_ASSISTANTS_SPEC.md`. Draft-only; human publish; kill-switch; minimize PII; cost limits.

---

## 9. Stage 21 — RF infra (roadmap only)

File later: `RF_INFRA_MIGRATION_ROADMAP.md`.  
Caveat: FCM/APNs remain external; VPN independence not promised without physical network test.

---

## 10. Design contract

Same mobile visual language; shared Mobile↔Admin Preview renderer; approved templates only; no raw enum/UUID/JSON in UI; Russian copy; SafeArea; keyboard dismiss; loading/error/empty/success; cache-first; stable images; phone + Admin 1280/1440/1920; a11y; text scale; reduce motion; widget/golden tests for critical templates.

---

## 11. Security contract

RLS + FORCE RLS; no client DML for privileged ops; DEFINER + `search_path=''`; `auth.uid()`; server RBAC; revoke PUBLIC/anon; minimal EXECUTE; no Web service_role; private signed storage; audit; IDOR protection; archived/hidden excluded from mobile RPCs; server-side audience; never trust client authz payload; cleanup/rollback tests.

---

## 12. Permission matrix (live keys)

| Permission | News | Managed content | Vacancies | Moderation | Import |
|---|---|---|---|---|---|
| `content.read` | ✓ | ✓ | admin list | — | — |
| `content.write` | ✓ | ✓ | admin draft | — | — |
| `content.publish` | ✓ | ✓ | publish | — | — |
| `moderation.read` | — | — | queue | queue | — |
| `moderation.write` / `moderation.action` | — | — | moderate | moderate | — |
| `academic.read` | — | — | — | — | dry-run read |
| `subjects.write` / `teachers.write` / `students.write` / `groups.write` / `terms.manage` | — | — | — | — | domain apply |
| `students.read` | — | audience picker | — | author filter | — |
| authenticated student | published-for-me | published-for-me | published + submit | report | — |

---

## 13. Implementation order

1. Docs gate + Codex APPROVE (this revision).
2. Stage 14 SQL + Dart models/renderer stubs + security tests.
3. Stage 15.1 home promo slice.
4. Stage 15.2 news audience.
5. Stage 15.3 profile feed.
6. Stage 16 foundations.
7. Stage 17–18 foundations.
8. Stage 19 Import Studio dry-run foundation.
9. Stage 20–21 specs only.

Each slice: focused diff → tests → Codex review → fix P0/P1 → APPROVE → local commit → next.

---

## 14. Non-goals this session

Remote apply/deploy/push; full demo production migration; paid AI; RF cutover; rewriting Stage 13 chat/group-actions/news-archive/RBAC without confirmed need.
