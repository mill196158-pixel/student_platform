# Связи экранов с существующими тестами

Автоматическая статическая карта прямых импортов. Импорт не доказывает, что весь экран проверен: тест может проверять только вспомогательный виджет. Отсутствие импорта не исключает косвенное покрытие. Это НЕ E2E-покрытие и НЕ процент протестированного функционала.

| Исходник | Тесты с прямым импортом |
|---|---|
| lib/src/ui/authentication/authenticate_screen.dart | Нет прямого импорта |
| lib/src/ui/authentication/screens/change_password_screen.dart | Нет прямого импорта |
| lib/src/ui/authentication/screens/login_screen.dart | Нет прямого импорта |
| lib/src/ui/authentication/screens/register_screen.dart | test/registration_access_test.dart |
| lib/src/ui/chats/archive_screen.dart | Нет прямого импорта |
| lib/src/ui/chats/core/unified_chat_screen.dart | Нет прямого импорта |
| lib/src/ui/chats/direct_chat_info_screen.dart | Нет прямого импорта |
| lib/src/ui/chats/direct_chat_screen.dart | Нет прямого импорта |
| lib/src/ui/chats/my_chats_screen.dart | Нет прямого импорта |
| lib/src/ui/exams/exams_screen.dart | Нет прямого импорта |
| lib/src/ui/friends/friend_profile_screen.dart | Нет прямого импорта |
| lib/src/ui/friends/my_friends_screen.dart | Нет прямого импорта |
| lib/src/ui/group_space/group_space_screen.dart | Нет прямого импорта |
| lib/src/ui/home/home_screen.dart | Нет прямого импорта |
| lib/src/ui/info/entity_review_screen.dart | Нет прямого импорта |
| lib/src/ui/info/info_screen.dart | test/group_chat_actions_stage13_9_test.dart, test/group_space_stage13_2_test.dart, test/info_tab_stage13_test.dart, test/info_vacancy_wiring_test.dart, test/profile_stage13_1_test.dart |
| lib/src/ui/info/my_vacancy_submissions_screen.dart | Нет прямого импорта |
| lib/src/ui/info/propose_vacancy_screen.dart | Нет прямого импорта |
| lib/src/ui/info/subject_info_screen.dart | test/info_tab_stage13_test.dart |
| lib/src/ui/info/teacher_profile_screen.dart | Нет прямого импорта |
| lib/src/ui/learning/assignment_details_screen.dart | Нет прямого импорта |
| lib/src/ui/learning/learning_screen.dart | Нет прямого импорта |
| lib/src/ui/learning/manage/manage_teams_screen.dart | Нет прямого импорта |
| lib/src/ui/learning/tabs/assignments_tab.dart | Нет прямого импорта |
| lib/src/ui/learning/tabs/chat/collections/create_collection_screen.dart | Нет прямого импорта |
| lib/src/ui/learning/tabs/chat/topics/create_topic_selection_screen.dart | Нет прямого импорта |
| lib/src/ui/learning/tabs/chat/topics/topic_list_review_screen.dart | test/topic_editor_stage13_12_test.dart |
| lib/src/ui/learning/tabs/chat/topics/topic_options_editor_screen.dart | test/topic_editor_stage13_12_test.dart |
| lib/src/ui/learning/tabs/chat/topics/topic_selection_detail_screen.dart | test/group_chat_actions_stage13_11_test.dart |
| lib/src/ui/learning/tabs/chat/unified_task_details_screen.dart | test/group_action_cards_stage13_12_test.dart |
| lib/src/ui/learning/tabs/chat_tab.dart | Нет прямого импорта |
| lib/src/ui/learning/tabs/files_tab.dart | Нет прямого импорта |
| lib/src/ui/learning/team_details_screen.dart | Нет прямого импорта |
| lib/src/ui/navigation/navigation_screen.dart | Нет прямого импорта |
| lib/src/ui/navigation/visited_tab.dart | test/visited_tab_test.dart |
| lib/src/ui/notifications/notification_settings_screen.dart | Нет прямого импорта |
| lib/src/ui/profile/edit_profile_screen.dart | Нет прямого импорта |
| lib/src/ui/profile/my_reviews_screen.dart | Нет прямого импорта |
| lib/src/ui/profile/personal_diary_screen.dart | Нет прямого импорта |
| lib/src/ui/profile/profile_screen.dart | test/profile_stage13_1_test.dart |
| lib/src/ui/schedule/diary_entry_details_screen.dart | Нет прямого импорта |
| lib/src/ui/schedule/lesson_details_screen.dart | Нет прямого импорта |
| lib/src/ui/schedule/schedule_screen.dart | Нет прямого импорта |
| lib/src/ui/schedule/subject_diary/screens/photo_conspect_screen.dart | Нет прямого импорта |
| lib/src/ui/schedule/subject_diary/screens/quick_note_screen.dart | Нет прямого импорта |
| lib/src/ui/schedule/subject_diary_screen.dart | Нет прямого импорта |
| lib/src/ui/splash/splash_screen.dart | Нет прямого импорта |
