# Серверные функции, вызываемые приложением

Статический поиск литералов .rpc в lib и CREATE FUNCTION в локальных SQL.
Отсутствие определения — пробел исходников, не доказательство отсутствия функции в production.
Наличие SQL не доказывает применённую миграцию или правильность функции.

| RPC | Определение в SQL | Клиентские файлы |
|---|---|---|
| accept_friend_request | Есть | lib/src/ui/friends/friend_profile_screen.dart, lib/src/ui/friends/my_friends_screen.dart |
| add_subject_diary_entry | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart |
| add_subject_diary_file | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart |
| add_topic_option | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| add_topic_option_with_version | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| block_user | Есть | lib/src/ui/chats/data/blocks_api.dart |
| cancel_friend_request | Есть | lib/src/ui/friends/friend_profile_screen.dart |
| cancel_topic_pick | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| close_topic_selection | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| confirm_collection_contribution | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| content_resolve_chat_cta | Есть | lib/src/ui/content/content_nav_executor.dart |
| create_group_collection | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| create_topic_selection | Есть | lib/src/ui/group_space/data/group_space_repository.dart |
| decline_friend_request | Есть | lib/src/ui/friends/friend_profile_screen.dart, lib/src/ui/friends/my_friends_screen.dart |
| delete_group_action | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| delete_subject_diary_entry | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart |
| disable_device_push_token | Есть | lib/src/services/push/push_notification_service.dart |
| dismiss_content_item | Есть | lib/src/ui/home/home_promo_service.dart |
| edit_own_message | Есть | lib/src/ui/chats/data/dm_api.dart, lib/src/ui/learning/data/supabase_learning_repository.dart |
| ensure_dm_chat | Есть | lib/src/ui/chats/data/dm_api.dart |
| ensure_group_space | Есть | lib/src/ui/group_space/data/group_space_repository.dart |
| get_block_relationship | Есть | lib/src/ui/chats/data/blocks_api.dart |
| get_chat_action_cards_batch | Есть | lib/src/ui/learning/tabs/chat/data/chat_action_cards_cache.dart |
| get_chat_composer_capabilities | Есть | lib/src/ui/learning/tabs/chat/data/chat_composer_capabilities_repository.dart |
| get_chat_messages_for_team | Есть | lib/src/ui/learning/data/supabase_learning_repository.dart |
| get_chat_messages_page | Есть | lib/src/ui/chats/data/dm_api.dart, lib/src/ui/learning/data/supabase_learning_repository.dart |
| get_collection_proof_file | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| get_entity_review_summary | Есть | lib/src/ui/profile/student_review_service.dart |
| get_my_app_notifications | Есть | lib/src/services/push/app_notifications_api.dart |
| get_my_archived_chat_summaries | Есть | lib/src/ui/chats/data/chat_archive_api.dart |
| get_my_blocked_user_ids | Есть | lib/src/ui/chats/data/blocks_api.dart |
| get_my_chat_summaries | Есть | lib/src/ui/chats/data/chat_warm_coordinator.dart, lib/src/ui/chats/my_chats_screen.dart |
| get_my_classmates | Есть | lib/src/ui/friends/my_friends_screen.dart |
| get_my_content_for_placement | Есть | lib/src/ui/home/home_promo_service.dart, lib/src/ui/profile/profile_feed_service.dart |
| get_my_entity_reviews | Есть | lib/src/ui/profile/student_review_service.dart |
| get_my_friends_bulk | Есть | lib/src/ui/friends/my_friends_screen.dart |
| get_my_group_space | Есть | lib/src/ui/group_space/data/group_space_repository.dart |
| get_my_incoming_friend_requests | Есть | lib/src/ui/friends/my_friends_screen.dart |
| get_my_lessons | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart, lib/src/ui/schedule/schedule_screen.dart |
| get_my_notification_preferences | Есть | lib/src/services/push/notification_preferences_api.dart |
| get_my_points_summary | Есть | lib/src/ui/profile/student_points_service.dart |
| get_my_profile | **Не найдено** | lib/src/core/session.dart, lib/src/ui/authentication/screens/login_screen.dart, lib/src/ui/friends/my_friends_screen.dart, lib/src/ui/home/home_dashboard_service.dart |
| get_my_published_news | Есть | lib/src/ui/home/home_dashboard_service.dart |
| get_my_reference_bundle | Есть | lib/src/ui/info/reference_service.dart |
| get_my_subject_diary | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart |
| get_my_team_organizer_state | Есть | lib/src/ui/learning/state/team_cubit.dart |
| get_my_teams | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart, lib/src/ui/learning/data/supabase_learning_repository.dart |
| get_my_unread_notification_count | Есть | lib/src/services/push/app_notifications_api.dart |
| get_my_vacancies | Есть | lib/src/ui/info/vacancy_service.dart |
| get_my_vacancy_submissions | Есть | lib/src/ui/info/vacancy_submission_service.dart |
| get_profile_counters | **Не найдено** | lib/src/ui/profile/profile_screen.dart |
| get_published_teacher | Есть | lib/src/ui/info/teacher_profile_screen.dart |
| get_subject_diary_files | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart |
| get_task_details | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| get_team_assignments | Есть | lib/src/ui/learning/data/supabase_learning_repository.dart |
| get_team_chat_notice | Есть | lib/src/ui/learning/tabs/chat/team/team_chat_notice.dart |
| get_team_members_directory | Есть | lib/src/ui/learning/tabs/chat/team/team_chat_notice.dart |
| get_unread_in_chat | **Не найдено** | lib/src/ui/chats/core/dm_chat_service.dart, lib/src/ui/chats/data/dm_api.dart, lib/src/ui/chats/my_chats_screen.dart, lib/src/ui/learning/tabs/chat/data/chat_repository.dart |
| get_unread_meta | **Не найдено** | lib/src/ui/chats/core/dm_chat_service.dart |
| get_user_friends_preview | Есть | lib/src/ui/friends/friend_profile_screen.dart |
| get_user_profile | Есть | lib/src/services/push/push_navigation.dart, lib/src/ui/chats/data/dm_api.dart, lib/src/ui/friends/friend_profile_screen.dart, lib/src/ui/learning/data/supabase_learning_repository.dart |
| get_vacancy_contacts | Есть | lib/src/ui/info/vacancy_service.dart |
| group_action_can_delete | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| hide_notification_for_me | Есть | lib/src/services/push/app_notifications_api.dart |
| hide_personal_chat_for_me | Есть | lib/src/ui/chats/data/chat_archive_api.dart |
| join_team_by_code | **Не найдено** | lib/src/ui/learning/data/supabase_learning_repository.dart |
| list_collection_contribution_progress | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| list_group_collections | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/assignments_tab.dart, lib/src/ui/learning/tabs/chat/data/chat_action_cards_cache.dart, lib/src/ui/learning/tabs/chat/unified_task_details_screen.dart |
| list_my_group_action_deadlines | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| list_team_members_directory | Есть | lib/src/ui/learning/tabs/chat/team/team_chat_notice.dart |
| list_topic_options_for_selection | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| list_topic_selections | Есть | lib/src/ui/group_space/data/group_space_repository.dart |
| list_topic_selections_for_chat | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| mark_all_notifications_read | Есть | lib/src/services/push/app_notifications_api.dart |
| mark_chat_read | **Не найдено** | lib/src/ui/chats/core/dm_chat_service.dart, lib/src/ui/chats/my_chats_screen.dart, lib/src/ui/learning/tabs/chat/data/chat_repository.dart |
| mark_news_seen | Есть | lib/src/ui/home/home_dashboard_service.dart |
| mark_notification_read | Есть | lib/src/services/push/app_notifications_api.dart |
| pick_topic | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| pin_message | Есть | lib/src/ui/chats/data/dm_api.dart, lib/src/ui/learning/data/supabase_learning_repository.dart |
| propose_assignment | Есть | lib/src/ui/learning/state/team_cubit.dart |
| publish_assignment | Есть | lib/src/ui/learning/state/team_cubit.dart |
| publish_topic_selection_for_chat | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| reassign_topic_pick | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| record_content_event | Есть | lib/src/ui/home/home_promo_service.dart, lib/src/ui/profile/profile_feed_service.dart |
| register_device_push_token | Есть | lib/src/services/push/push_notification_service.dart |
| release_topic_pick | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| remove_assignment | **Не найдено** | lib/src/ui/learning/state/team_cubit.dart |
| remove_friend | Есть | lib/src/ui/friends/friend_profile_screen.dart |
| remove_subject_diary_file | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart |
| remove_topic_option | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| reorder_topic_options | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| report_vacancy | Есть | lib/src/ui/info/vacancy_service.dart |
| resubmit_my_vacancy | Есть | lib/src/ui/info/vacancy_submission_service.dart |
| rpc_get_my_subjects_v2 | Есть | lib/src/ui/exams/exams_screen.dart, lib/src/ui/info/subject_info_screen.dart, lib/src/ui/info/teacher_profile_screen.dart, lib/src/ui/info/useful_subjects_repository.dart |
| rpc_vote_subject_difficulty_v2 | Есть | lib/src/ui/exams/exams_screen.dart, lib/src/ui/info/subject_info_screen.dart |
| save_chat_file | **Не найдено** | lib/src/ui/learning/tabs/chat/attachments/chat_attachments_controller.dart, lib/src/ui/learning/tabs/chat/data/chat_repository.dart, lib/src/ui/learning/tabs/files_tab.dart |
| search_users_global | Есть | lib/src/ui/friends/my_friends_screen.dart |
| send_chat_message | **Не найдено** | lib/src/ui/learning/data/supabase_learning_repository.dart |
| send_chat_message_with_files | Есть | lib/src/ui/learning/tabs/chat/data/chat_repository.dart, lib/src/ui/learning/tabs/files_tab.dart |
| send_friend_request | Есть | lib/src/ui/friends/friend_profile_screen.dart |
| send_message_in_chat_with_files | **Не найдено** | lib/src/ui/chats/data/dm_api.dart |
| set_assignment_done | **Не найдено** | lib/src/data/personal_diary_service.dart, lib/src/ui/home/home_dashboard_service.dart, lib/src/ui/learning/state/team_cubit.dart |
| set_personal_chat_archived | Есть | lib/src/ui/chats/data/chat_archive_api.dart |
| submit_content_correction | Есть | lib/src/ui/info/reference_service.dart |
| submit_my_entity_review | Есть | lib/src/ui/profile/student_review_service.dart |
| submit_vacancy | Есть | lib/src/ui/info/vacancy_submission_service.dart |
| toggle_message_reaction | **Не найдено** | lib/src/ui/chats/data/dm_api.dart, lib/src/ui/learning/tabs/chat/data/chat_repository.dart |
| touch_my_presence | Есть | lib/src/services/presence/user_presence.dart |
| unblock_user | Есть | lib/src/ui/chats/data/blocks_api.dart |
| unread_total | **Не найдено** | lib/src/ui/profile/profile_screen.dart |
| update_assignment | **Не найдено** | lib/src/ui/learning/state/team_cubit.dart |
| update_group_collection_deadline | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| update_group_collection_status | Есть | lib/src/ui/group_space/data/group_space_repository.dart |
| update_my_notification_preferences | Есть | lib/src/services/push/notification_preferences_api.dart |
| update_my_vacancy_draft | Есть | lib/src/ui/info/vacancy_submission_service.dart |
| update_subject_diary_text | **Не найдено** | lib/src/data/subject_diary_repository_supabase.dart |
| update_topic_option | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| update_topic_selection | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| update_topic_selection_before_activity | Есть | lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| upsert_my_collection_contribution | Есть | lib/src/ui/group_space/data/group_space_repository.dart, lib/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart |
| upsert_my_entity_review | Есть | lib/src/ui/profile/student_review_service.dart |
| upsert_team_chat_notice | Есть | lib/src/ui/learning/tabs/chat/team/team_chat_notice.dart |
| vote_assignment | Есть | lib/src/ui/learning/state/team_cubit.dart |
