# Content Platform — Acceptance Checklist

Status: **ACTIVE**
Updated: **2026-07-30** (Stage 14.1 + Design Z closed with Codex APPROVE_WITH_NOTES; media smoke residual)
Rule: mark `[x]` only with **code + tests + Codex APPROVE** for that item.
Docs-only items: Codex APPROVE on the docs package.
Do **not** merge requirements into vague “готово”.

Legend: `[ ]` open · `[x]` accepted · `[~]` partial · `[blocked]` blocked (see CURRENT_TASK)

---

## A. Process & control system

- [x] `docs/master_roadmap.md` содержит Stages 14–21
- [x] Исторические §14–§16 roadmap помечены как Appendix A–C
- [x] Создан `docs/content_platform/CONTENT_PLATFORM_SPEC.md`
- [x] Создан этот `ACCEPTANCE_CHECKLIST.md` с атомарными пунктами
- [x] Обновлён `docs/agent_coordination/CURRENT_TASK.md`
- [x] Обновлён `AGENTS.md` (Content Platform read/gate rules)
- [x] Создан `.cursor/rules/content-platform.mdc` (`alwaysApply: true`)
- [x] Docs gate отправлен в Codex thread `019fa373-81f2-7962-a8c9-81d86cb62311`
- [x] Docs gate получил Codex **APPROVE**
- [x] Перед каждым code-подэтапом архитектура + схема отправлены в Codex
- [x] После каждого code-подэтапа полный diff + тесты отправлены в Codex
- [x] P0/P1 исправлены до APPROVE подэтапа
- [x] Подэтап не отмечен DONE без Codex APPROVE
- [x] После APPROVE выполнен переход к следующему локальному подэтапу
- [x] В конце цепочки запрошен общий Codex review
- [x] Remote migrations не применялись без владельца
- [x] Edge Functions не деплоились без владельца
- [x] GitHub push не выполнялся без владельца
- [x] Force push не использовался
- [x] Реальные данные не импортировались без владельца
- [x] `service_role` не хранится во Flutter Web / Admin Web
- [x] Существующие данные не удалялись
- [x] Уже применённые миграции не редактировались
- [x] Дублирующий roadmap не создавался

---

## B. Read-only audit evidence

- [x] Evidence-файл аудита создан (дата, локальный HEAD, remote migration tail, проверенные объекты; без секретов/ПДн)
- [x] Изучен news backend
- [x] Изучен news editor (Admin)
- [x] Изучен `packages/student_ui`
- [x] Изучена Главная и «Застрял с заданием?»
- [x] Изучена лента профиля
- [x] Изучены карточка и экран предмета
- [x] Изучен справочный раздел
- [x] Изучены Admin teachers / subjects / students
- [x] Изучен Stage 13.6 reviews / moderation
- [x] Изучены vacancies (если есть / hardcoded)
- [x] Изучены файлы и Storage-паттерны
- [x] Изучен академический импорт и `scripts/import_academic_batch.js`
- [x] Прочитаны реальные таблицы Supabase (read-only)
- [x] Прочитаны RLS / RPC / grants (read-only)
- [x] Зафиксировано: какие таблицы расширяем vs создаём (с обоснованием)
- [x] Новые таблицы не созданы без доказательства, что расширение небезопасно

---

## C. Stage 14 — entities & schema

- [x] Таблица / сущность `content_templates`
- [x] PK/UNIQUE templates = `(key, schema_version)`
- [x] Запрет мутации опубликованной schema; новая версия = новый `schema_version`
- [x] Таблица / сущность `content_items`
- [x] Таблица / сущность `content_item_versions`
- [x] Таблица / сущность `content_item_placements`
- [x] Таблица / сущность `content_item_audience_groups`
- [x] Таблица / сущность `content_item_audience_users`
- [x] Таблица / сущность `content_assets`
- [x] Таблица / сущность `content_media_cleanup_queue`
- [x] Таблица / сущность `content_item_dismissals`
- [x] Таблица / сущность `content_item_events`
- [x] Таблица / сущность `content_audit_log`
- [x] ENABLE RLS на каждой новой таблице
- [x] FORCE RLS на каждой новой таблице
- [x] REVOKE ALL от PUBLIC/anon/authenticated на table DML
- [x] Grants table DML только service_role
- [x] Authenticated только минимальный EXECUTE на RPC

---

## D. Stage 14 — concepts & fields

- [x] Content item
- [x] Approved template
- [x] Placement
- [x] Audience
- [x] Asset
- [x] Version
- [x] Status draft
- [x] Status published
- [x] Status archived
- [x] Publication schedule (`starts_at` / `ends_at`)
- [x] Priority
- [x] Sort order
- [x] Origin `demo`
- [x] Origin `admin`
- [x] Origin `import`
- [x] Origin `user_submission`
- [x] Audit действий
- [x] Impressions (минимальные)
- [x] Clicks (минимальные)

---

## E. Stage 14 — templates & payload validation

- [x] Нет свободного конструктора страниц
- [x] Seed template `home_promo_v1`
- [x] Seed template `profile_feed_card_v1`
- [x] Seed template `reference_article_v1`
- [x] Серверная валидация payload
- [x] Серверная валидация `schema_version`
- [x] Зафиксирован versioned PL/pgSQL validator contract для каждого template
- [x] Runtime validation не зависит от `pg_jsonschema`
- [x] `schema_doc` не используется как runtime schema engine
- [x] Для каждого `(template_key, schema_version)` задан allowlist ключей, типов, лимитов и enum
- [x] Fail-closed на unknown template/schema_version/payload field
- [x] Fail-closed на неверный тип, длину, enum или CTA
- [x] Fail-closed на inactive/unknown template
- [x] Publish path повторно валидирует payload
- [x] Guard trigger/security assertion: referenced `(key, schema_version)` immutable (`schema_doc`, `allowed_placements`, validator semantics)
- [x] Эволюция шаблона только через новый `schema_version`
- [x] Publish: каждый asset id в payload существует
- [x] Publish: каждый asset id принадлежит тому же `content_item_id`
- [x] Publish: каждый asset id проходит MIME/type rule шаблона
- [x] Restore enforce тот же asset invariant

---

## F. Stage 14 — placements

- [x] Placement `home_promo`
- [x] Placement `profile_feed`
- [x] Placement `reference`
- [x] Расширение news targeting без rewrite news backend

---

## G. Stage 14 — audience semantics

- [x] Аудитория all
- [x] Аудитория одна группа
- [x] Аудитория несколько групп
- [x] Аудитория явный набор пользователей
- [x] Режим groups_and_users
- [x] Union + dedupe смешанной аудитории
- [x] Только active users считаются
- [x] Только active enrollment/membership считаются
- [x] Unknown/blocked/transferred исключены
- [x] Один и тот же resolver для preview и mobile visibility
- [x] UUID не хранятся в небезопасном клиентском payload
- [x] Нормализованные junction-таблицы
- [x] Audience вычисляется сервером
- [x] Client audience payload не доверяется для authz
- [x] Publish с пустой targeted-аудиторией запрещён

---

## H. Stage 14 — Admin RPCs (каждый отдельно)

- [x] `admin_list_content_items`
- [x] `admin_get_content_item`
- [x] `admin_create_content_draft`
- [x] `admin_update_content_draft`
- [x] `admin_set_content_placements`
- [x] `admin_set_content_audience`
- [x] `admin_preview_content_audience` (count + safe breakdown, без списка ПДн)
- [x] `admin_publish_content`
- [x] `admin_unpublish_content`
- [x] `admin_archive_content`
- [x] `admin_list_content_versions`
- [x] `admin_restore_content_version`
- [x] `admin_reorder_content_placement`
- [x] `admin_safe_delete_content`
- [x] `content_items.row_version`
- [x] Каждый mutating RPC существующего item принимает expected row_version; create draft — исключение, reorder принимает массив версий
- [x] Version mismatch возвращает conflict без частичной записи
- [x] Успешная мутация увеличивает `row_version`
- [x] Audience replacement транзакционен
- [x] Placement replacement транзакционен
- [x] Restore транзакционен
- [x] Reorder принимает обязательную expected row_version для каждого item
- [x] Reorder отклоняет массивы разной длины и duplicate item IDs
- [x] Reorder проверяет все версии атомарно под deterministic locks
- [x] Conflict откатывает весь reorder без частичного порядка
- [x] Reorder увеличивает row_version каждого затронутого item

---

## I. Stage 14 — version snapshot / restore

- [x] Snapshot включает payload
- [x] Snapshot включает template_key + schema_version
- [x] Snapshot включает schedule
- [x] Snapshot включает placements
- [x] Snapshot включает audience relations
- [x] Snapshot включает priority/order
- [x] Snapshot включает asset refs
- [x] Snapshot включает visibility flags (is_hidden)
- [x] Restore — одна транзакция
- [x] Restore создаёт новую version_number
- [x] Restore не молча пропускает недоступный asset
- [ ] История версий доступна в Admin

---

## J. Stage 14 — mobile RPCs & client behaviour

- [x] `get_my_content_for_placement`
- [x] `dismiss_content_item`
- [x] `record_content_event` (allowlist impression|click)
- [x] Колонка `event_hour` (UTC hour bucket, пишет только RPC)
- [x] UNIQUE `(content_item_id, user_id, event_type, event_hour)`
- [x] Rate-limit / dedupe events через эту UNIQUE / upsert-стратегию
- [x] Event только если item реально видим caller
- [x] Event/audit meta без CTA URL / лишних ПДн
- [ ] Retention policy для events
- [x] Cache-first mobile
- [x] Refresh после app resume
- [x] Pull-to-refresh
- [ ] Нет N+1 (есть evidence: batch/join)
- [x] Нет сырого JSON в UI
- [x] Archived/hidden не выдаётся mobile RPC

---

## K. Stage 14 — assets & storage

- [x] Private Storage bucket
- [x] Typed ownership Stage 14 через FK `content_assets.content_item_id`
- [x] В Stage 14 нет polymorphic `owner_kind`
- [x] Signed upload
- [x] Signed download с authz на каждое чтение
- [x] MIME whitelist
- [x] Size whitelist
- [x] Individual asset deletion forbidden while current item references it
- [x] `admin_safe_delete_content` разрешён только для archived item
- [x] Safe-delete enqueue всех asset paths в `content_media_cleanup_queue` до delete
- [x] Safe-delete может каскадно удалить archived item + version history + assets одной транзакцией
- [x] Cleanup queue + retry
- [x] Нет Base64 в БД

---

## L. Stage 14 — security assertions

- [x] `SECURITY DEFINER` только при необходимости
- [x] `search_path=''`
- [x] `auth.uid()` обязателен
- [x] Membership/RBAC на сервере
- [x] IDOR tests PASS *(local disposable DB Stage 14 roleplay 2026-07-30)*
- [x] SQL security review PASS *(local disposable DB Stage 14/15.2/17/19 reviews 2026-07-30)*
- [x] SQL behavioral role-play + rollback PASS *(local disposable DB Stage 14 roleplay ASSERTED_SCENARIOS PASS 2026-07-30)*
- [x] Secret scan clean
- [x] `git diff --check` clean
- [x] Codex APPROVE Stage 14 foundation

---

## M. Stage 14.1 — Demo governance

- [x] Инвентаризация hardcoded/demo элементов записана
- [x] Демо не удалено до миграции/замены
- [x] `origin=demo`
- [x] Фильтр «Демо» в админке
- [x] Архивирование демо через админку
- [x] Удаление демо через админку
- [x] Замена демо реальным материалом
- [x] Демо не возвращается самопроизвольно после удаления
- [x] Demo fallback не маскирует ошибку сервера
- [x] Demo-вакансии: «Пример» или вне production-аудитории
- [x] Demo-отзывы: «Пример» или вне production-аудитории
- [x] Codex APPROVE 14.1 *(APPROVE_WITH_NOTES; media smoke residual)*

---

## N. Stage 15.1 — Home promo

- [x] «Застрял с заданием?» → managed promo
- [x] Редактируется заголовок
- [x] Редактируется подзаголовок
- [ ] Редактируется изображение/иллюстрация *(отключено до signed-URL/media path; Codex 15.1 APPROVE с этим residual)*
- [x] Редактируется градиент
- [x] Редактируется иконка
- [x] Редактируется CTA
- [x] Редактируется внутренний маршрут
- [x] Редактируется проверенная внешняя ссылка
- [x] Редактируется аудитория
- [x] Редактируется период показа
- [x] Редактируется порядок
- [x] Возможность закрыть карточку
- [x] Политика повторного показа
- [x] Статус draft
- [x] Статус published
- [x] Статус archived
- [x] Origin/status demo
- [x] Renderer в `packages/student_ui`
- [x] Admin Preview = тот же renderer
- [x] Mobile = тот же renderer
- [x] Cache-first + resume/refresh
- [x] Widget/golden tests promo
- [x] Codex APPROVE 15.1

---

## O. Stage 15.2 — News targeting extension

- [x] News backend не переписан с нуля
- [x] Аудитория «все»
- [x] Аудитория несколько групп
- [x] Аудитория явный набор пользователей
- [x] Preview получателей новостей
- [x] Существующие публикации сохранены
- [x] Существующие изображения сохранены
- [x] Обратная совместимость
- [x] Нет утечки скрытых новостей через RPC
- [x] Нет утечки через кеш
- [x] Нет утечки через signed URL
- [x] Codex APPROVE 15.2

---

## P. Stage 15.3 — Profile feed

- [x] Placement `profile_feed`
- [x] Контент для всех
- [x] Контент для групп
- [x] Контент для отдельных пользователей
- [x] Порядок
- [x] Расписание
- [x] Preview аудитории
- [x] Управление из Admin
- [x] Единый дизайн приложения
- [x] Новости не дублируются автоматически
- [x] Админ явно выбирает placement
- [x] Codex APPROVE 15.3

---

## Q. Stage 16 — Subject card editor

- [x] Admin визуальный editor карточки предмета
- [x] Название
- [x] Краткое описание
- [x] Подробное описание
- [x] Чему научится студент
- [x] Форма контроля
- [x] Часы
- [x] Зачётные единицы
- [x] Требования
- [x] Советы по подготовке
- [x] Преподаватели
- [x] Дата актуальности
- [x] Изображения
- [x] Файлы
- [x] Ссылки
- [x] Порядок секций
- [x] Preview мобильной карточки
- [x] Catalog-level данные
- [x] Безопасный offering-level override
- [x] Связь через `subject_id` / `subject_catalog_id` / `subject_offering_id`
- [x] Название не является ключом
- [x] Codex APPROVE 16.1

---

## R. Stage 16 — Subject files

- [x] Private Storage
- [x] Signed upload
- [x] Signed download
- [x] MIME whitelist
- [x] Size whitelist
- [x] Versioning
- [x] Cleanup после безопасного удаления
- [x] Нет Base64 в БД
- [x] Codex APPROVE 16.2

---

## S. Stage 16 — Reference

- [x] Полностью управляемый справочник
- [x] Категории
- [x] Иконка
- [x] Заголовок
- [x] Короткий текст
- [x] Полный материал
- [x] Изображения
- [x] Файлы
- [x] Ссылки
- [x] CTA
- [x] Порядок
- [x] Аудитория
- [x] Draft
- [x] Publish
- [x] Archive
- [x] Admin Preview
- [x] Mobile cache-first renderer
- [x] «Сообщить об ошибке»
- [x] Произвольный HTML запрещён
- [x] Произвольный JS запрещён
- [x] Codex APPROVE 16.3

---

## T. Stage 17 — Vacancies

- [x] Отдельная доменная модель (не generic content JSON SoT)
- [x] Админ создаёт вакансию
- [x] Пользователь предлагает через форму
- [x] User submission не публикуется сразу
- [x] Поле название
- [x] Поле организация
- [x] Поле описание
- [x] Поле формат занятости
- [x] Поле местоположение/удалённо
- [x] Поле зарплата (optional)
- [x] Поле требования
- [x] Поле контакты
- [x] Поле ссылка
- [x] Поле срок актуальности
- [x] Поле аудитория
- [x] Поле изображения/файлы
- [x] Поле автор заявки
- [x] Поле источник
- [x] Поле дата проверки
- [x] Статус draft
- [x] Статус submitted
- [x] Статус moderation / in_moderation
- [x] Статус approved/published
- [x] Статус expired
- [x] Статус archived
- [x] Статус rejected
- [x] Предпросмотр
- [x] Срок окончания в выдаче
- [x] Жалоба
- [x] Защита контактов
- [x] Проверка ссылок
- [x] Причина отклонения
- [x] Журнал модерации
- [x] Mobile-карточка
- [x] Admin-карточка
- [x] Demo-вакансии отдельно / не вводят в заблуждение
- [x] Codex APPROVE 17

---

## U. Stage 18 — Reviews (extend 13.6)

- [x] Вторая система отзывов не создана
- [x] Расширен Stage 13.6
- [x] Отзывы на преподавателя
- [x] Отзывы на предмет
- [x] Вакансия/работодатель только после отдельного продуктового решения
- [x] Структурированные оценки/теги
- [x] Короткий текст
- [x] Анонимность для студентов
- [x] Автор виден модерации
- [x] Жалоба
- [x] Редактирование до начала модерации
- [x] Один отзыв на разрешённый контекст
- [x] Блок ПДн
- [x] Блок оскорблений
- [x] Блок обвинений
- [x] Публикация только после модерации
- [x] Нельзя модерировать свой отзыв
- [x] Rate limit
- [x] Антиспам
- [x] Codex APPROVE 18 reviews

---

## V. Stage 18 — Points ledger

- [x] +1 балл за один одобренный отзыв
- [x] Начисление только после одобрения
- [x] Идемпотентность
- [x] Повторная отправка ≠ второй балл
- [x] Редактирование ≠ второй балл
- [x] Уникальная ledger-запись по `review_id`
- [x] Compensating запись при удалении за нарушение
- [x] История баллов для студента
- [x] Баллы не деньги
- [x] Баллы не выводятся
- [x] Codex APPROVE 18 points

---

## W. Stage 18 — Unified moderation Admin

- [x] Раздел «Модерация»
- [x] Очередь отзывов
- [x] Очередь вакансий
- [x] Очередь жалоб
- [x] Очередь исправлений контента
- [x] Фильтр тип
- [x] Фильтр статус
- [x] Фильтр дата
- [x] Фильтр автор
- [x] Фильтр приоритет
- [x] Фильтр назначенный модератор
- [x] Принять
- [x] Отклонить с причиной
- [x] Запросить уточнение
- [x] Скрыть
- [x] Восстановить
- [x] Открыть историю
- [x] Audit log всех действий
- [x] Codex APPROVE 18 moderation

---

## X. Stage 19 — Import Studio domains

- [x] Единый Admin Import Studio hub
- [x] Отдельные валидаторы доменов
- [x] Домен преподаватели: template
- [x] Домен преподаватели: mapping
- [x] Домен преподаватели: validator
- [x] Домен преподаватели: dry-run
- [x] Домен преподаватели: diff
- [x] Домен преподаватели: apply
- [x] Домен преподаватели: idempotent replay
- [x] Домен преподаватели: safe rollback (где возможно)
- [x] Домен предметы: template
- [x] Домен предметы: mapping
- [x] Домен предметы: validator
- [x] Домен предметы: dry-run
- [x] Домен предметы: diff
- [x] Домен предметы: apply
- [x] Домен предметы: idempotent replay
- [x] Домен предметы: safe rollback (где возможно)
- [x] Домен студенты: template
- [x] Домен студенты: mapping
- [x] Домен студенты: validator
- [x] Домен студенты: dry-run
- [x] Домен студенты: diff
- [x] Домен студенты: apply
- [x] Домен студенты: idempotent replay
- [x] Домен студенты: safe rollback (где возможно)
- [x] Домен группы: template
- [x] Домен группы: mapping
- [x] Домен группы: validator
- [x] Домен группы: dry-run
- [x] Домен группы: diff
- [x] Домен группы: apply
- [x] Домен группы: idempotent replay
- [x] Домен группы: safe rollback (где возможно)
- [x] Домен семестры: template
- [x] Домен семестры: mapping
- [x] Домен семестры: validator
- [x] Домен семестры: dry-run
- [x] Домен семестры: diff
- [x] Домен семестры: apply
- [x] Домен семестры: idempotent replay
- [x] Домен семестры: safe rollback (где возможно)
- [x] Домен учебные планы групп: template
- [x] Домен учебные планы групп: mapping
- [x] Домен учебные планы групп: validator
- [x] Домен учебные планы групп: dry-run
- [x] Домен учебные планы групп: diff
- [x] Домен учебные планы групп: apply
- [x] Домен учебные планы групп: idempotent replay
- [x] Домен учебные планы групп: safe rollback (где возможно)
- [x] Домен offering: template
- [x] Домен offering: mapping
- [x] Домен offering: validator
- [x] Домен offering: dry-run
- [x] Домен offering: diff
- [x] Домен offering: apply
- [x] Домен offering: idempotent replay
- [x] Домен offering: safe rollback (где возможно)
- [x] Домен связи преподавателей: template
- [x] Домен связи преподавателей: mapping
- [x] Домен связи преподавателей: validator
- [x] Домен связи преподавателей: dry-run
- [x] Домен связи преподавателей: diff
- [x] Домен связи преподавателей: apply
- [x] Домен связи преподавателей: idempotent replay
- [x] Домен связи преподавателей: safe rollback (где возможно)
- [x] Домен enrollment: template
- [x] Домен enrollment: mapping
- [x] Домен enrollment: validator
- [x] Домен enrollment: dry-run
- [x] Домен enrollment: diff
- [x] Домен enrollment: apply
- [x] Домен enrollment: idempotent replay
- [x] Домен enrollment: safe rollback (где возможно)

---

## Y. Stage 19 — Import Studio UX / safety (cross-domain)

- [x] Кнопка «Скачать шаблон Excel»
- [x] Визуальный предпросмотр таблицы в админке
- [x] Названия обязательных колонок
- [x] Названия необязательных колонок
- [x] Примеры заполнения
- [x] Ошибки обычным языком
- [x] Загрузка XLSX
- [x] Определение листов
- [x] Mapping колонок
- [x] Таблица валидных строк
- [x] Таблица ошибочных строк
- [x] Diff до apply
- [x] Warning о создаваемых предметах
- [x] Warning о создаваемых командах/чатах
- [x] Apply только после подтверждения
- [x] Audit / import batch id
- [x] Цепочка: academic term
- [x] Цепочка: group
- [x] Цепочка: subject_catalog
- [x] Цепочка: curriculum
- [x] Цепочка: subject_offering
- [x] Цепочка: offering_teachers
- [x] Цепочка: enrollment
- [x] Цепочка: team/chat creation
- [x] Нет связывания по названию при наличии ID
- [x] Текущий семестр не переключается автоматически
- [x] Осень 2026 не создаётся без владельца
- [x] Web Admin без service_role
- [x] Привилегии только RPC/Edge + RBAC
- [x] Codex APPROVE 19 foundation (минимум template+dry-run для выбранных доменов) и отдельные APPROVE на расширение доменов

---

## Z. Design contract

- [ ] Тот же визуальный язык, что у mobile Student Platform
- [x] Общий renderer Mobile ↔ Admin Preview
- [x] Утверждённые шаблоны вместо свободного конструктора
- [ ] Нет сырых enum в UI
- [ ] Нет сырых UUID в UI
- [x] Нет сырого JSON в UI
- [ ] Нет developer labels в UI
- [x] Понятные тексты на русском
- [ ] Современная типографика
- [ ] Единые радиусы
- [ ] Единые отступы
- [ ] Правильный SafeArea
- [ ] Клавиатура не перекрывает действия
- [ ] Tap outside закрывает клавиатуру
- [ ] Drag закрывает клавиатуру (где применимо)
- [ ] Done закрывает клавиатуру
- [x] Loading state
- [x] Error state
- [x] Empty state
- [ ] Success state
- [ ] Cache-first без мерцания
- [ ] Изображения без скачков размеров
- [ ] Маленькие телефоны
- [ ] Крупные телефоны
- [ ] Web 1280
- [ ] Web 1440
- [ ] Web 1920
- [ ] Accessibility labels
- [ ] Текстовый масштаб
- [ ] Reduce motion
- [ ] Лицензии изображений/Lottie
- [~] Widget/golden tests критичных шаблонов *(widget yes; golden files absent)*
- [ ] Дизайн не выглядит как техническая форма
- [ ] Дизайн не отличается от основного приложения

---

## AA. Stage 20 — AI (spec only)

- [x] `docs/content_platform/AI_ASSISTANTS_SPEC.md` создан
- [x] Вариант: определение колонок неизвестного Excel
- [x] Вариант: сопоставление преподавателей/предметов и дубли
- [x] Вариант: очистка OCR
- [x] Вариант: черновик карточки предмета из файла
- [x] Вариант: черновик новости/promo
- [x] Вариант: классификация вакансии
- [x] Вариант: предварительная проверка отзывов
- [x] Вариант: поиск ПДн и оскорблений
- [x] Вариант: объяснение ошибок импорта
- [x] Вариант: помощник администратора по контенту
- [x] AI только черновик
- [x] Публикация только человеком
- [x] Нет скрытых автодействий
- [x] Минимизация ПДн
- [x] Журнал источников
- [x] Лимиты стоимости
- [x] Полный opt-out AI
- [x] Платный AI не внедрён автоматически
- [x] Codex APPROVE Stage 20 docs

---

## AB. Stage 21 — RU infra (roadmap only)

- [x] `docs/content_platform/RF_INFRA_MIGRATION_ROADMAP.md` создан
- [x] Российский VPS
- [x] PostgreSQL
- [x] Auth
- [x] Storage
- [x] Realtime
- [x] Edge/worker/cron
- [x] Резервные копии
- [x] Мониторинг
- [x] Домен/TLS
- [x] Миграционная репетиция
- [x] Проверка целостности
- [x] Rollback
- [x] Временный read-only/cutover
- [x] Обновление Flutter конфигурации
- [x] Caveat: снижение зависимости от Supabase
- [x] Caveat: FCM/APNs остаются внешними
- [x] Caveat: VPN-independence без физического теста не обещается
- [x] Перенос сейчас не выполнялся
- [x] Codex APPROVE Stage 21 docs

---

## AC. Per-code-slice engineering checks

> Копировать в CURRENT_TASK при закрытии каждого code-подэтапа.

- [ ] `dart format` затронутых файлов
- [ ] Focused `dart analyze` clean
- [ ] Flutter focused tests PASS
- [ ] Admin tests PASS (если Admin затронут)
- [ ] Shared renderer tests PASS (если шаблоны затронуты)
- [ ] SQL security review PASS (если SQL)
- [ ] SQL behavioral role-play + rollback PASS (если SQL)
- [ ] RLS/FORCE/grants assertions записаны
- [ ] Migration preflight local Supabase PASS (если миграции)
- [ ] Deno check изменённых Edge PASS (если Edge)
- [ ] Android debug build PASS (если mobile)
- [ ] iOS simulator build PASS (если mobile)
- [ ] Admin Web build PASS (если Admin)
- [ ] Main Web build PASS (если main web)
- [ ] Cache/error/empty tests PASS (если UI выдача)
- [ ] No-N+1 evidence записан (если списки)
- [ ] `git diff --check` clean
- [ ] Secret scan clean
- [ ] Codex APPROVE slice

---

## AD. Final stop

- [x] Все технически возможные локальные подэтапы выполнены или заблокированы в CURRENT_TASK *(14.1/Z: media smoke JWT residual)*
- [x] Каждый завершённый подэтап имеет Codex APPROVE
- [x] Roadmap обновлён
- [x] CURRENT_TASK обновлён
- [x] Checklist отражает факт
- [x] Migrations подготовлены, remote не применены
- [x] Remote данные не изменены
- [x] Push не выполнен
- [x] Git tree clean или status объяснён
- [x] Финальный отчёт владельцу (14 разделов brief) *(see STAGE_14_21_ACCEPTANCE_AUDIT.md + this closeout)*
