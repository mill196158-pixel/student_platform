import 'dart:async';

import 'offline_policy_grant_host.dart';
import 'offline_policy_grant.dart';

/// Capture the old identity and fence it synchronously, before logout awaits.
/// A timed-out removal continues in the store's FIFO in the background.
Future<bool> beginOfflineGrantLogout({
  required OfflinePolicyGrantAccess? access,
  required void Function() invalidate,
  Duration timeout = const Duration(seconds: 2),
}) {
  OfflineSessionBinding? binding;
  var bindingFailed = false;
  try {
    binding = access?.currentBinding();
  } catch (_) {
    bindingFailed = true;
  }
  invalidate();
  if (bindingFailed) return Future.value(false);
  if (access == null || binding == null) return Future.value(true);
  try {
    final handled = access.store.blockAndRevoke(binding).then<bool>(
          (_) => true,
          onError: (Object _, StackTrace __) => false,
        );
    return handled.timeout(timeout, onTimeout: () => false);
  } catch (_) {
    return Future.value(false);
  }
}
