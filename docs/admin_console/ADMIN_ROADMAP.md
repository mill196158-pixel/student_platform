# Student Platform Admin — Master Roadmap

> Единый источник правды по Web Admin для Cursor, Codex и разработчика. Читать перед началом каждого нового чата и обновлять после каждого материального изменения.

## Current state

- Last updated: 2026-07-21
- Current branch: `feature/admin-console`
- Current worktree: `/Users/annasuvorova/student_platform_admin`
- Base commit: `89f0890`
- Current stage: 12.1 — Security and RBAC
- Current status: REVIEW
- Next action: review локальной миграции `20260721184328_admin_rbac_and_audit.sql` и auth-каркаса Admin; не применять к remote без разрешения.
- Blockers: remote apply/deploy запрещены до отдельного разрешения; первый `super_admin` назначается только bootstrap-инструкцией после review.

Допустимые статусы: TODO, IN PROGRESS, REVIEW, DONE, BLOCKED. Одновременно только один этап может иметь статус IN PROGRESS.

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
- Будущий `packages/content_renderer` используется приложением и админкой.
- Визуальный компонент новости пишется один раз.
- Изменение контента не требует выпуска новой версии приложения.
- Новый технический вид UI может требовать обновления приложения.
- Firebase Hosting используется для размещения сайта.
- Supabase Auth/RBAC используется для входа и прав.
- `service_role` запрещён в браузере.
- Код должен работать на macOS и Windows.
- Абсолютные локальные пути запрещены в исходном коде.

## Current project facts

- Текущие новости главной пока находятся в `lib/src/ui/home/home_dashboard_service.dart` в методе `_localNews()`.
- В проекте уже есть визуальные home widgets.
- Существуют `subject_catalog`.
- Существуют `subject_offerings`.
- Существуют `subject_student_profiles`.
- Существуют `subject_offering_student_profiles`.
- Существуют `teachers`.
- Существуют `offering_teachers`.
- Преподаватели пока практически не заполнены.
- Существует `scripts/import_academic_batch.js`.
- Push-инфраструктура уже реализована.
- Firebase настроен.
- Admin worktree создан от commit `89f0890`.

## Security debt

- Часть академических таблиц сейчас без RLS.
- `anon`/`authenticated` имеют избыточные grants.
- `users` UPDATE policy потенциально позволяет менять опасные поля.
- `is_admin()` не должен доверять редактируемому `users.role`.
- Реальное подключение Web Admin запрещено до этапа RBAC/RLS.
- RLS нельзя включать механически без проверки текущих Flutter-запросов.
- На этапе 12.0 Supabase вообще не подключается.

## News requirements

Четыре варианта карточек:

- `gradientText`;
- `imageOverlay`;
- `imageOnly`;
- `imageWithText`.

В будущей рабочей версии нужны:

- маленькое изображение карточки;
- большое изображение новости;
- заголовок;
- подзаголовок;
- основной текст;
- положение текста;
- светлый/тёмный текст;
- затемнение;
- точка фокуса;
- порядок;
- аудитория;
- дата публикации;
- дата окончания;
- push по желанию;
- черновик;
- предпросмотр;
- публикация;
- архив;
- восстановление;
- версии.

## Subjects requirements

Разделять:

- `subject_catalog` — общий предмет;
- `subject_student_profiles` — общая информация студентам;
- `subject_offerings` — предмет группы и семестра;
- `subject_offering_student_profiles` — локальные особенности.

Редактируемая информация:

- название;
- короткое описание;
- чего ожидать;
- как сдать;
- материалы;
- частые ошибки;
- советы;
- особенности конкретного семестра и преподавателя;
- статус публикации.

## Teachers requirements

Предусмотреть:

- таблицу;
- ФИО;
- фотографию;
- кафедру;
- должность;
- контакты;
- описание;
- предметы;
- группы;
- семестры;
- статус;
- архив;
- историю изменений.

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
- Не отмечать этап DONE до пользовательского ревью.

## Roadmap

### 12.0 — Web Admin foundation

- Goal: создать автономный desktop-first Flutter Web каркас и локальные UX-прототипы ключевых разделов без подключения к Supabase.
- Deliverables: Flutter Web проект; структура; маршруты; desktop shell; mock visual news editor; mock subjects table; mock teachers table; документация; Web build.
- Acceptance criteria: маршруты открываются; shell адаптируется к узкой ширине; mock-редактор новостей поддерживает заявленные локальные действия; таблицы поддерживают поиск и фильтр; targeted-проверки и Web build проходят; пользователь провёл визуальное ревью.
- Status: REVIEW
- Related files: `admin_console/`, `packages/student_ui/`, `lib/src/ui/home/home_screen.dart`, `lib/src/ui/navigation/navigation_screen.dart`, `docs/admin_console/ADMIN_ROADMAP.md`, `scripts/run_admin_web.sh`, `scripts/run_admin_web.ps1`
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: Flutter Web проект, маршруты, адаптивный AdminShell, полноценный локальный визуальный редактор новостей (четыре варианта карточек, локальная загрузка изображений, focal point, затемнение, draft-баннер), mock-таблицы предметов/преподавателей, общий `packages/student_ui`, точный прокручиваемый Home Preview с height-scaled phone frame, PWA manifest, локальные launch-скрипты, тесты и Web build созданы. Мобильный `HomeScreen` продолжает загружать реальные данные через неизменённый `HomeDashboardService` и передаёт готовую presentation-модель общему `StudentHomeView`. Admin Preview передаёт только безопасные mock-данные; редактируемы только новости. Интерфейсы `NewsRepository`/`AdminImageStore`/`AdminImagePicker` готовы к будущей замене на Supabase Auth/RBAC/Storage. Supabase не подключается. Этап не переводится в DONE до пользовательского ревью.

### 12.1 — Security and RBAC

- Goal: подготовить безопасный административный доступ до подключения реальных данных.
- Deliverables: аудит `users` grants/RLS; локальная миграция admin RBAC/scopes/audit; RPC capabilities; hardening опасных колонок профиля; Admin Auth каркас; bootstrap-инструкция; focused tests.
- Acceptance criteria: студенту недоступны admin RPC; права только через server assignments; Web Admin без service_role; локальный прототип работает без dart-define; миграция не применена к remote.
- Status: REVIEW
- Related files: `supabase/migrations/20260721184328_admin_rbac_and_audit.sql`, `supabase/checks/admin_rbac_security_review.sql`, `docs/admin_console/ADMIN_RBAC_BOOTSTRAP.md`, `admin_console/lib/core/auth/`
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: live audit confirmed `authenticated`/`anon` could UPDATE `users.role` and other privileged columns; migration revokes those column privileges and adds RPC-only admin access. Do not apply until explicit approval.

### 12.2 — Shared content renderer

- Goal: обеспечить одинаковое отображение поддерживаемого контента в приложении и админке.
- Deliverables: `packages/content_renderer`; общие модели; общий `NewsCard`; общий полноэкранный просмотр; одинаковое отображение в app/admin.
- Acceptance criteria: будут определены перед началом этапа.
- Status: TODO
- Related files: `packages/content_renderer/` (план)
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: новый технический вид UI может требовать обновления приложения.

### 12.3 — News backend and visual editor

- Goal: подключить безопасный жизненный цикл новостей к визуальному редактору.
- Deliverables: `content_posts`; versions; audiences; media; drafts; publish; archive; scheduling; upload; push; cache-first лента приложения.
- Acceptance criteria: будут определены после завершения этапов 12.1 и 12.2.
- Status: TODO
- Related files: будут определены
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: все записи только через разрешённые RPC или Edge Functions.

### 12.4 — Subjects management

- Goal: управлять общими и локальными данными предметов без раскрытия технической модели.
- Deliverables: формы и таблицы для `subject_catalog`, `subject_student_profiles`, `subject_offerings`, `subject_offering_student_profiles`.
- Acceptance criteria: будут определены перед началом этапа.
- Status: TODO
- Related files: будут определены
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: имя предмета не является техническим ключом.

### 12.5 — Teachers management

- Goal: управлять преподавателями и их связями с предметами.
- Deliverables: таблица, профиль, фотография, кафедра, должность, контакты, описание, связи с предметами/группами/семестрами, статус, архив, история.
- Acceptance criteria: будут определены перед началом этапа.
- Status: TODO
- Related files: будут определены
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: использовать существующие `teachers` и `offering_teachers`.

### 12.6 — Students and Excel import

- Goal: безопасно управлять студентами и массовым импортом.
- Deliverables: список студентов; формы; проверки; массовые операции; Excel-импорт.
- Acceptance criteria: будут определены перед началом этапа.
- Status: TODO
- Related files: будут определены
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: учитывать существующий `scripts/import_academic_batch.js` и staging-first процесс.

### 12.7 — Schedule and assignments

- Goal: управлять расписанием и заданиями через разрешённые операции.
- Deliverables: таблицы, фильтры, формы и массовые действия для расписания и заданий.
- Acceptance criteria: будут определены перед началом этапа.
- Status: TODO
- Related files: будут определены
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: связи предметов должны использовать `subject_offering_id`.

### 12.8 — Moderation and sanctions

- Goal: дать модераторам понятный и аудируемый рабочий процесс.
- Deliverables: очереди модерации, решения, санкции, история действий.
- Acceptance criteria: будут определены перед началом этапа.
- Status: TODO
- Related files: будут определены
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: опасные операции требуют capabilities и audit log.

### 12.9 — Notifications and monitoring

- Goal: управлять уведомлениями и видеть состояние административных процессов.
- Deliverables: уведомления, статусы доставки, мониторинг и понятные ошибки.
- Acceptance criteria: будут определены перед началом этапа.
- Status: TODO
- Related files: будут определены
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: внутренние ошибки базы не показываются пользователю.

### 12.10 — Extended visual layout controls

- Goal: расширить визуальные настройки в пределах разрешённых компонентов.
- Deliverables: дополнительные layout-контролы, предпросмотр, версии и безопасные ограничения.
- Acceptance criteria: будут определены перед началом этапа.
- Status: TODO
- Related files: будут определены
- Commit SHA: отсутствует
- Remote applied/deployed: нет
- Notes: админка не становится произвольным редактором базы или UI.

## Decision log

### 2026-07-21

- Выбран Flutter Web, а не Python desktop.
- Выбран один репозиторий.
- Выбран отдельный worktree `feature/admin-console`.
- Мобильное приложение разрабатывается параллельно.
- Часть модулей визуальная.
- Большие справочники табличные.
- Первым рабочим модулем будут новости.
- Затем предметы и преподаватели.
- Admin Preview должен отображать настоящее приложение 1:1.
- Независимая копия мобильного дизайна не создаётся.
- Мобильное приложение и Admin Preview используют общие presentation widgets.
- В preview редактируются только явно разрешённые области.
- На первом этапе редактируются только новости.
- Системные блоки отображаются, прокручиваются, но не изменяются.

## Session handoff

- Last completed action: этап 12.1 — local runtime role-play **23/23 PASS** on local Supabase; migration `20260721184328` applied only locally.
- Current task: review + decision о remote apply; затем bootstrap первого `super_admin` по `ADMIN_RBAC_BOOTSTRAP.md`.
- Files being changed: `supabase/migrations/20260721184328_admin_rbac_and_audit.sql`, `supabase/checks/admin_rbac_*`, `admin_console/lib/core/auth/*`, router/shell, mobile `change_password_screen.dart`, docs.
- Checks already run: local role-play B/C — 23/23 PASS; `git diff --check` — clean; remote not touched.
- Known blockers: remote apply / Edge deploy / commit / push запрещены до явного разрешения.
- Exact next task: после approval — remote apply migration, bootstrap super_admin, затем 12.2/12.3 content renderer.
- Uncommitted changes: stage 12.1 files listed in git status; commit отсутствует.
- Last commit: `4a17b82`
- Push status: branch tracking exists from 12.0; 12.1 not pushed.
- Remote migration status: `20260609093000_*` / `20260609133500_*` / `20260721184328_*` — не применены.
- Deploy status: не выполнялся.
