# Проверка конфигурации обычной Android-сборки — 7 ноября 2026

- Проверенный исходный коммит: `39281ff6fab58e860f56ad09d696c654decec954`. Различия в tracked исходниках Dart на момент сборки отсутствовали; изменённые пользовательский Excel и отчёт Gradle в сборку не включались.
- Локальная debug-сборка `flutter build apk --debug --no-pub`: SHA-256 `67e5286a9a8f5f96b6ab9da62f5a729793f5a161122029c06ef78bbee9f4e9e8`.
- Прежний файл `C:\student_platform_e2e\normal-app-defines.json`: SHA-256 `1b96b826e9e0e7c6037ed4c58e3ed89233752c25a587dbbce4e821f5e3ddaf31`; только SUPABASE_URL и SUPABASE_ANON_KEY, оба равны исходным значениям по умолчанию. Сервер `gwdanmwluhrcfxbnplwd.supabase.co`, QA/experiment defines в файле отсутствуют, service-role key отсутствует. Сам файл не включать в Git.
- Сборка с указанным defines-файлом и её хеш должны быть зафиксированы отдельно перед установкой. APK выше собран без defines-файла и на устройство не устанавливался.
- До установки на `emulator-5554` находилась версия APK SHA-256 `f8cb04192bbf8f742f3ffca0af5a58cb7e97eb390d1621b63182c9fc1f7b2331`. Контроль сохранности текущего черновика и устройство обязательны перед заменой.
