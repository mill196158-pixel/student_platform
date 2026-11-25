import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeSocketSink implements WebSocketSink {
  _FakeSocketSink(this.controller);
  final StreamController<dynamic> controller;
  @override
  void add(dynamic data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      controller.close();
  @override
  Future<void> get done => controller.done;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Keeps routing tests independent of live Realtime and WebSocket ping timers.
class InMemoryRealtimeSocket implements WebSocketChannel {
  final StreamController<dynamic> controller =
      StreamController<dynamic>.broadcast();
  late final _FakeSocketSink output = _FakeSocketSink(controller);
  @override
  Stream<dynamic> get stream => controller.stream;
  @override
  WebSocketSink get sink => output;
  @override
  Future<void> get ready async {}
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
