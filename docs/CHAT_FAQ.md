### Chat module FAQ and implementation guide

This document captures the changes, decisions, and gotchas implemented in the Learning → Chat over the last session. Use it to avoid regressions and to understand how the features are wired end-to-end.

**Last updated**: Added swipe-to-close for fullscreen images, improved draft persistence, fixed message deletion, default chat tab, pin navigation, reduced haptic feedback. Fixed draft file loss, keyboard hiding, and scroll position issues.

### Scope

- Chat bubbles (text, single-file with caption, multi-file)
- Message deletion (server + optimistic UI)
- Scrolling behavior (start at bottom, smoothness)
- Keyboard behavior (hide on send, hide on tap)
- Reply navigation (tap replied preview → scroll to original)
- Date separators (hide empty)
- Local caching (files + drafts) persisted across app restarts and login/logout
- Haptic feedback on bottom navigation (Android + iOS)

### Implemented features

- **Single-file message with caption**:
  - Time is shown once, inline with the caption, aligned to the bubble edge (Telegram-like).
  - Time is not duplicated under the file preview.
  - Images open fullscreen; non-images download to local temp and open with the system app.

- **Multi-file message bubble**:
  - Text color fixed to `Colors.black87` for readability.
  - Each file item is clickable and opens (image fullscreen, docs via local download + `open_filex`).
  - Long-press triggers the same message actions (e.g., delete) as single bubbles.

- **Message deletion**:
  - Optimistic UI removal in `TeamCubit.removeMessage`.
  - Server deletion via `LearningRepository.deleteMessage` implemented in `SupabaseLearningRepository`.
  - Deletes both message and associated files from `chat_files` table.
  - Reverts local state if server deletion fails.

- **Reply navigation**:
  - Tapping the replied preview scrolls to the original message using `_scrollToMessage(messageId)` with `animateTo`.
  - No snackbars on jump; keeps UX clean.

- **Scrolling behavior**:
  - Chat starts at the very bottom using post-frame callback to `_jumpToBottom()`.
  - Removed `initialScrollOffset` to prevent opening at top of chat.
  - Smooth scrolling to bottom on initialization.

- **Keyboard behavior**:
  - Keyboard hides on send (`FocusScope.of(context).unfocus()`).
  - Keyboard hides when tapping anywhere on the chat area (wrapping `ListView` with `GestureDetector`).

- **Date separators**:
  - Empty date separators are hidden.

- **Local caching (persistent)**:
  - Introduced `GlobalCache` singleton for app-wide cache of `ChatFile` objects and chat drafts.
  - Persistence via `shared_preferences` (files + drafts survive app restarts and login/logout).
  - Caching logic checks cache before DB and skips re-downloads; verbose logs for verification.

- **Draft persistence**:
  - Draft text and attached files are saved per chat when typing (with 300ms debounce) and on focus loss.
  - Drafts are restored on opening the chat, even after leaving the module or app relaunch.
  - Forced save on dispose, focus loss, and tap outside to prevent data loss.
  - Files are copied before sending to prevent race conditions.
  - Verbose logging for draft save/restore operations.

- **Performance and rebuilds**:
  - Removed redundant `TeamCubit.init()` calls on send.
  - Replaced async date grouping with synchronous `_buildMessagesWithDatesSync` to avoid constant refresh.
  - Added `buildWhen` to `BlocBuilder` to rebuild only when relevant slices change (chat/team/assignments).
  - Reduced unnecessary `setState` calls in handlers (typing, reactions, uploads, send, reply, scroll).

- **Haptic feedback (navigation tabs)**:
  - Light haptic on real tab change only (30ms duration, reduced by 40%).
  - Android: `VIBRATE` permission, `vibration` plugin.
  - iOS: Haptics enabled with usage description in `Info.plist`; iOS deployment target 13.0.

- **Fullscreen image viewer**:
  - Swipe down gesture closes the viewer and returns to chat (negative velocity check).
  - Gallery support with page navigation.
  - Download functionality for current image.

- **Default tab behavior**:
  - Team details screen opens with chat tab selected (index 1).
  - Chat is the primary interface for team communication.

- **Pin navigation**:
  - When pinning a message, automatically scrolls to that message.
  - Same smooth scrolling logic as reply navigation.

### Key files

- `lib/src/ui/learning/tabs/chat/file_message_bubble.dart` — single-file bubble, caption + time on one line, open handlers.
- `lib/src/ui/learning/tabs/chat/multi_file_bubble.dart` — multi-file bubble, text color, clickable items, long-press actions.
- `lib/src/ui/learning/tabs/chat/message_bubble.dart` — `onReplyTap` support for jump to original.
- `lib/src/ui/learning/tabs/chat_tab.dart` — scroll, keyboard, drafts, caching usage, optimized rebuilds, reply navigation.
- `lib/src/ui/learning/global_cache.dart` — global persistent cache (files + drafts) using `shared_preferences`.
- `lib/src/ui/learning/data/learning_repository.dart` — `deleteMessage` contract.
- `lib/src/ui/learning/data/supabase_learning_repository.dart` — server delete implementation.
- `lib/main.dart` — `await GlobalCache().initialize()` on startup.
- `lib/src/ui/navigation/navigation_screen.dart` — haptic feedback on tab change (`vibration` plugin).
- Android: `android/app/src/main/AndroidManifest.xml` — `VIBRATE` permission.
- iOS: `ios/Runner/Info.plist` — `NSHapticFeedbackUsageDescription`.
- iOS: `ios/Podfile` — `platform :ios, '13.0'` and no manual pod for vibration.

### Dependencies and versions

- `shared_preferences` — persistent storage for cache/drafts.
- `http`, `path_provider`, `open_filex` — download + open files locally.
- `vibration` — haptic feedback; use `>= 3.0.0` to avoid v1 embedding issues.

### Initialization and usage

- **Global cache**
  - In `main.dart` before `runApp`: `await GlobalCache().initialize()`.
  - Use `GlobalCache` for:
    - `cacheFile(fileId, ChatFile)` / `getFile(fileId)`
    - `saveDraft(chatId, text, files)` / `getDraft(chatId)` / `clearDraft(chatId)`
  - Files and drafts are saved immediately to `SharedPreferences`.

- **Chat screen**
  - `ScrollController(initialScrollOffset: 9999999)` to start at bottom.
  - Wrap the messages `ListView` with `GestureDetector` to hide keyboard on tap.
  - On send: unfocus to hide keyboard; avoid re-init of cubit.
  - Reply preview: call `_scrollToMessage(originalMessageId)`.

- **Bubbles**
  - Single-file: show caption + time in one line; do not duplicate time under file.
  - Multi-file: each item is tappable; long-press bubble for actions.

### Testing checklist

- **Deletion**
  - Long-press any bubble (single/multi) → delete → disappears instantly.
  - Confirm the message does not reappear after server sync.
  - Verify that associated files are also removed from the chat.

- **Fullscreen image viewer**
  - Swipe down gesture closes viewer and returns to chat.
  - Gallery navigation works for multi-image messages.

- **Draft persistence**
  - Type text and attach files → leave chat → return → draft restored.
  - Draft saves with 300ms debounce during typing.
  - Files are preserved when sending messages quickly after restoring draft.

- **Default tab behavior**
  - Enter team details → chat tab opens by default.

- **Pin navigation**
  - Pin a message → automatically scrolls to that message.

- **Single-file caption**
  - Send image/doc with text → caption + time on one line; no duplicate time below preview.

- **Multi-file**
  - Tap each file: images open fullscreen; docs download once and open locally.
  - Long-press triggers message actions.

- **Reply navigation**
  - Tap reply preview → smooth scroll to the original message.

- **Scrolling**
  - Open chat → immediately at the bottom; no opening at top.

- **Keyboard**
  - After sending → keyboard hides.
  - Tap empty area → keyboard hides.

- **Caching**
  - Re-enter chat or app → files should be loaded from cache (logs show "🎯/📦/⏭️"), drafts restored.

- **Haptics**
  - Switch tabs → light vibration once per actual tab change (30ms duration).

### Troubleshooting

- **Android build error (plugin v1 embedding / Registrar not found)**
  - Cause: old `vibration` version (e.g., 1.9.0).
  - Fix: set `vibration: ">=3.0.0"` in `pubspec.yaml`, then `flutter clean && flutter pub get`.

- **CocoaPods: higher minimum deployment target required**
  - Error mentions `Flutter` pod requires higher target.
  - Fix: in `ios/Podfile`, set `platform :ios, '13.0'` and ensure `IPHONEOS_DEPLOYMENT_TARGET = 13.0` in build settings loop; then:
    - `cd ios && pod repo update && pod install --repo-update`
  - Do not add `pod 'Vibration'` manually; Flutter manages plugin pods.

- **Podspec not found for Vibration**
  - Remove any manual `pod 'Vibration'` entries from `Podfile`.
  - Rely on Flutter plugin symlinks.

- **Emulator audio errors (pcm_writei failed / I/O)**
  - Benign on some emulators; unrelated to chat features and can be ignored.

- **Chat starts at top or jerks on open**
  - Remove `initialScrollOffset` and use post-frame `_jumpToBottom()`.
  - Ensure smooth scrolling to bottom on initialization.

- **Stateless widget context usage**
  - `MultiFileBubble` is `StatelessWidget`; pass `BuildContext context` into helpers, don’t access `context` as a getter.

- **Parentheses or syntax errors**
  - Ensure matching parentheses around `Row/Column/Widget` trees.

### Pending / Backlog

- **Multi-select attachments** when attaching via paperclip (currently single-select).

### Conventions and best practices

- Keep emoji-prefixed logs for cache hits/misses; they help verify behavior quickly.
- Avoid triggering `TeamCubit.init()` on send to prevent unnecessary rebuilds.
- Use `buildWhen` generously to scope rebuilds to relevant state changes.
- Save drafts on text change and on composer focus loss.

### Useful commands

```bash
# Refresh Dart deps
flutter pub get

# Clean build caches if plugin versions changed
flutter clean && flutter pub get

# iOS (on macOS)
cd ios && pod repo update && pod install --repo-update

# Run
flutter run
```



