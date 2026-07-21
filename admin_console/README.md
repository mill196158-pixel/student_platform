# Student Platform Admin

Отдельная desktop-first панель управления на Flutter Web.

На этапе 12.0 приложение использует только локальные mock-данные. Supabase,
секреты и deploy-конфигурация не подключены.

## Быстрый запуск

Из корня репозитория:

macOS:

```bash
./scripts/run_admin_web.sh
```

Windows PowerShell:

```powershell
.\scripts\run_admin_web.ps1
```

Скрипты сами переходят в `admin_console`, при необходимости выполняют
`flutter pub get` и запускают Chrome.

Ручной запуск:

```bash
cd admin_console
flutter pub get
flutter run -d chrome
```

## Маршруты

- `/login`
- `/dashboard`
- `/content/news`
- `/academic/subjects`
- `/academic/teachers`

Главная дорожная карта: `../docs/admin_console/ADMIN_ROADMAP.md`.
