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

- [ ] «Застрял с заданием?» → managed promo
- [ ] Редактируется заголовок
- [ ] Редактируется подзаголовок
- [ ] Редактируется изображение/иллюстрация
- [ ] Редактируется градиент
- [ ] Редактируется иконка
- [ ] Редактируется CTA
- [ ] Редактируется внутренний маршрут
- [ ] Редактируется проверенная внешняя ссылка
- [ ] Редактируется аудитория
- [ ] Редактируется период показа
- [ ] Редактируется порядок
- [ ] Возможность закрыть карточку
- [ ] Политика повторного показа
- [ ] Статус draft
- [ ] Статус published
- [ ] Статус archived
- [ ] Origin/status demo
- [ ] Renderer в `packages/student_ui`
- [ ] Admin Preview = тот же renderer
- [ ] Mobile = тот же renderer
- [ ] Cache-first + resume/refresh
- [ ] Widget/golden tests promo
- [ ] Codex APPROVE 15.1

---

## O. Stage 15.2 — News targeting extension

- [ ] News backend не переписан с нуля
- [ ] Аудитория «все»
- [ ] Аудитория несколько групп
- [ ] Аудитория явный набор пользователей
- [ ] Preview получателей новостей
- [ ] Существующие публикации сохранены
- [ ] Существующие изображения сохранены
- [ ] Обратная совместимость
- [ ] Нет утечки скрытых новостей через RPC
- [ ] Нет утечки через кеш
- [ ] Нет утечки через signed URL
- [ ] Codex APPROVE 15.2

---

## P. Stage 15.3 — Profile feed

- [ ] Placement `profile_feed`
- [ ] Контент для всех
- [ ] Контент для групп
- [ ] Контент для отдельных пользователей
- [ ] Порядок
- [ ] Расписание
- [ ] Preview аудитории
- [ ] Управление из Admin
- [ ] Единый дизайн приложения
- [ ] Новости не дублируются автоматически
- [ ] Админ явно выбирает placement
- [ ] Codex APPROVE 15.3

---

## Q. Stage 16 — Subject card editor

- [ ] Admin визуальный editor карточки предмета
- [ ] Название
- [ ] Краткое описание
- [ ] Подробное описание
- [ ] Чему научится студент
- [ ] Форма контроля
- [ ] Часы
- [ ] Зачётные единицы
- [ ] Требования
- [ ] Советы по подготовке
- [ ] Преподаватели
- [ ] Дата актуальности
- [ ] Изображения
- [ ] Файлы
- [ ] Ссылки
- [ ] Порядок секций
- [ ] Preview мобильной карточки
- [ ] Catalog-level данные
- [ ] Безопасный offering-level override
- [ ] Связь через `subject_id` / `subject_catalog_id` / `subject_offering_id`
- [ ] Название не является ключом
- [ ] Codex APPROVE 16.1

---

## R. Stage 16 — Subject files

- [ ] Private Storage
- [ ] Signed upload
- [ ] Signed download
- [ ] MIME whitelist
- [ ] Size whitelist
- [ ] Versioning
- [ ] Cleanup после безопасного удаления
- [ ] Нет Base64 в БД
- [ ] Codex APPROVE 16.2

---

## S. Stage 16 — Reference

- [ ] Полностью управляемый справочник
- [ ] Категории
- [ ] Иконка
- [ ] Заголовок
- [ ] Короткий текст
- [ ] Полный материал
- [ ] Изображения
- [ ] Файлы
- [ ] Ссылки
- [ ] CTA
- [ ] Порядок
- [ ] Аудитория
- [ ] Draft
- [ ] Publish
- [ ] Archive
- [ ] Admin Preview
- [ ] Mobile cache-first renderer
- [ ] «Сообщить об ошибке»
- [ ] Произвольный HTML запрещён
- [ ] Произвольный JS запрещён
- [ ] Codex APPROVE 16.3

---

## T. Stage 17 — Vacancies

- [ ] Отдельная доменная модель (не generic content JSON SoT)
- [ ] Админ создаёт вакансию
- [ ] Пользователь предлагает через форму
- [ ] User submission не публикуется сразу
- [ ] Поле название
- [ ] Поле организация
- [ ] Поле описание
- [ ] Поле формат занятости
- [ ] Поле местоположение/удалённо
- [ ] Поле зарплата (optional)
- [ ] Поле требования
- [ ] Поле контакты
- [ ] Поле ссылка
- [ ] Поле срок актуальности
- [ ] Поле аудитория
- [ ] Поле изображения/файлы
- [ ] Поле автор заявки
- [ ] Поле источник
- [ ] Поле дата проверки
- [ ] Статус draft
- [ ] Статус submitted
- [ ] Статус moderation / in_moderation
- [ ] Статус approved/published
- [ ] Статус expired
- [ ] Статус archived
- [ ] Статус rejected
- [ ] Предпросмотр
- [ ] Срок окончания в выдаче
- [ ] Жалоба
- [ ] Защита контактов
- [ ] Проверка ссылок
- [ ] Причина отклонения
- [ ] Журнал модерации
- [ ] Mobile-карточка
- [ ] Admin-карточка
- [ ] Demo-вакансии отдельно / не вводят в заблуждение
- [ ] Codex APPROVE 17

---

## U. Stage 18 — Reviews (extend 13.6)

- [ ] Вторая система отзывов не создана
- [ ] Расширен Stage 13.6
- [ ] Отзывы на преподавателя
- [ ] Отзывы на предмет
- [ ] Вакансия/работодатель только после отдельного продуктового решения
- [ ] Структурированные оценки/теги
- [ ] Короткий текст
- [ ] Анонимность для студентов
- [ ] Автор виден модерации
- [ ] Жалоба
- [ ] Редактирование до начала модерации
- [ ] Один отзыв на разрешённый контекст
- [ ] Блок ПДн
- [ ] Блок оскорблений
- [ ] Блок обвинений
- [ ] Публикация только после модерации
- [ ] Нельзя модерировать свой отзыв
- [ ] Rate limit
- [ ] Антиспам
- [ ] Codex APPROVE 18 reviews

---

## V. Stage 18 — Points ledger

- [ ] +1 балл за один одобренный отзыв
- [ ] Начисление только после одобрения
- [ ] Идемпотентность
- [ ] Повторная отправка ≠ второй балл
- [ ] Редактирование ≠ второй балл
- [ ] Уникальная ledger-запись по `review_id`
- [ ] Compensating запись при удалении за нарушение
- [ ] История баллов для студента
- [ ] Баллы не деньги
- [ ] Баллы не выводятся
- [ ] Codex APPROVE 18 points

---

## W. Stage 18 — Unified moderation Admin

- [ ] Раздел «Модерация»
- [ ] Очередь отзывов
- [ ] Очередь вакансий
- [ ] Очередь жалоб
- [ ] Очередь исправлений контента
- [ ] Фильтр тип
- [ ] Фильтр статус
- [ ] Фильтр дата
- [ ] Фильтр автор
- [ ] Фильтр приоритет
- [ ] Фильтр назначенный модератор
- [ ] Принять
- [ ] Отклонить с причиной
- [ ] Запросить уточнение
- [ ] Скрыть
- [ ] Восстановить
- [ ] Открыть историю
- [ ] Audit log всех действий
- [ ] Codex APPROVE 18 moderation

---

## X. Stage 19 — Import Studio domains

- [ ] Единый Admin Import Studio hub
- [ ] Отдельные валидаторы доменов
- [ ] Домен преподаватели: template
- [ ] Домен преподаватели: mapping
- [ ] Домен преподаватели: validator
- [ ] Домен преподаватели: dry-run
- [ ] Домен преподаватели: diff
- [ ] Домен преподаватели: apply
- [ ] Домен преподаватели: idempotent replay
- [ ] Домен преподаватели: safe rollback (где возможно)
- [ ] Домен предметы: template
- [ ] Домен предметы: mapping
- [ ] Домен предметы: validator
- [ ] Домен предметы: dry-run
- [ ] Домен предметы: diff
- [ ] Домен предметы: apply
- [ ] Домен предметы: idempotent replay
- [ ] Домен предметы: safe rollback (где возможно)
- [ ] Домен студенты: template
- [ ] Домен студенты: mapping
- [ ] Домен студенты: validator
- [ ] Домен студенты: dry-run
- [ ] Домен студенты: diff
- [ ] Домен студенты: apply
- [ ] Домен студенты: idempotent replay
- [ ] Домен студенты: safe rollback (где возможно)
- [ ] Домен группы: template
- [ ] Домен группы: mapping
- [ ] Домен группы: validator
- [ ] Домен группы: dry-run
- [ ] Домен группы: diff
- [ ] Домен группы: apply
- [ ] Домен группы: idempotent replay
- [ ] Домен группы: safe rollback (где возможно)
- [ ] Домен семестры: template
- [ ] Домен семестры: mapping
- [ ] Домен семестры: validator
- [ ] Домен семестры: dry-run
- [ ] Домен семестры: diff
- [ ] Домен семестры: apply
- [ ] Домен семестры: idempotent replay
- [ ] Домен семестры: safe rollback (где возможно)
- [ ] Домен учебные планы групп: template
- [ ] Домен учебные планы групп: mapping
- [ ] Домен учебные планы групп: validator
- [ ] Домен учебные планы групп: dry-run
- [ ] Домен учебные планы групп: diff
- [ ] Домен учебные планы групп: apply
- [ ] Домен учебные планы групп: idempotent replay
- [ ] Домен учебные планы групп: safe rollback (где возможно)
- [ ] Домен offering: template
- [ ] Домен offering: mapping
- [ ] Домен offering: validator
- [ ] Домен offering: dry-run
- [ ] Домен offering: diff
- [ ] Домен offering: apply
- [ ] Домен offering: idempotent replay
- [ ] Домен offering: safe rollback (где возможно)
- [ ] Домен связи преподавателей: template
- [ ] Домен связи преподавателей: mapping
- [ ] Домен связи преподавателей: validator
- [ ] Домен связи преподавателей: dry-run
- [ ] Домен связи преподавателей: diff
- [ ] Домен связи преподавателей: apply
- [ ] Домен связи преподавателей: idempotent replay
- [ ] Домен связи преподавателей: safe rollback (где возможно)
- [ ] Домен enrollment: template
- [ ] Домен enrollment: mapping
- [ ] Домен enrollment: validator
- [ ] Домен enrollment: dry-run
- [ ] Домен enrollment: diff
- [ ] Домен enrollment: apply
- [ ] Домен enrollment: idempotent replay
- [ ] Домен enrollment: safe rollback (где возможно)

---

## Y. Stage 19 — Import Studio UX / safety (cross-domain)

- [ ] Кнопка «Скачать шаблон Excel»
- [ ] Визуальный предпросмотр таблицы в админке
- [ ] Названия обязательных колонок
- [ ] Названия необязательных колонок
- [ ] Примеры заполнения
- [ ] Ошибки обычным языком
- [ ] Загрузка XLSX
- [ ] Определение листов
- [ ] Mapping колонок
- [ ] Таблица валидных строк
- [ ] Таблица ошибочных строк
- [ ] Diff до apply
- [ ] Warning о создаваемых предметах
- [ ] Warning о создаваемых командах/чатах
- [ ] Apply только после подтверждения
- [ ] Audit / import batch id
- [ ] Цепочка: academic term
- [ ] Цепочка: group
- [ ] Цепочка: subject_catalog
- [ ] Цепочка: curriculum
- [ ] Цепочка: subject_offering
- [ ] Цепочка: offering_teachers
- [ ] Цепочка: enrollment
- [ ] Цепочка: team/chat creation
- [ ] Нет связывания по названию при наличии ID
- [ ] Текущий семестр не переключается автоматически
- [ ] Осень 2026 не создаётся без владельца
- [ ] Web Admin без service_role
- [ ] Привилегии только RPC/Edge + RBAC
- [ ] Codex APPROVE 19 foundation (минимум template+dry-run для выбранных доменов) и отдельные APPROVE на расширение доменов

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
