# Student Platform · проверка экранов от 27 ноября 2026

База для сравнения `e7afc7a`. Кадры сняты во Flutter на Windows при портретных размерах iPhone. Для чатов использованы тестовые данные. В кадрах с клавиатурой тест создаёт её системный отступ. Проверка Release на физическом iPhone открыта.

## Главная

Локальная лента успевала отдать метаданные до загрузки обложек. Даже готовое изображение на первом кадре скрывали две анимации появления. Теперь Home читает сохранённые метаданные текущего аккаунта и первые обложки, готовит декодированные изображения с теми же ключами, которые использует карусель, и оставляет готовую обложку в карточке во время обновления. Вход на вкладку сохраняет карточку и её положение. При первом запуске без кэша полоса ожидания занимает высоту будущих новостей. Пустой результат меняет сообщение на месте, без смещения сводки.

Apple рекомендует готовить изображения до показа и приводит рабочий пример UIKit. Flutter `precacheImage` использует общий `ImageCache`, когда последующий виджет запрашивает тот же ключ. В примере Google Now in Android размер места для обложки задан до получения картинки. [Сессия Apple](https://developer.apple.com/videos/play/wwdc2021/10252/) · [Пример Apple](https://developer.apple.com/documentation/uikit/building-high-performance-lists-and-collection-views) · [Документация Flutter](https://api.flutter.dev/flutter/widgets/precacheImage.html) · [Now in Android](https://github.com/android/nowinandroid/blob/main/core/ui/src/main/kotlin/com/google/samples/apps/nowinandroid/core/ui/NewsResourceCard.kt)

Тест карусели проверяет пиксели первого кадра и первого кадра после возврата без ожидания анимации. На старом коде оба пикселя были `#F5F7FB`, после исправления оба `#2A9D8F`. Однотонная обложка создана для однозначной проверки цвета. Тест экрана Home отдельно читает её из SQLite при очищенном `ImageCache` и проверяет кадр до ответа сервера, возврат на вкладку и обновление заголовка при недоступной повторной загрузке обложки. При повторном холодном открытии с обновлённым заголовком сохранённая обложка доступна офлайн. После удаления из кэша повторный вход открывает публикацию без прежней картинки.

| Кадр теста карусели | До | После |
| --- | --- | --- |
| Первый кадр | [PNG](student_iphone_frame_polish_20261127/feed-before-first-home-frame.png) | [PNG](student_iphone_frame_polish_20261127/feed-after-first-home-frame.png) |
| Возврат на вкладку | [PNG](student_iphone_frame_polish_20261127/feed-before-return-home-frame.png) | [PNG](student_iphone_frame_polish_20261127/feed-after-return-home-frame.png) |

Кадры экрана Home с SQLite. [Холодный вход](student_iphone_frame_polish_20261127/app-cold-first-home-frame.png) · [Первый кадр возврата](student_iphone_frame_polish_20261127/app-first-frame-after-tab-return.png) · [Обновление в фоне](student_iphone_frame_polish_20261127/app-same-cover-after-refresh.png) · [Офлайн после обновления заголовка](student_iphone_frame_polish_20261127/app-cold-offline-first-frame-after-title-edit.png)

## Профиль

«Данные приложения» показывает один измеряемый объём и действие «Очистить кэш». Ручная очистка удаляет временные копии изображений. В прогоне с двумя тестовыми студентами проверены байты загруженного чертежа, сохранённого офлайн-файла, истории и черновика после очистки. Заголовок проверен по координате центра на 320 с масштабом текста до 200% и при наличии и отсутствии кнопки назад.

Промобаннер при обычном тексте уменьшен с 212 до 184 логических пикселей. Тесты проверяют кадрирование, свайпы, нажатия и учёт показа. В «Моих отзывах» проверены пустой список, длинный отзыв, тёмная тема и переход на подробности.

| Экран | До | После |
| --- | --- | --- |
| Данные приложения · 320 · 160% · светлая | [PNG](student_iphone_frame_polish_20261127/app-data-before-narrow-large-light.png) | [PNG](student_iphone_frame_polish_20261127/app-data-after-narrow-large-light.png) |
| Данные приложения · 320 · 160% · тёмная | [PNG](student_iphone_frame_polish_20261127/app-data-before-narrow-large-dark.png) | [PNG](student_iphone_frame_polish_20261127/app-data-after-narrow-large-dark.png) |
| Промобаннер · светлая | [PNG](student_iphone_frame_polish_20261127/profile-before-light.png) | [PNG](student_iphone_frame_polish_20261127/profile-after-light.png) |
| Промобаннер · 320 · 125% · тёмная | [PNG](student_iphone_frame_polish_20261127/profile-before-narrow-dark.png) | [PNG](student_iphone_frame_polish_20261127/profile-after-narrow-dark.png) |
| Мои отзывы · светлая | [PNG](student_iphone_frame_polish_20261127/reviews-before-light.png) | [PNG](student_iphone_frame_polish_20261127/reviews-after-light.png) |
| Длинный отзыв · тёмная | [PNG](student_iphone_frame_polish_20261127/reviews-before-long-dark.png) | [PNG](student_iphone_frame_polish_20261127/reviews-after-long-dark.png) |
| Пустой список | [PNG](student_iphone_frame_polish_20261127/reviews-before-empty.png) | [PNG](student_iphone_frame_polish_20261127/reviews-after-empty.png) |

## Чаты

Пустое поле показывает «Сообщение» в разрешённом чате. В одну строку поле и боковые кнопки имеют высоту 48 логических пикселей и совпадают по центру. При наборе нескольких строк поле растёт вверх. В личном чате имя и аватар выделены, кнопки выровнены.

На отдельном стенде проверены «Надёжность систем водоснабжения» и «Моделирование системы водоснабжения». Для каждого пройдены вход из учебного меню, из материалов, из списка чатов и по ссылке внутри сообщения. Проверка сверяет аккаунт, команду, ID открытого основного чата, `readOnly`, свежий ответ о предложении задания и независимое разрешение отправки. Отдельный контроль проходит запрет перехода по ссылке и режим «Только чтение».

| Компоновка на 320 | До | После |
| --- | --- | --- |
| Группа · без клавиатуры | [PNG](student_iphone_frame_polish_20261127/chat-before-group-closed.png) | [PNG](student_iphone_frame_polish_20261127/chat-after-group-closed.png) |
| Группа · с отступом клавиатуры · 160% | [PNG](student_iphone_frame_polish_20261127/chat-before-group-keyboard.png) | [PNG](student_iphone_frame_polish_20261127/chat-after-group-keyboard.png) |
| Личный чат · без клавиатуры | [PNG](student_iphone_frame_polish_20261127/chat-before-private-closed.png) | [PNG](student_iphone_frame_polish_20261127/chat-after-private-closed.png) |
| Личный чат · с отступом клавиатуры · 160% | [PNG](student_iphone_frame_polish_20261127/chat-before-private-keyboard.png) | [PNG](student_iphone_frame_polish_20261127/chat-after-private-keyboard.png) |
| Полный экран личного чата · 320 | [PNG](student_iphone_frame_polish_20261127/chat-before-private-full-screen.png) | [PNG](student_iphone_frame_polish_20261127/chat-after-private-full-screen.png) |
