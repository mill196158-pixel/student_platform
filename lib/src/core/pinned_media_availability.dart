import 'package:flutter/foundation.dart';

enum PinnedMediaAvailabilityState { idle, preparing, ready, unavailable }

/// User-visible state; no exception text, credentials or file paths are kept.
class PinnedMediaAvailability {
  static final ValueNotifier<PinnedMediaAvailabilityState> state =
      ValueNotifier(PinnedMediaAvailabilityState.idle);
  static Object? _owner;
  static VoidCallback? _retry;

  static void attach(Object owner, VoidCallback retry) {
    _owner = owner; _retry = retry; state.value = PinnedMediaAvailabilityState.preparing;
  }
  static void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null; _retry = null; state.value = PinnedMediaAvailabilityState.idle;
  }
  static void preparing(Object owner) {
    if (identical(_owner, owner)) state.value = PinnedMediaAvailabilityState.preparing;
  }
  static void unavailable(Object owner) {
    if (identical(_owner, owner)) state.value = PinnedMediaAvailabilityState.unavailable;
  }
  static void ready() {
    if (_owner != null) state.value = PinnedMediaAvailabilityState.ready;
  }
  static void retry() => _retry?.call();
}

class MediaProtectionUnavailable implements Exception {
  const MediaProtectionUnavailable();
  @override String toString() => 'Хранилище вложений недоступно';
}
