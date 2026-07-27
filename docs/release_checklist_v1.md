# Release checklist — Student Platform v1 (Android + iPhone)

Дата: 2026-07-27
Ветка: `refactor/chat-tab`

## Перед сборкой (владелец)

1. ~~Remote-миграции~~ **TECHNICALLY DONE** на `gwdanmwluhrcfxbnplwd` (порядок фактически: news archive → 13.2 → 13.3 → 13.4 → 13.5 → 13.6 → organizer admin):
   1. `20260727183823_admin_news_archive_delete.sql`
   2. `20260727184049_stage13_2_group_space.sql`
   3. `20260727184156_stage13_3_teachers_admin.sql`
   4. `20260727184238_stage13_4_subjects_admin.sql`
   5. `20260727184423_stage13_5_students_groups_terms_admin.sql`
   6. `20260727184457_stage13_6_reviews_moderation.sql`
   7. `20260727184511_stage13_2_admin_group_organizer.sql`
2. ~~Security reviews~~ **PASS** (remote assertive); Admin smoke: Студенты → группа → Организаторы пространства.
3. ~~Edge deploy~~ **DONE** (`news-media` v2, `generate-upload-url` v7, `cleanup-chat-files` v4, `dispatch-push-notifications` v4). `teacher-media` deferred.
4. Feature flags: `reviews.text_enabled=false`, `reviews.structured_enabled=true` — confirmed on remote.
5. **REAL XLSX REQUIRED** — реальные Excel (преподаватели/предметы/студенты); fixtures не импортировать в production.
6. **PHYSICAL SMOKE REQUIRED** — Android/iPhone ниже.

## Android

- [ ] Установка / первый запуск
- [ ] Login / logout / смена пароля
- [ ] Новый пользователь / пустые данные
- [ ] Offline / cache-first (Инфо, новости, карточка преподавателя)
- [ ] Push: foreground / background / terminated
- [ ] Чат + файлы + групповое пространство (после remote apply 13.2)
- [ ] Инфо: семестры / предметы / голосование сложности
- [ ] Большой текст / layout smoke
- [ ] Плохая сеть

## iPhone

- [ ] Установка / первый запуск
- [ ] Login / logout / смена пароля
- [ ] Новый пользователь / пустые данные
- [ ] Offline / cache-first
- [ ] Push: foreground / background / terminated
- [ ] Чат + файлы + групповое пространство
- [ ] Инфо: семестры / предметы / голосование сложности
- [ ] Большой текст / layout smoke
- [ ] Плохая сеть

## Admin Web (после remote apply)

- [ ] Новости archive/hard-delete
- [ ] Преподаватели CRUD + dry-run import
- [ ] Предметы CRUD + dry-run import
- [ ] Студенты/группы/подготовка семестра (подтверждение mass actions)
- [ ] Модерация очереди (text reviews выключены флагом)

## Не блокеры v1 (зафиксированные residuals)

- PDF экспорт отложен
- `teacher-media` upload отложен
- Profile screen legacy polling (не чат)
- Local preflight cleared: `scripts/local_preflight_stage13.sh` (baseline + pending migrations + security/role-play)
- Auth.create студентов только CLI/Edge
- Физические устройства обязательны для финального GO
