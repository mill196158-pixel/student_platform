# CURRENT_TASK

* Status: **DONE** — Stage 17.1 vacancy ready-publish (Codex APPROVE)
* Branch: `refactor/chat-tab`
* Remote: `gwdanmwluhrcfxbnplwd`
* Migration applied: `20260731123346_stage17_1_vacancy_ready_publish_admin_demo`
* Local file matches remote version
* Edge: none
* Push: not requested

## Symptom

`invalid_status_transition_draft_to_published` when clicking «Опубликовать» on a draft vacancy.

## Fix

Atomic ready-publish for `origin ∈ {admin,demo}` AND `submitted_by IS NULL`:  
draft → in_moderation → approved → published in one transaction.  
User submissions remain moderation-only. Admin client routes eligible drafts to `readyPublish`.

## Operator note

Restart/rebuild Admin Web so it calls `admin_ready_publish_vacancy` (migration alone is not enough for an old bundle).
