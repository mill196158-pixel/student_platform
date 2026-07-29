# AI Assistants Spec — Stage 20 (spec only)

Date: **2026-07-29**  
Branch: `feature/content-platform` (base `origin/refactor/chat-tab`)  
Worktree: `/Users/annasuvorova/student_platform_content`  
Related: `docs/master_roadmap.md` (Stage 20), `docs/content_platform/CONTENT_PLATFORM_SPEC.md` §8, `ACCEPTANCE_CHECKLIST.md` §AA.

**Status: SPEC DONE** / Codex **APPROVE_WITH_NOTES** (2026-07-29 refresh) — documentation only.  
Stages 14–19 are locally complete on `feature/content-platform`.  
No implementation, no paid AI integration, no remote deploy.

---

## 0. Scope and non-goals

This document defines **optional AI-assisted workflows** for administrators and moderators after Stages 14–19 are stable. It does **not** authorize:

- automatic publication of AI output;
- silent background AI actions;
- sending student PII to third-party models without explicit policy;
- billing or subscription to paid AI APIs without owner approval;
- replacing human moderation or import confirmation.

**Explicit rule: do not implement paid AI now.** Any future provider choice (self-hosted, regional API, or commercial) requires a separate owner decision, budget, and Codex security review.

---

## 1. Hard rules (non-negotiable)

| Rule | Meaning |
|---|---|
| **Draft-only** | AI output is always stored as a draft suggestion (`status=draft_suggestion` or equivalent UI state). It never becomes published content, approved import rows, or moderation decisions by itself. |
| **Human publish** | An authenticated admin with the correct RBAC permission must explicitly accept, edit, and confirm every AI suggestion before apply/publish. |
| **No silent auto-actions** | No cron, webhook, or import pipeline may call AI and mutate production data without a visible admin step. Failures must surface in UI, not log-only. |
| **Minimize PII** | Send the smallest text excerpt needed for the task. Strip or redact phone, email, passport, SNILS, bank details, full student lists, and chat message bodies unless the task cannot work without them (and then require elevated permission + audit). |
| **Source journal** | Every AI invocation records: actor, feature key, input hash (not full payload), provider/model id, token/cost estimate, linked entity ids, timestamp, outcome (`suggested` / `rejected` / `accepted_partial` / `failed`). |
| **Cost limits** | Per-day and per-admin caps; hard stop when exceeded; no queue overflow to paid tier without owner flag. |
| **Full kill-switch / opt-out** | Global `ai.enabled=false` disables all AI UI and server routes. Per-feature flags allow granular rollout. Owner can disable without redeploying app (server-side flag in `app_feature_flags` or successor). |

---

## 2. AI capability options (Stage 20)

Each option is **independent**. Implement only after product need, Codex APPROVE, and owner budget decision. Priority order below is a suggestion, not a mandate.

### 2.1 Excel column detection (`ai.import.column_detect`)

**Problem:** Unknown `.xlsx` layouts force manual column mapping in Import Studio (Stage 19).

**Input (minimized):** Header row + up to 5 sample data rows per sheet; sheet names; target domain hint (`teachers` | `subjects` | `students` | `curriculum`).

**Output:** Suggested mapping `{ source_column → canonical_field }` with confidence scores and rationale (plain Russian). Unknown columns flagged.

**Human step:** Admin reviews mapping in Import Studio UI, adjusts, then dry-run. AI never applies.

**PII note:** Do not send full file; sample rows only. Mask cells that match phone/email patterns before send.

---

### 2.2 Teacher/subject matching and duplicate detection (`ai.import.entity_match`)

**Problem:** Fuzzy names, typos, and duplicate teachers/subjects during import.

**Input:** Normalized name strings + optional department/catalog codes from dry-run diff; existing catalog snippets (id + display name only, no student data).

**Output:** Ranked match candidates with `new | update | possible_duplicate | error` classification and short explanation.

**Human step:** Admin resolves each row in Import Studio diff table; merge/skip/create only via confirmed apply.

**Constraint:** Matching uses **IDs** when present; AI assists only when ID missing. Never auto-merge duplicates.

---

### 2.3 OCR cleanup (`ai.ocr.cleanup`)

**Problem:** On-device OCR (Stage 13.9 topic extraction) produces noisy lines, broken words, duplicate bullets.

**Input:** Raw OCR text lines from admin review screen (already user-visible); language hint `ru`/`en`.

**Output:** Cleaned lines with merge/split/dedupe suggestions; preserves original OCR in immutable side panel.

**Human step:** Admin edits/reorders in existing review UI; AI button is optional «Предложить правки».

**PII note:** OCR may contain names; process on server only with retention ≤ 24h for suggestion cache; no training use.

---

### 2.4 Subject card draft from file (`ai.subject.draft_from_file`)

**Problem:** Admins upload PDF/DOCX/syllabus and need a starting point for subject card (Stage 16).

**Input:** Extracted text from uploaded file (server-side text extraction, not raw binary to external AI if avoidable); subject title if known.

**Output:** Draft sections: description, learning outcomes, control form hints, hours, tips — each as editable draft fields.

**Human step:** Opens in Subject Admin visual editor as draft; publish requires `subjects.write` + preview.

---

### 2.5 News / promo draft (`ai.content.promo_draft`)

**Problem:** Writing home promo or profile feed cards (Stage 15) from a brief.

**Input:** Admin prompt (title intent, audience, CTA goal); optional reference link text (fetch allowlist domains only).

**Output:** Suggested `home_promo_v1` / `profile_feed_card_v1` payload fields (title, subtitle, cta_label) — **not** image generation in v1.

**Human step:** Loads into content draft editor; template validation still runs server-side on publish.

---

### 2.6 Vacancy classification (`ai.vacancy.classify`)

**Problem:** User-submitted vacancies (Stage 17) need triage: format, remote/hybrid, suspicious contact, wrong category.

**Input:** Vacancy title, organization, description excerpt (max length cap); no submitter identity in model prompt.

**Output:** Suggested tags (`internship`, `part_time`, `remote`, `needs_contact_review`, etc.) and moderation priority hint.

**Human step:** Moderator queue; classification is advisory only.

---

### 2.7 Review pre-check (`ai.review.precheck`)

**Problem:** Text reviews (when enabled after Stage 18) may contain PII, insults, or off-topic content.

**Input:** Review text + structured tags already chosen by student; entity type (teacher/subject).

**Output:** Flags: `possible_pii`, `possible_insult`, `possible_accusation`, `off_topic`, with highlighted spans in moderator UI only.

**Human step:** Moderator decides approve/reject; AI flag does not auto-reject or hide.

---

### 2.8 PII / abuse scan (`ai.moderation.pii_abuse_scan`)

**Problem:** Cross-cutting scan for UGC: reviews, vacancy descriptions, user-submitted corrections, chat-adjacent reports (where applicable).

**Input:** Text under moderation; configurable max tokens.

**Output:** Structured findings list with severity; no automatic deletion.

**Human step:** Unified Moderation queue (Stage 18); scan runs on «Запросить проверку» or on open, never in background publish path.

**Note:** Prefer deterministic regex + blocklists for phones/emails; AI supplements edge cases only.

---

### 2.9 Import error explanation (`ai.import.explain_error`)

**Problem:** Dry-run errors like `FK_VIOLATION` or `DUPLICATE_OFFERING` are opaque to non-technical admins.

**Input:** Error code, row number, field names, **no** full row PII — use masked values.

**Output:** Plain Russian explanation + suggested fix («Проверьте код группы в колонке B»).

**Human step:** Display-only in Import Studio error panel; admin fixes spreadsheet and re-runs dry-run.

---

### 2.10 Admin content assistant (`ai.admin.content_assistant`)

**Problem:** Admins need in-context help: «Как настроить аудиторию promo?», «Почему предмет не виден группе?»

**Input:** Admin question + optional current screen id (`home_promo_editor`, `import_studio`, etc.); **no** live student data queries unless read-only RPC snapshot ids are attached by server.

**Output:** Step-by-step guidance referencing product docs and allowed actions; must not invent permissions or SQL.

**Human step:** Chat-style panel in Admin; answers are not executed commands. Dangerous intents («удали всех студентов») → refusal template.

**Constraint:** Retrieval over internal help docs only; no arbitrary SQL generation.

---

## 3. Feature flags (proposed)

Store in `app_feature_flags` (extend existing Stage 13.6 pattern) or dedicated `ai_feature_flags`:

| Flag key | Default | Description |
|---|---|---|
| `ai.enabled` | `false` | Global kill-switch |
| `ai.import.column_detect` | `false` | §2.1 |
| `ai.import.entity_match` | `false` | §2.2 |
| `ai.import.explain_error` | `false` | §2.9 |
| `ai.ocr.cleanup` | `false` | §2.3 |
| `ai.subject.draft_from_file` | `false` | §2.4 |
| `ai.content.promo_draft` | `false` | §2.5 |
| `ai.vacancy.classify` | `false` | §2.6 |
| `ai.review.precheck` | `false` | §2.7 |
| `ai.moderation.pii_abuse_scan` | `false` | §2.8 |
| `ai.admin.content_assistant` | `false` | §2.10 |
| `ai.provider.external_allowed` | `false` | Blocks any non-self-hosted provider until owner enables |
| `ai.logging.full_prompt` | `false` | If false, journal stores hash + length only |

Server must check flags on **every** AI RPC/Edge route; client hides buttons when flag off (defense in depth: server still enforces).

---

## 4. Data minimization

1. **Extract locally first:** OCR cleanup and file-to-text run on our infrastructure before optional external model call.
2. **Row sampling:** Excel/CSV — headers + N sample rows, never entire workbook to external API.
3. **Redaction pipeline:** Regex + dictionary for RU phone, email, passport-like sequences; replace with `[REDACTED]` in outbound prompt.
4. **No student chat bulk export** to AI.
5. **Retention:** Suggestion cache TTL 24h; journal metadata 90d; no prompt storage unless `ai.logging.full_prompt` explicitly enabled for debug window.
6. **Regional preference:** When RF infra (Stage 21) exists, route AI to self-hosted or in-region endpoint before foreign SaaS.

---

## 5. Audit fields (proposed table sketch)

Not implemented — schema for future migration review:

```
ai_invocation_journal
  id uuid PK
  feature_key text not null
  actor_user_id uuid not null
  input_hash text not null          -- sha256 of redacted payload
  input_byte_size int not null
  provider text not null            -- 'disabled' | 'self_hosted' | 'external'
  model_id text null
  linked_entity_type text null      -- import_batch | content_item | review | ...
  linked_entity_id uuid null
  outcome text not null             -- suggested | accepted | rejected | failed | blocked_flag
  token_estimate int null
  cost_estimate_rub numeric null
  error_code text null
  created_at timestamptz not null default now()
```

Admin audit UI: filter by feature, actor, date; no replay of full prompts by default.

---

## 6. Cost controls

| Control | Behavior |
|---|---|
| Daily org cap | e.g. 500 invocations / day; configurable |
| Per-admin cap | e.g. 50 / day |
| Token ceiling | Hard truncate input; refuse over limit with user message |
| Budget flag | `ai.budget.exceeded` → all features return 503 + «AI временно отключён» |
| No auto-upgrade | Exceeding cap must **not** silently switch to paid tier |
| Cost visibility | Admin dashboard: today’s count, estimated cost (if external), top features |

Self-hosted models still count invocations for abuse protection.

---

## 7. Architecture sketch (future implementation)

```
Admin UI → AI suggest button
         → RPC ai_suggest_* (RBAC + feature flag + rate limit)
         → Redaction service
         → Provider adapter (null if ai.enabled=false)
         → Draft record / UI suggestion only
         → Human confirm → existing publish/import/moderation RPCs
```

- All AI entry points are **separate RPCs** from publish/import apply paths.
- Provider API keys live server-side only (Edge/env), never Flutter Web.
- Unit tests: flag off → 403; draft never changes `published` status; journal row always written.

---

## 8. Dependencies and order

Implement AI features **after**:

1. Stage 19 Import Studio dry-run UI (for §2.1, §2.2, §2.9);
2. Stage 16 subject editor (for §2.4);
3. Stage 15 content editor (for §2.5);
4. Stage 17–18 vacancies + moderation (for §2.6–§2.8).

Stage 21 RF infra may change provider placement but does not block spec approval.

---

## 9. Acceptance mapping

Checklist §AA items map 1:1 to §2 options and §1 hard rules. Mark checklist `[x]` only after this doc + Codex APPROVE.

---

## 10. Open decisions (owner / Codex)

- [ ] Provider strategy: self-hosted only vs approved external API
- [ ] Whether OCR cleanup runs entirely on-device vs server
- [ ] Retention period for `ai_invocation_journal`
- [ ] Per-feature rollout order after Stage 19 stable

**Reminder:** Paid AI is **out of scope** for current implementation sessions unless owner explicitly authorizes budget and provider.
