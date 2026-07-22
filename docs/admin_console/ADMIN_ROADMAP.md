# Student Platform Admin — Master Roadmap

> Единый источник правды по Web Admin для Cursor, Codex и разработчика. Читать перед началом каждого нового чата и обновлять после каждого материального изменения.

## Current state

- Last updated: 2026-07-22
- Current branch: `feature/admin-console`
- Current worktree: `/Users/annasuvorova/student_platform_admin`
- Base commit: `89f0890`
- Current stage: 12.2 — real news end-to-end
- Current status: DONE
- Next action: recovery-flow stash pop + отдельный commit; затем 12.3 content renderer package.
- Blockers: none for 12.2.

Допустимые статусы: TODO, IN PROGRESS, REVIEW, DONE, BLOCKED. Одновременно только один этап может иметь статус IN PROGRESS / IN REVIEW как активный.

## Product vision

Student Platform Admin — отдельная визуальная веб-панель на Flutter Web. Она открывается через браузер на Windows и macOS.

Панель предназначена для человека, далёкого от программирования и базы. Пользователь не должен видеть UUID, SQL, названия таблиц, технические ключи, `service_role` и внутренние ошибки базы.

Админка сочетает:

1. Визуальное управление:
   - новости;
   - баннеры;
   - разрешённые контентные блоки;
   - настоящий телефонный предпросмотр;
   - редактирование свойств;
   - перестановка;
   - дублирование;
   - скрытие;
   - архив;
   - Undo;
   - черновики;
   - публикация.
2. Табличное управление:
   - предметы;
   - преподаватели;
   - студенты;
   - семестры;
   - расписание;
   - задания;
   - модерация;
   - поиск;
   - фильтры;
   - сортировка;
   - формы;
   - массовые операции;
   - Excel-импорт.

Админка не является произвольным редактором таблиц базы. Все будущие записи выполняются только через разрешённые RPC или Edge Functions.

## Architecture decisions

- Мобильное приложение остаётся в корневом `lib/`.
- Web Admin находится в `admin_console/`.
- Всё хранится в одном GitHub-репозитории.
- Разработка ведётся в отдельном git worktree.
- Общие presentation widgets живут в `packages/student_ui` (в т.ч. `StudentHomeView`, news cards, `StudentNewsStorySheet`).
- Отдельный `packages/content_renderer` остаётся следующим шагом унификации (12.3).
- Изменение контента не требует выпуска новой версии приложения.
- Новый технический вид UI может требовать обновления приложения.
- Firebase Hosting используется для размещения сайта.
- Supabase Auth/RBAC используется для входа и прав.
- `service_role` запрещён в браузере и в mobile.
- Код должен работать на macOS и Windows.
- Абсолютные локальные пути запрещены в исходном коде.

## Current project facts

- Новости главной: production path — `get_my_published_news` + cache-first в `HomeDashboardService`; `_localNews()` только fallback при ошибке сети без кеша.
- Существуют `subject_catalog`, `subject_offerings`, `subject_student_profiles`, `subject_offering_student_profiles`, `teachers`, `offering_teachers`.
- Push-инфраструктура уже реализована; Firebase настроен.
- Admin worktree: `feature/admin-console`.

## Security debt

- Часть академических таблиц сейчас без RLS.
- `anon`/`authenticated` имеют избыточные grants.
- `users` UPDATE policy потенциально позволяет менять опасные поля.
- `is_admin()` не должен доверять редактируемому `users.role`.
- RLS нельзя включать механически без проверки текущих Flutter-запросов.

## News requirements

Четыре варианта карточек:

- `gradientText`;
- `imageOverlay`;
- `imageOnly`;
- `imageWithText`.

Рабочая версия (12.2):

- маленькое изображение карточки / большое в story;
- title / subtitle / body;
- focal point + overlay opacity;
- порядок / приоритет;
- аудитория all|group;
- starts_at / ends_at;
- draft / published / archived;
- версии и restore;
- предпросмотр + полный `StudentNewsStorySheet`;
- публикация без обновления приложения.

## Subjects requirements

Разделять:

- `subject_catalog` — общий предмет;
- `subject_student_profiles` — общая информация студентам;
- `subject_offerings` — предмет группы и семестра;
- `subject_offering_student_profiles` — локальные особенности.

## Teachers requirements

Использовать существующие `teachers` и `offering_teachers`.

## User workflow rules

- Работать быстро и точно.
- Не выполнять лишние проверки.
- Targeted-проверки обязательны.
- Не запускать analyze всего мобильного приложения без необходимости.
- Не применять миграции без разрешения.
- Не делать commit/push без разрешения.
- Не использовать force/reset.
- Не изменять чужие или незнакомые файлы.
- Обновлять roadmap после каждого этапа.
- Не отмечать этап DONE до пользовательского ревью и remote smoke.

## Roadmap

### 12.0 — Web Admin foundation

- Goal: создать автономный desktop-first Flutter Web каркас и локальные UX-прототипы ключевых разделов без подключения к Supabase.
- Status: REVIEW
- Related files: `admin_console/`, `packages/student_ui/`, `docs/admin_console/ADMIN_ROADMAP.md`, `scripts/run_admin_web.sh`
- Remote applied/deployed: нет
- Notes: локальный визуальный редактор новостей и mock-таблицы; Supabase не подключался на этом этапе.

### 12.1 — Security and RBAC

- Goal: подготовить безопасный административный доступ до подключения реальных данных.
- Status: DONE
- Related files: `supabase/migrations/20260721202054_admin_rbac_and_audit.sql`, `supabase/checks/admin_rbac_security_review.sql`, `docs/admin_console/ADMIN_RBAC_BOOTSTRAP.md`, `admin_console/lib/core/auth/`
- Commit SHA: `81791ba` (+ housekeeping rename)
- Remote applied/deployed: migration `20260721202054` / `admin_rbac_and_audit` applied; Edge/Web Admin deploy не выполнялся
- Notes: bootstrap `mill453020` = global `super_admin`; local role-play 23/23; remote smoke PASS.

### 12.2 — Real news end-to-end

- Goal: администратор создаёт новость в Web Admin, загружает изображение, сохраняет черновик и публикует; после публикации новость появляется в Student Platform без обновления приложения.
- Status: DONE
- Deliverables:
  - Tables: `news_posts`, `news_versions`, `news_views`
  - Statuses: `draft` / `published` / `archived`
  - Fields: sort_order, priority, starts_at/ends_at, audience all|group, variants (`gradientText`, `imageOnly`, `imageOverlay`, `imageWithText`), title/subtitle/body, image_path, focal point, overlay opacity, created_by/updated_by/published_by + timestamps
  - RPCs (SECURITY DEFINER, RBAC): `admin_list_news`, `admin_get_news`, `admin_create_news_draft`, `admin_update_news_draft`, `admin_publish_news`, `admin_unpublish_news`, `admin_archive_news`, `admin_duplicate_news`, `admin_reorder_news`, `admin_list_news_versions`, `admin_restore_news_version`, `get_my_published_news`, `mark_news_seen`, `admin_can_manage_news_media`, `admin_can_read_news_media`
  - Storage: private bucket `news-media`
  - Edge Function: `news-media` (`createUpload` / `createDownload` / `delete`) — JWT + RBAC, no service_role in Flutter
  - Web Admin: `SupabaseNewsRepository` + `SupabaseAdminImageStore` in real mode; `Local*` in demo
  - Preview: real `StudentHomeView` + full `StudentNewsStorySheet`
  - Mobile: cache-first / stale-while-revalidate via `PublishedNewsCache`
  - Checks: `supabase/checks/news_posts_security_review.sql`, `docs/admin_console/NEWS_RUNTIME_SMOKE.md`
- Related files:
  - `supabase/migrations/20260722110804_news_posts_and_admin_rpc.sql`
  - `supabase/functions/news-media/`
  - `supabase/checks/news_posts_security_review.sql`
  - `admin_console/lib/features/content/news/`
  - `packages/student_ui/lib/src/home/widgets/student_news_story_sheet.dart`
  - `lib/src/ui/home/home_dashboard_service.dart`
  - `docs/admin_console/NEWS_RUNTIME_SMOKE.md`
- Commit SHA: `60c1e7e` (+ follow-up docs/history align)
- Remote applied/deployed: migration `20260722110804` / `news_posts_and_admin_rpc` applied; Edge `news-media` v1 ACTIVE (`verify_jwt=true`); runtime smoke PASS
- Notes: прямые table grants для authenticated запрещены; admin actions пишут `admin_audit_log`; student видит только published + audience/schedule; publish требует `content.publish`.

### 12.3 — Shared content renderer package

- Goal: вынести общий renderer в `packages/content_renderer` (сейчас presentation уже частично в `student_ui`).
- Status: TODO
- Related files: `packages/content_renderer/` (план)
- Notes: новый технический вид UI может требовать обновления приложения.

### 12.4 — Subjects management

- Status: TODO

### 12.5 — Teachers management

- Status: TODO

### 12.6 — Students and Excel import

- Status: TODO

### 12.7 — Schedule and assignments

- Status: TODO

### 12.8 — Moderation and sanctions

- Status: TODO

### 12.9 — Notifications and monitoring

- Status: TODO

### 12.10 — Extended visual layout controls

- Status: TODO

## Decision log

### 2026-07-21

- Выбран Flutter Web, а не Python desktop.
- Выбран один репозиторий.
- Выбран отдельный worktree `feature/admin-console`.
- Первым рабочим модулем будут новости.
- Admin Preview должен отображать настоящее приложение 1:1.
- На первом этапе редактируются только новости.

### 2026-07-22

- Stage 12.2 переопределён как real news e2e (таблицы `news_*`, RPC, Storage, Edge Function, Web Admin + mobile cache-first).
- `packages/content_renderer` сдвинут в 12.3; общий story sheet временно в `student_ui`.
- Media: private Supabase Storage bucket + Edge Function signed URLs; без Base64 в БД/Git; без service_role в клиентах.

## Session handoff

- Last completed action: 12.2 DONE — commit `60c1e7e`, remote migration `20260722110804`, Edge `news-media` v1, smoke PASS.
- Current task: pop recovery stash and commit recovery-flow separately.
- Checks already run: local format/analyze/tests; remote RPC smoke + security grant checks; Edge unauth 401.
- Known blockers: none for 12.2.
- Exact next task: `git stash pop stash@{0}` → verify recovery → separate commit → push.
- Uncommitted leftovers: recovery-flow in `stash@{0}` until pop.
- Push status: push after docs/history align commit.
- Remote migration status: `admin_rbac_and_audit` = `20260721202054`; `news_posts_and_admin_rpc` = `20260722110804`.
- Deploy status: Edge `news-media` v1 ACTIVE.
