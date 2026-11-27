# Главная на физическом iPhone

Проверку закрывают запись первого видимого кадра главной и журнал той же подписанной сборки. Снимок `pubspec.yaml` показывает версию исходников, установленную версию читает Xcode с телефона.

## Установленная сборка

На Mac с Xcode подключите разблокированный iPhone, которому доверяет компьютер. Для сборки, подписанной для разработки, включите Developer Mode. Проверьте наличие iPhone в `xcrun devicectl list devices`. До обновления зафиксируйте версию приложения со сбоем. [Xcode и физические устройства](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

```bash
export IPHONE_DEVICE_ID='<идентификатор подключённого iPhone>'
bundle=com.mill453020.studentplatform
evidence=$(mktemp -d)

xcrun devicectl device info apps --device "$IPHONE_DEVICE_ID" \
  --bundle-id "$bundle" --json-output "$evidence/installed-before.json"
plutil -extract result.apps.0.version raw -o - "$evidence/installed-before.json"
plutil -extract result.apps.0.bundleVersion raw -o - "$evidence/installed-before.json"
```

Сопоставьте эти поля с журналом выпуска или исходным архивом этой установки. В `b8fac31` встроенной ревизии нет, а один номер сборки мог использоваться повторно. Для исходной установки без журнала запишите версию и оставьте Git-ревизию неизвестной. [Ключи версии Apple](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html) · [Команда Xcode в тестах Flutter](https://chromium.googlesource.com/external/github.com/flutter/flutter/+/c6f719d7a523f0a9f7c349b963339a4b268db57d/packages/flutter_tools/test/general.shard/ios/core_devices_test.dart#2372)

## Подписанный кандидат

В основном каталоге на Mac выберите проверяемый коммит и настройте подпись Runner в `ios/Runner.xcworkspace`. Укажите новый номер сборки и убедитесь, что `git status --porcelain` пуст. Оставьте прежнюю установку и её данные для проверки сохранённого снимка при обновлении приложения. [Release-сборка Flutter](https://docs.flutter.dev/deployment/ios)

```bash
export HOME_QA_BUILD='<свободный номер сборки>'
(
  set -eu
  source_status=$(git status --porcelain)
  test -z "$source_status"
  revision=$(git rev-parse HEAD)
  printf 'Revision %s\n' "$revision"
  flutter build ios --release --build-number="$HOME_QA_BUILD" \
    --dart-define=HOME_FRAME_TRACE=true --dart-define=STARTUP_TRACE=true \
    --dart-define=BUILD_REVISION="$revision"

  app=build/ios/iphoneos/Runner.app
  codesign --verify --deep --strict "$app"
  app_version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist")
  app_build=$(plutil -extract CFBundleVersion raw -o - "$app/Info.plist")
  test "$app_build" = "$HOME_QA_BUILD"
  shasum -a 256 "$app/Frameworks/App.framework/App"

  xcrun devicectl device install app --device "$IPHONE_DEVICE_ID" "$app"
  installed="$evidence/installed-after.json"
  xcrun devicectl device info apps --device "$IPHONE_DEVICE_ID" \
    --bundle-id "$bundle" --json-output "$installed"
  installed_version=$(plutil -extract result.apps.0.version raw -o - "$installed")
  installed_build=$(plutil -extract result.apps.0.bundleVersion raw -o - "$installed")
  test "$installed_version" = "$app_version"
  test "$installed_build" = "$app_build"
  printf 'Installed %s+%s\n' "$installed_version" "$installed_build"
)
```

Проверьте совпадение версии и номера на телефоне и в `.app`. В Console на Mac выберите iPhone и найдите строки `[startup-perf]` и `[home-frame]` процесса Runner. Последние содержат `mode=release` и `revision=<SHA>` работающего Dart-кода. Пара `*_paint` и `*_raster` с одинаковым номером кадра связывает построение и растеризацию. Запись экрана показывает первый кадр, увиденный пользователем. [Журнал устройства в Console](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)

## Запись первого кадра

Запишите модель iPhone, версию iOS, номер сборки и Git SHA. Включите запись экрана. На тестовом аккаунте сначала откройте главную с цветными новостями и промобаннерами и дождитесь сохранения снимка. Для каждой строки проведите вход с иконки после принудительного закрытия процесса и возврат с другой вкладки.

| Условие | Что должно быть видно в первом кадре |
| --- | --- |
| Обычная сеть, ранее открытая главная | Заголовок, видимые карточки новостей и промобаннеров в цвете, остальные видимые блоки в готовом положении. |
| Медленная сеть, сохранённая главная | Тот же готовый кадр до ответа API. Зафиксируйте условия ограничения сети. При обновлении прежний снимок виден до готовности замены. |
| Авиарежим и Wi‑Fi выключен, действующий офлайн-доступ | Готовый локальный снимок. Отдельно отметьте результат проверки доступа и выдачи снимка. |
| Тестовый новый аккаунт или чистые данные | Пустое или загрузочное состояние текущего аккаунта. Снимок другого студента отсутствует. |

В журнале сопоставьте время восстановления снимка, количество найденных и ожидаемых файлов, декодированные обложки и первый кадр. При поздней вставке сравните координаты остальных блоков до и после. Если подтвердились только размеры или цвет одной карточки, проверка всей главной остаётся открытой.

Из уже загруженной главной откройте «Новое приложение» в «Что нового». Для публикации от 22 июля проверьте реальную цветную обложку в первом видимом кадре «Добро пожаловать». Повторите при медленной сети и в авиарежиме с действующим офлайн-доступом. Строки `story_cover_read` и `story_cover_decoded` должны предшествовать `story_first_visible_paint` и `story_first_visible_raster`. С чистым кэшем текст должен оставаться читаемым и на одном месте при появлении обложки.
