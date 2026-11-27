import 'dart:async';
import 'dart:developer';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Opt-in timing for one Home visit or refresh. No payload or account data.
final class HomeFrameTrace {
  HomeFrameTrace()
      : _operation = enabled ? ++_nextOperation : 0,
        _clock = enabled ? (Stopwatch()..start()) : null;

  static const enabled = bool.fromEnvironment('HOME_FRAME_TRACE') ||
      bool.fromEnvironment('STARTUP_TRACE');
  static int _nextOperation = 0;
  static const _suppliedRevision = String.fromEnvironment('BUILD_REVISION');
  static final _revision = RegExp(r'^[0-9a-f]{40}$').hasMatch(_suppliedRevision)
      ? _suppliedRevision
      : 'unavailable';

  final int _operation;
  final Stopwatch? _clock;

  void mark(String event, {Map<String, int> counts = const {}}) {
    final clock = _clock;
    if (clock == null) return;
    final fields = <String, Object>{
      ...counts,
      'operation': _operation,
      'elapsed_us': clock.elapsedMicroseconds,
      'mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'revision': _revision,
    };
    Timeline.instantSync('Home/$event', arguments: fields);
    debugPrintSynchronously(
      '[home-frame] $event ${fields.entries.map((field) => '${field.key}=${field.value}').join(' ')}',
    );
  }

  /// Call after committing the frame, or while building the newly visible UI.
  /// Uses the engine frame number to match the raster report, which can arrive
  /// later in a batch. The presentation on the device is checked on video.
  void markNextRaster(String event, {bool Function()? current}) {
    if (!enabled) return;
    final binding = SchedulerBinding.instance;
    int? frame;
    var listening = true;
    late final TimingsCallback report;
    late final Timer deadline;
    void stop() {
      listening = false;
      binding.removeTimingsCallback(report);
      deadline.cancel();
    }

    report = (timings) {
      final visibleFrame = frame;
      if (visibleFrame == null) return;
      for (final timing in timings) {
        if (timing.frameNumber != visibleFrame) continue;
        stop();
        mark('${event}_raster', counts: {
          'frame': visibleFrame,
          'build_us': timing.buildDuration.inMicroseconds,
          'raster_us': timing.rasterDuration.inMicroseconds,
          'raster_wall_us': timing.timestampInMicroseconds(
            FramePhase.rasterFinishWallTime,
          ),
        });
        break;
      }
    };
    deadline = Timer(const Duration(seconds: 5), () {
      stop();
      if (current?.call() != false) {
        mark('${event}_raster_unavailable', counts: {'frame': frame ?? -1});
      }
    });
    binding.addTimingsCallback(report);

    binding.addPostFrameCallback((_) {
      if (!listening) return;
      if (current?.call() == false) {
        stop();
        return;
      }
      final visibleFrame = binding.platformDispatcher.frameData.frameNumber;
      frame = visibleFrame;
      mark('${event}_paint', counts: {'frame': visibleFrame});
    });
  }
}
