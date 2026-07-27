# Release checklist — Student Platform v1 (Android + iPhone)

Дата: 2026-07-27
Ветка: `refactor/chat-tab`

## Перед сборкой (владелец)

1. Применить remote-миграции **строго по порядку** (только с явным разрешением):
   1. `20260722121908_admin_news_archive_delete.sql` (+ связанные news archive RPC/queue, если ещё не на remote)
   2. `20260727140000_stage13_2_group_space.sql`
   3. `20260727150000_stage13_3_teachers_admin.sql`
   4. `20260727160000_stage13_4_subjects_admin.sql`
   5. `20260727170000_stage13_5_students_groups_terms_admin.sql`
   6. `20260727180000_stage13_6_reviews_moderation.sql`
   7. `20260727182537_stage13_2_admin_group_organizer.sql`
2. После apply: прогнать security SQL checks из `supabase/checks/stage13_*_security_review.sql` и smoke Admin list screens (Студенты → группа → Организаторы пространства).
3. Задеплоить Edge Functions: `news-media`, `generate-upload-url`, `cleanup-chat-files`, `dispatch-push-notifications` (+ позже `teacher-media` если нужен).
4. Проверить feature flags: `reviews.text_enabled=false`, `reviews.structured_enabled=true` (или продуктовое решение).
5. Подготовить реальные Excel (преподаватели/предметы/студенты) — mapping расширяемый, точный файл не зафиксирован.

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
