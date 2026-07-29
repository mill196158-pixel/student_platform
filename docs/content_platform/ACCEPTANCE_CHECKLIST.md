# Content Platform — Acceptance Checklist

Status: **ACTIVE**
Updated: **2026-07-29** (restored atomic after Codex CHANGES_REQUESTED)
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
- [ ] Перед каждым code-подэтапом архитектура + схема отправлены в Codex
- [ ] После каждого code-подэтапа полный diff + тесты отправлены в Codex
- [ ] P0/P1 исправлены до APPROVE подэтапа
- [ ] Подэтап не отмечен DONE без Codex APPROVE
- [ ] После APPROVE выполнен переход к следующему локальному подэтапу
- [ ] В конце цепочки запрошен общий Codex review
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
- [ ] Изучен news backend
- [ ] Изучен news editor (Admin)
- [ ] Изучен `packages/student_ui`
- [ ] Изучена Главная и «Застрял с заданием?»
- [ ] Изучена лента профиля
- [ ] Изучены карточка и экран предмета
- [ ] Изучен справочный раздел
- [ ] Изучены Admin teachers / subjects / students
- [ ] Изучен Stage 13.6 reviews / moderation
- [ ] Изучены vacancies (если есть / hardcoded)
- [ ] Изучены файлы и Storage-паттерны
- [ ] Изучен академический импорт и `scripts/import_academic_batch.js`
- [ ] Прочитаны реальные таблицы Supabase (read-only)
- [ ] Прочитаны RLS / RPC / grants (read-only)
- [ ] Зафиксировано: какие таблицы расширяем vs создаём (с обоснованием)
- [ ] Новые таблицы не созданы без доказательства, что расширение небезопасно

---

## C. Stage 14 — entities & schema

- [ ] Таблица / сущность `content_templates`
- [ ] PK/UNIQUE templates = `(key, schema_version)`
- [ ] Запрет мутации опубликованной schema; новая версия = новый `schema_version`
- [ ] Таблица / сущность `content_items`
- [ ] Таблица / сущность `content_item_versions`
- [ ] Таблица / сущность `content_item_placements`
- [ ] Таблица / сущность `content_item_audience_groups`
- [ ] Таблица / сущность `content_item_audience_users`
- [ ] Таблица / сущность `content_assets`
- [ ] Таблица / сущность `content_media_cleanup_queue`
- [ ] Таблица / сущность `content_item_dismissals`
- [ ] Таблица / сущность `content_item_events`
- [ ] Таблица / сущность `content_audit_log`
- [ ] ENABLE RLS на каждой новой таблице
- [ ] FORCE RLS на каждой новой таблице
- [ ] REVOKE ALL от PUBLIC/anon/authenticated на table DML
- [ ] Grants table DML только service_role
- [ ] Authenticated только минимальный EXECUTE на RPC

---

## D. Stage 14 — concepts & fields

- [ ] Content item
- [ ] Approved template
- [ ] Placement
- [ ] Audience
- [ ] Asset
- [ ] Version
- [ ] Status draft
- [ ] Status published
- [ ] Status archived
- [ ] Publication schedule (`starts_at` / `ends_at`)
- [ ] Priority
- [ ] Sort order
- [ ] Origin `demo`
- [ ] Origin `admin`
- [ ] Origin `import`
- [ ] Origin `user_submission`
- [ ] Audit действий
- [ ] Impressions (минимальные)
- [ ] Clicks (минимальные)

---

## E. Stage 14 — templates & payload validation

- [ ] Нет свободного конструктора страниц
- [ ] Seed template `home_promo_v1`
- [ ] Seed template `profile_feed_card_v1`
- [ ] Seed template `reference_article_v1`
- [ ] Серверная валидация payload
- [ ] Серверная валидация `schema_version`
- [ ] Зафиксирован versioned PL/pgSQL validator contract для каждого template
- [ ] Runtime validation не зависит от `pg_jsonschema`
- [ ] `schema_doc` не используется как runtime schema engine
- [ ] Для каждого `(template_key, schema_version)` задан allowlist ключей, типов, лимитов и enum
- [ ] Fail-closed на unknown template/schema_version/payload field
- [ ] Fail-closed на неверный тип, длину, enum или CTA
- [ ] Fail-closed на inactive/unknown template
- [ ] Publish path повторно валидирует payload
- [ ] Guard trigger/security assertion: referenced `(key, schema_version)` immutable (`schema_doc`, `allowed_placements`, validator semantics)
- [ ] Эволюция шаблона только через новый `schema_version`
- [ ] Publish: каждый asset id в payload существует
- [ ] Publish: каждый asset id принадлежит тому же `content_item_id`
- [ ] Publish: каждый asset id проходит MIME/type rule шаблона
- [ ] Restore enforce тот же asset invariant

---

## F. Stage 14 — placements

- [ ] Placement `home_promo`
- [ ] Placement `profile_feed`
- [ ] Placement `reference`
- [ ] Расширение news targeting без rewrite news backend

---

## G. Stage 14 — audience semantics

- [ ] Аудитория all
- [ ] Аудитория одна группа
- [ ] Аудитория несколько групп
- [ ] Аудитория явный набор пользователей
- [ ] Режим groups_and_users
- [ ] Union + dedupe смешанной аудитории
- [ ] Только active users считаются
- [ ] Только active enrollment/membership считаются
- [ ] Unknown/blocked/transferred исключены
- [ ] Один и тот же resolver для preview и mobile visibility
- [ ] UUID не хранятся в небезопасном клиентском payload
- [ ] Нормализованные junction-таблицы
- [ ] Audience вычисляется сервером
- [ ] Client audience payload не доверяется для authz
- [ ] Publish с пустой targeted-аудиторией запрещён

---

## H. Stage 14 — Admin RPCs (каждый отдельно)

- [ ] `admin_list_content_items`
- [ ] `admin_get_content_item`
- [ ] `admin_create_content_draft`
- [ ] `admin_update_content_draft`
- [ ] `admin_set_content_placements`
- [ ] `admin_set_content_audience`
- [ ] `admin_preview_content_audience` (count + safe breakdown, без списка ПДн)
- [ ] `admin_publish_content`
- [ ] `admin_unpublish_content`
- [ ] `admin_archive_content`
- [ ] `admin_list_content_versions`
- [ ] `admin_restore_content_version`
- [ ] `admin_reorder_content_placement`
- [ ] `admin_safe_delete_content`
- [ ] `content_items.row_version`
- [ ] Каждый mutating RPC существующего item принимает expected row_version; create draft — исключение, reorder принимает массив версий
- [ ] Version mismatch возвращает conflict без частичной записи
- [ ] Успешная мутация увеличивает `row_version`
- [ ] Audience replacement транзакционен
- [ ] Placement replacement транзакционен
- [ ] Restore транзакционен
- [ ] Reorder принимает обязательную expected row_version для каждого item
- [ ] Reorder отклоняет массивы разной длины и duplicate item IDs
- [ ] Reorder проверяет все версии атомарно под deterministic locks
- [ ] Conflict откатывает весь reorder без частичного порядка
- [ ] Reorder увеличивает row_version каждого затронутого item

---

## I. Stage 14 — version snapshot / restore

- [ ] Snapshot включает payload
- [ ] Snapshot включает template_key + schema_version
- [ ] Snapshot включает schedule
- [ ] Snapshot включает placements
- [ ] Snapshot включает audience relations
- [ ] Snapshot включает priority/order
- [ ] Snapshot включает asset refs
- [ ] Snapshot включает visibility flags (is_hidden)
- [ ] Restore — одна транзакция
- [ ] Restore создаёт новую version_number
- [ ] Restore не молча пропускает недоступный asset
- [ ] История версий доступна в Admin

---

## J. Stage 14 — mobile RPCs & client behaviour

- [ ] `get_my_content_for_placement`
- [ ] `dismiss_content_item`
- [ ] `record_content_event` (allowlist impression|click)
- [ ] Колонка `event_hour` (UTC hour bucket, пишет только RPC)
- [ ] UNIQUE `(content_item_id, user_id, event_type, event_hour)`
- [ ] Rate-limit / dedupe events через эту UNIQUE / upsert-стратегию
- [ ] Event только если item реально видим caller
- [ ] Event/audit meta без CTA URL / лишних ПДн
- [ ] Retention policy для events
- [ ] Cache-first mobile
- [ ] Refresh после app resume
- [ ] Pull-to-refresh
- [ ] Нет N+1 (есть evidence: batch/join)
- [ ] Нет сырого JSON в UI
- [ ] Archived/hidden не выдаётся mobile RPC

---

## K. Stage 14 — assets & storage

- [ ] Private Storage bucket
- [ ] Typed ownership Stage 14 через FK `content_assets.content_item_id`
- [ ] В Stage 14 нет polymorphic `owner_kind`
- [ ] Signed upload
- [ ] Signed download с authz на каждое чтение
- [ ] MIME whitelist
- [ ] Size whitelist
- [ ] Individual asset deletion forbidden while current item references it
- [ ] `admin_safe_delete_content` разрешён только для archived item
- [ ] Safe-delete enqueue всех asset paths в `content_media_cleanup_queue` до delete
- [ ] Safe-delete может каскадно удалить archived item + version history + assets одной транзакцией
- [ ] Cleanup queue + retry
- [ ] Нет Base64 в БД

---

## L. Stage 14 — security assertions

- [ ] `SECURITY DEFINER` только при необходимости
- [ ] `search_path=''`
- [ ] `auth.uid()` обязателен
- [ ] Membership/RBAC на сервере
- [ ] IDOR tests PASS
- [ ] SQL security review PASS
- [ ] SQL behavioral role-play + rollback PASS
- [ ] Secret scan clean
- [ ] `git diff --check` clean
- [ ] Codex APPROVE Stage 14 foundation

---

## M. Stage 14.1 — Demo governance

- [ ] Инвентаризация hardcoded/demo элементов записана
- [ ] Демо не удалено до миграции/замены
- [ ] `origin=demo`
- [ ] Фильтр «Демо» в админке
- [ ] Архивирование демо через админку
- [ ] Удаление демо через админку
- [ ] Замена демо реальным материалом
- [ ] Демо не возвращается самопроизвольно после удаления
- [ ] Demo fallback не маскирует ошибку сервера
- [ ] Demo-вакансии: «Пример» или вне production-аудитории
- [ ] Demo-отзывы: «Пример» или вне production-аудитории
- [ ] Codex APPROVE 14.1

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
- [ ] Общий renderer Mobile ↔ Admin Preview
- [ ] Утверждённые шаблоны вместо свободного конструктора
- [ ] Нет сырых enum в UI
- [ ] Нет сырых UUID в UI
- [ ] Нет сырого JSON в UI
- [ ] Нет developer labels в UI
- [ ] Понятные тексты на русском
- [ ] Современная типографика
- [ ] Единые радиусы
- [ ] Единые отступы
- [ ] Правильный SafeArea
- [ ] Клавиатура не перекрывает действия
- [ ] Tap outside закрывает клавиатуру
- [ ] Drag закрывает клавиатуру (где применимо)
- [ ] Done закрывает клавиатуру
- [ ] Loading state
- [ ] Error state
- [ ] Empty state
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
- [ ] Widget/golden tests критичных шаблонов
- [ ] Дизайн не выглядит как техническая форма
- [ ] Дизайн не отличается от основного приложения

---

## AA. Stage 20 — AI (spec only)

- [ ] `docs/content_platform/AI_ASSISTANTS_SPEC.md` создан
- [ ] Вариант: определение колонок неизвестного Excel
- [ ] Вариант: сопоставление преподавателей/предметов и дубли
- [ ] Вариант: очистка OCR
- [ ] Вариант: черновик карточки предмета из файла
- [ ] Вариант: черновик новости/promo
- [ ] Вариант: классификация вакансии
- [ ] Вариант: предварительная проверка отзывов
- [ ] Вариант: поиск ПДн и оскорблений
- [ ] Вариант: объяснение ошибок импорта
- [ ] Вариант: помощник администратора по контенту
- [ ] AI только черновик
- [ ] Публикация только человеком
- [ ] Нет скрытых автодействий
- [ ] Минимизация ПДн
- [ ] Журнал источников
- [ ] Лимиты стоимости
- [ ] Полный opt-out AI
- [ ] Платный AI не внедрён автоматически
- [ ] Codex APPROVE Stage 20 docs

---

## AB. Stage 21 — RU infra (roadmap only)

- [ ] `docs/content_platform/RF_INFRA_MIGRATION_ROADMAP.md` создан
- [ ] Российский VPS
- [ ] PostgreSQL
- [ ] Auth
- [ ] Storage
- [ ] Realtime
- [ ] Edge/worker/cron
- [ ] Резервные копии
- [ ] Мониторинг
- [ ] Домен/TLS
- [ ] Миграционная репетиция
- [ ] Проверка целостности
- [ ] Rollback
- [ ] Временный read-only/cutover
- [ ] Обновление Flutter конфигурации
- [ ] Caveat: снижение зависимости от Supabase
- [ ] Caveat: FCM/APNs остаются внешними
- [ ] Caveat: VPN-independence без физического теста не обещается
- [ ] Перенос сейчас не выполнялся
- [ ] Codex APPROVE Stage 21 docs

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

- [ ] Все технически возможные локальные подэтапы выполнены или заблокированы в CURRENT_TASK
- [ ] Каждый завершённый подэтап имеет Codex APPROVE
- [ ] Roadmap обновлён
- [ ] CURRENT_TASK обновлён
- [ ] Checklist отражает факт
- [ ] Migrations подготовлены, remote не применены
- [ ] Remote данные не изменены
- [ ] Push не выполнен
- [ ] Git tree clean или status объяснён
- [ ] Финальный отчёт владельцу (14 разделов brief)
