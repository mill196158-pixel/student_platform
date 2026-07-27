# Release checklist — Student Platform v1 (Android + iPhone)

Дата: 2026-07-27  
Ветка: `refactor/chat-tab`

## Перед сборкой (владелец)

1. Применить remote-миграции по порядку (см. итоговый отчёт Stage 13).
2. Задеплоить Edge Functions: `news-media`, `generate-upload-url`, `cleanup-chat-files`, `dispatch-push-notifications` (+ позже `teacher-media` если нужен).
3. Проверить feature flags: `reviews.text_enabled=false`, `reviews.structured_enabled=true` (или продуктовое решение).
4. Подготовить реальные Excel (преподаватели/предметы/студенты) — mapping расширяемый, точный файл не зафиксирован.

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
- UNKNOWN_DB_LOCAL_VALIDATION без полного local stack
- Auth.create студентов только CLI/Edge
- Физические устройства обязательны для финального GO
