# Student Platform Admin

Отдельная desktop-first панель управления на Flutter Web.

## Обычный запуск (реальный вход в браузере)

Из корня репозитория:

macOS / Linux:

```bash
./scripts/run_admin_web.sh
```

macOS (двойной клик):

```text
scripts/run_admin_web.command
```

Windows PowerShell:

```powershell
.\scripts\run_admin_web.ps1
```

Windows cmd / двойной клик:

```text
scripts\run_admin_web.bat
```

Скрипты переходят в `admin_console`, при необходимости выполняют `flutter pub get`
и запускают Chrome на фиксированном адресе:

```text
http://localhost:3000
```

Форма входа открывается в браузере: пользователь вводит email и пароль в UI.
После входа вызывается `get_my_admin_capabilities`.

Публичный `publishable`/`anon` key и URL проекта заданы по умолчанию в
`AdminBackendConfig` (тот же клиентский ключ, что у мобильного приложения).
`--dart-define=SUPABASE_URL=...` / `SUPABASE_PUBLISHABLE_KEY=...` остаются
необязательным override для разработки.

В реальном режиме в интерфейсе показывается маркировка **«Подключено»**.

### Supabase Auth — Redirect URLs (обязательно для сброса пароля)

В [Supabase Dashboard](https://supabase.com/dashboard) → **Authentication** →
**URL Configuration** добавьте в **Redirect URLs**:

```text
http://localhost:3000/**
```

`resetPasswordForEmail` отправляет `redirectTo` ровно:

```text
http://localhost:3000/
```

Без `#`, `?` и внутреннего route. Supabase сам добавляет recovery-фрагмент в URL;
приложение ловит `AuthChangeEvent.passwordRecovery` и открывает экран смены пароля.

Без allowlist redirect recovery-ссылка из письма не вернёт пользователя в локальный
Admin Web.

## Demo-запуск (локальный прототип)

Только явно:

```bash
./scripts/run_admin_web_demo.sh
```

```powershell
.\scripts\run_admin_web_demo.ps1
```

или:

```bash
cd admin_console
flutter run -d chrome --dart-define=ADMIN_DEMO_MODE=true
```

Без `ADMIN_DEMO_MODE=true` приложение **не** переходит в demo молча при ошибке
backend — показывается явная ошибка конфигурации/подключения.

## Безопасность

- Publishable/anon key — **публичный клиентский** ключ; доступ ограничивается RLS и RPC.
- `service_role`, Firebase service account, пароли и пользовательские JWT в клиент
  и launch-скрипты класть **запрещено**.
- Access/refresh token из recovery-ссылки не логируются и не показываются в UI.
- Вход выполняется внутри браузера через Supabase Auth; админ-права только через
  server-side RBAC assignments.

## Маршруты

- `/login`
- `/auth/forgot-password`
- `/auth/reset-password`
- `/dashboard`
- `/content/news`
- `/academic/subjects`
- `/academic/teachers`

Главная дорожная карта: `../docs/admin_console/ADMIN_ROADMAP.md`.
