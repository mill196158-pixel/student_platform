# Production integration preflight — Stages 14–21

Date: **2026-07-30**  
Content worktree: `/Users/annasuvorova/student_platform_content` @ `feature/content-platform`  
Main worktree: `/Users/annasuvorova/student_platform` @ `refactor/chat-tab`  
Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`  
Remote project: `gwdanmwluhrcfxbnplwd`

**Nothing applied / merged / pushed until this preflight + Codex APPROVE + green admin suite.**

## 1. Git state (after `git fetch origin`)

| Worktree | Branch | Status | Notes |
|---|---|---|---|
| content | `feature/content-platform` | clean | ahead **24**, behind **1** vs `origin/refactor/chat-tab` |
| main | `refactor/chat-tab` | clean | equals `origin/refactor/chat-tab` @ `c31f572` |

Behind commit on origin (must merge into feature before/with integration):

* `c31f572` — `chore: normalize CRLF in roster/schedule helpers`

Merge-base: `a14c269`

## 2. Local commits Stages 14–21 (24)

```
0f34fb8 docs(content): Stage 14–21 acceptance audit with Codex APPROVE
514749f fix(content): FilePicker 11 API and vacancy test EOL for audit gates
7b25ca5 docs(content): Stage 20–21 specs Codex APPROVE_WITH_NOTES
544fcd4 feat(content): Stage 19 Import Studio completion with Codex APPROVE
91325f1 fix(content): park Stage 14/15.2 check hardening and content icons
716c604 feat(content): Stage 19 Import Studio foundation with Codex APPROVE_WITH_NOTES
8a3f533 feat(content): Stage 18 reviews/points/moderation with Codex APPROVE
0b4a040 feat(content): Stage 17 vacancies domain UI with Codex APPROVE
65039d4 feat(content): Stage 16.3 reference hardening with Codex APPROVE
5bdccfb feat(content): Stage 16.2 subject signed media with Codex APPROVE_WITH_NOTES
6e03828 feat(content): Stage 16.1 subject card editor with Codex APPROVE
5f23429 docs(content): mark Stage 20–21 specs Codex APPROVE in roadmap
a100974 docs(content): park Content Platform local chain status
3772b4a feat(content): add Stage 16 and 19 SQL foundation drafts
5629da9 feat(content): add Stage 17–18 SQL foundation drafts (vacancies, points)
e279c53 docs(content): add Stage 20 AI and Stage 21 RF infra specs
cebfcf5 feat(content): Stage 15.3 managed profile feed dual-read slice
001e1f0 feat(content): Stage 15.2 news audience junctions and Admin dual-read
183efc8 feat(content): Stage 15.1 managed Home promo dual-read slice
74c779d fix(content): harden home promo parsers after Codex 14B review
691f43e feat(content): add shared Home promo renderer and typed models
2588581 feat(content): add Stage 14A managed content SQL foundation
9c8aba9 docs(content): close Content Platform docs gate after Codex APPROVE
d1796ac docs(content): lock Stage 14–21 Content Platform architecture gate
```

## 3. Migrations to apply (ordered, Stages 14–19 only)

Stage 20–21 are docs-only — **no migrations**.

1. `20260729133000_stage14_managed_content_foundation.sql`
2. `20260729140000_stage15_2_news_audience_extension.sql`
3. `20260729150500_stage16_1_subject_card_foundation.sql`
4. `20260729150550_stage16_1_subject_card_hardening.sql`
5. `20260729150560_stage16_1_subject_card_p1_r2.sql`
6. `20260729150570_stage16_1_subject_card_p1_r3.sql`
7. `20260729150600_stage16_2_subject_assets.sql`
8. `20260729150650_stage16_2_subject_assets_hardening.sql`
9. `20260729150660_stage16_2_subject_assets_p1_fixes.sql`
10. `20260729150670_stage16_2_subject_assets_p1_r2.sql`
11. `20260729150700_stage16_3_reference_corrections.sql`
12. `20260729150750_stage16_3_reference_hardening.sql`
13. `20260729150760_stage16_3_content_media_upload.sql`
14. `20260729151000_stage17_vacancies_domain.sql`
15. `20260729151050_stage17_vacancies_p1_hardening.sql`
16. `20260729152000_stage18_reviews_points_moderation.sql`
17. `20260729152050_stage18_reviews_points_p1_hardening.sql`
18. `20260729152060_stage18_reviews_points_p1_round3.sql`
19. `20260729152070_stage18_reviews_points_p1_round4.sql`
20. `20260729153000_stage19_import_studio_foundation.sql`
21. `20260729153050_stage19_import_studio_p1_hardening.sql`
22. `20260729154000_stage19_import_studio_completion.sql`

## 4. Edge Functions changed vs `origin/refactor/chat-tab`

**New (deploy after migrations):**

* `supabase/functions/content-media/`
* `supabase/functions/subject-media/`
* `supabase/functions/vacancy-media/`

**Unchanged in this branch vs origin:** `news-media`, `cleanup-chat-files`, `dispatch-push-notifications`, `generate-upload-url` — do **not** redeploy unless required by config.

## 5. admin_console suite diagnosis (pre-fix)

| Failure | Classification | Action |
|---|---|---|
| `news_editor_image_test` ×2 | **Outdated test** — seeds default to draft while editor opens Published tab → empty panel | Update seeds to `NewsStatus.published` |
| `admin_auth_session_test` / `widget_test` load failures in earlier audit | **Environment flake / parallel load** — pass in isolation and in current full suite | No product change |

## 6. Hard bans still in force until APPROVE

No push · No merge · No remote apply · No Edge deploy · No real XLSX · No demo publish · No mass push · No force
