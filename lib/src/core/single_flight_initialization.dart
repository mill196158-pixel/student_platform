/// Share in-flight initialization; release on success or failure for retry.
class SingleFlightInitialization {
  Future<void>? _pending;
  Future<void> run(Future<void> Function() initialize) {
    final pending = _pending;
    if (pending != null) return pending;
    late final Future<void> work;
    work = Future<void>.sync(initialize).whenComplete(() {
      if (identical(_pending, work)) _pending = null;
    });
    _pending = work;
    return work;
  }
}
