# Карта экранов после очистки — 29.10.2026

Статическая проверка связей от lib/main.dart, включая условные импорты.
Это не доказательство корректности каждого пользовательского сценария.

| Файл | Классы экранов | Строк | Достижим из main |
|---|---|---:|---|
| lib/src/ui/authentication/authenticate_screen.dart | AuthenticateScreen | 30 | да |
| lib/src/ui/authentication/screens/change_password_screen.dart | ChangePasswordScreen | 206 | да |
| lib/src/ui/authentication/screens/login_screen.dart | LoginScreen | 295 | да |
| lib/src/ui/authentication/screens/register_screen.dart | RegisterScreen | 25 | да |
| lib/src/ui/chats/archive_screen.dart | ArchiveScreen | 640 | да |
| lib/src/ui/chats/core/unified_chat_screen.dart | UnifiedChatScreen | 2526 | да |
| lib/src/ui/chats/direct_chat_info_screen.dart | DirectChatInfoScreen | 370 | да |
| lib/src/ui/chats/direct_chat_screen.dart | DirectChatScreen | 98 | да |
| lib/src/ui/chats/my_chats_screen.dart | MyChatsScreen | 2246 | да |
| lib/src/ui/exams/exams_screen.dart | ExamsScreen | 2615 | да |
| lib/src/ui/friends/friend_profile_screen.dart | FriendProfileScreen | 1592 | да |
| lib/src/ui/friends/my_friends_screen.dart | MyFriendsScreen | 1455 | да |
| lib/src/ui/group_space/group_space_screen.dart | GroupSpaceScreen, _CollectionDetailScreen, _TopicDetailScreen | 865 | нет, требует отдельного решения |
| lib/src/ui/home/home_screen.dart | HomeScreen | 1101 | да |
| lib/src/ui/info/entity_review_screen.dart | EntityReviewScreen | 576 | да |
| lib/src/ui/info/info_screen.dart | InfoScreen | 3636 | да |
| lib/src/ui/info/my_vacancy_submissions_screen.dart | MyVacancySubmissionsScreen | 117 | да |
| lib/src/ui/info/propose_vacancy_screen.dart | ProposeVacancyScreen | 356 | да |
| lib/src/ui/info/subject_info_screen.dart | SubjectInfoScreen | 1999 | да |
| lib/src/ui/info/teacher_profile_screen.dart | TeacherProfileScreen | 1268 | да |
| lib/src/ui/learning/assignment_details_screen.dart | AssignmentDetailsScreen | 876 | да |
| lib/src/ui/learning/learning_screen.dart | LearningScreen | 965 | да |
| lib/src/ui/learning/manage/manage_teams_screen.dart | ManageTeamsScreen | 144 | нет, требует отдельного решения |
| lib/src/ui/learning/tabs/assignments_tab.dart | AssignmentsTab | 891 | да |
| lib/src/ui/learning/tabs/chat/collections/create_collection_screen.dart | CreateCollectionScreen | 1103 | да |
| lib/src/ui/learning/tabs/chat/topics/create_topic_selection_screen.dart | CreateTopicSelectionScreen | 1345 | да |
| lib/src/ui/learning/tabs/chat/topics/topic_list_review_screen.dart | TopicListReviewScreen | 1277 | да |
| lib/src/ui/learning/tabs/chat/topics/topic_options_editor_screen.dart | TopicOptionsEditorScreen | 1405 | да |
| lib/src/ui/learning/tabs/chat/topics/topic_selection_detail_screen.dart | TopicSelectionDetailScreen | 1338 | нет, требует отдельного решения |
| lib/src/ui/learning/tabs/chat/unified_task_details_screen.dart | UnifiedTaskDetailsScreen | 1879 | да |
| lib/src/ui/learning/tabs/chat_tab.dart | ChatTab | 3030 | да |
| lib/src/ui/learning/tabs/files_tab.dart | FilesTab | 874 | да |
| lib/src/ui/learning/team_details_screen.dart | TeamDetailsScreen, _MiniTab | 649 | да |
| lib/src/ui/navigation/navigation_screen.dart | NavigationScreen | 136 | да |
| lib/src/ui/navigation/visited_tab.dart | VisitedTab | 27 | да |
| lib/src/ui/notifications/notification_settings_screen.dart | NotificationSettingsScreen | 462 | да |
| lib/src/ui/profile/edit_profile_screen.dart | EditProfileScreen | 986 | да |
| lib/src/ui/profile/my_reviews_screen.dart | MyReviewsScreen | 131 | да |
| lib/src/ui/profile/personal_diary_screen.dart | PersonalDiaryScreen | 3346 | да |
| lib/src/ui/profile/profile_screen.dart | ProfileScreen, MapSpbgasuScreen | 959 | да |
| lib/src/ui/schedule/diary_entry_details_screen.dart | DiaryEntryDetailsScreen, AllConspectsGalleryScreen, AllFilesScreen | 539 | нет, требует отдельного решения |
| lib/src/ui/schedule/lesson_details_screen.dart | LessonDetailsScreen, _MapSpbgasuInlineScreen | 789 | да |
| lib/src/ui/schedule/schedule_screen.dart | ScheduleScreen, _AssignmentOpenErrorScreen | 2107 | да |
| lib/src/ui/schedule/subject_diary/screens/photo_conspect_screen.dart | SubjectPhotoConspectScreen | 278 | да |
| lib/src/ui/schedule/subject_diary/screens/quick_note_screen.dart | SubjectQuickNoteScreen | 835 | да |
| lib/src/ui/schedule/subject_diary_screen.dart | SubjectDiaryScreen, AllConspectsGalleryScreen, AllFilesScreen, AllNotesScreen | 2286 | да |
| lib/src/ui/splash/splash_screen.dart | SplashScreen | 86 | да |

## Админка

Статическая инвентаризация страниц Admin; проверка поведения — отдельные тесты.

| Файл | Классы страниц | Строк |
|---|---|---:|
| admin_console/lib/core/auth/forgot_password_screen.dart | ForgotPasswordScreen | 129 |
| admin_console/lib/core/auth/login_screen.dart | LoginScreen | 193 |
| admin_console/lib/core/auth/no_access_screen.dart | NoAccessScreen | 58 |
| admin_console/lib/core/auth/reset_password_screen.dart | ResetPasswordScreen | 158 |
| admin_console/lib/features/academic/students/students_screen.dart | StudentsScreen | 644 |
| admin_console/lib/features/academic/subjects/subject_card_editor_screen.dart | SubjectCardEditorScreen | 1123 |
| admin_console/lib/features/academic/subjects/subjects_screen.dart | SubjectsScreen | 531 |
| admin_console/lib/features/academic/teachers/teachers_screen.dart | TeachersScreen | 756 |
| admin_console/lib/features/content/home_promo/home_promo_editor_screen.dart | HomePromoEditorScreen | 2750 |
| admin_console/lib/features/content/news/news_editor_screen.dart | NewsEditorScreen | 2112 |
| admin_console/lib/features/content/profile_feed/profile_feed_editor_screen.dart | ProfileFeedEditorScreen | 2066 |
| admin_console/lib/features/content/reference/reference_editor_screen.dart | ReferenceEditorScreen | 2682 |
| admin_console/lib/features/content/vacancies/vacancy_editor_screen.dart | VacancyEditorScreen | 2124 |
| admin_console/lib/features/dashboard/dashboard_screen.dart | DashboardScreen | 236 |
| admin_console/lib/features/import_studio/import_studio_screen.dart | ImportStudioScreen | 1802 |
| admin_console/lib/features/moderation/moderation_screen.dart | ModerationScreen | 1054 |
| admin_console/lib/features/system/terms/terms_screen.dart | TermsScreen | 433 |
