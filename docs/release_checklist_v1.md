# Release checklist — Student Platform v1 (Android + iPhone)

Дата: 2026-07-28
Ветка: `refactor/chat-tab`

## Перед сборкой (владелец)

1. ~~Remote-миграции~~ **TECHNICALLY DONE** на `gwdanmwluhrcfxbnplwd` (через 13.9 + hotfix):
   1. `20260727183823_admin_news_archive_delete.sql`
   2. `20260727184049_stage13_2_group_space.sql`
   3. `20260727184156_stage13_3_teachers_admin.sql`
   4. `20260727184238_stage13_4_subjects_admin.sql`
   5. `20260727184423_stage13_5_students_groups_terms_admin.sql`
   6. `20260727184457_stage13_6_reviews_moderation.sql`
   7. `20260727184511_stage13_2_admin_group_organizer.sql`
   8. `20260727234755_stage13_8_safe_academic_terms.sql`
   9. `20260727235000_stage13_9_chat_topics_collections.sql`
   10. `20260727235317_stage13_9_group_action_notifications.sql`
   11. `20260727235707_stage13_9_fix_card_msg_type.sql`
2. ~~Security reviews~~ **PASS** (remote assertive 13.8/13.9 + notifications after hotfix).
3. ~~Edge deploy~~ **DONE** (`news-media` v2, `generate-upload-url` v7, `cleanup-chat-files` v4, `dispatch-push-notifications` **v5**). `teacher-media` deferred.
4. Feature flags: `reviews.text_enabled=false`, `reviews.structured_enabled=true` — confirmed on remote.
5. **REAL XLSX REQUIRED** — реальные Excel (преподаватели/предметы/студенты); fixtures не импортировать в production.
6. **PHYSICAL SMOKE REQUIRED** — OCR + two-device topic race + controlled push; Android/iPhone ниже.

## Android

- [ ] Установка / первый запуск
- [ ] Login / logout / смена пароля
- [ ] Новый пользователь / пустые данные
- [ ] Offline / cache-first (Инфо, новости, карточка преподавателя)
- [ ] Push: foreground / background / terminated
- [ ] Чат + файлы + чат группы / выбор темы / сбор (OCR + race pick)
- [ ] Controlled push: group action notification → deep-link highlight
- [ ] Инфо: семестры / предметы / голосование сложности
- [ ] Большой текст / layout smoke
- [ ] Плохая сеть

## iPhone

- [ ] Установка / первый запуск
- [ ] Login / logout / смена пароля
- [ ] Новый пользователь / пустые данные
- [ ] Offline / cache-first
- [ ] Push: foreground / background / terminated
- [ ] Чат + файлы + чат группы / выбор темы / сбор (OCR + race pick)
- [ ] Controlled push: group action notification → deep-link highlight
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
