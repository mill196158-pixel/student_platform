# iOS TestFlight — инструкция на завтра (Mac)

Краткий чеклист перед Archive и загрузкой в App Store Connect.

## 1. Команды в терминале (из корня проекта)

```bash
flutter clean
flutter pub get
cd ios && pod install --repo-update && cd ..
open ios/Runner.xcworkspace
```

> Открывай **Runner.xcworkspace**, не `Runner.xcodeproj`.

После успешного `pod install` на Mac можно закоммитить `ios/Podfile.lock` (рекомендуется для воспроизводимых сборок).

## 2. Xcode — Runner → Signing & Capabilities

| Параметр | Значение |
|----------|----------|
| Bundle Identifier | `com.mill453020.studentplatform` |
| Team | выбрать вручную (Apple Developer account) |
| Automatically manage signing | **ON** |

Дополнительно проверь:

- **General → Minimum Deployments → iOS 15.0**
- Схема **Runner** (не RunnerTests) выбрана для Archive

`DEVELOPMENT_TEAM` в репозитории не задан — это нормально, Xcode пропишет его локально после выбора Team.

## 3. Archive и Upload

1. Устройство: **Any iOS Device (arm64)** (не симулятор)
2. **Product → Archive**
3. Organizer → **Distribute App**
4. **App Store Connect** → **Upload**
5. Дождаться обработки билда в App Store Connect (обычно 5–30 мин)

Альтернатива из терминала (после настройки signing):

```bash
flutter build ipa --release
```

IPA: `build/ios/ipa/` → загрузить через **Transporter**.

## 4. App Store Connect

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **My Apps** → **+** → New App
2. Bundle ID: **`com.mill453020.studentplatform`** (должен совпадать с Xcode)
3. Version: **1.0.0**, Build: **1** (из `pubspec.yaml`: `1.0.0+1`)
4. После обработки билда → вкладка **TestFlight**

### Тестировщики

- **Internal testing** — добавь себя (член команды в App Store Connect)
- **External testing** — добавь жену как external tester (нужен Beta App Review для первой external-группы)

## 5. Что уже настроено в репозитории

- iOS Deployment Target: **15.0** (Podfile, AppFrameworkInfo.plist, project.pbxproj)
- Bundle ID Runner: **com.mill453020.studentplatform**
- `Info.plist`: photo/camera permissions (RU)
- `version: 1.0.0+1` в `pubspec.yaml`
- Нет `NSAllowsArbitraryLoads` / `NSAppTransportSecurity`

## 6. Если что-то пойдёт не так

| Проблема | Действие |
|----------|----------|
| Signing error | Xcode → Settings → Accounts → войти в Apple ID → выбрать Team |
| Bundle ID not found | Developer Portal → Identifiers → зарегистрировать `com.mill453020.studentplatform` |
| Pod install fails | `cd ios && pod deintegrate && pod install --repo-update` |
| Archive greyed out | Выбрать **Any iOS Device**, не симулятор |
