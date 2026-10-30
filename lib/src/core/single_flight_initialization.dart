/// Share in-flight initialization; release on success or failure for retry.
class SingleFlightInitialization {
  Future<void>? _pending;
  Future<void> run(Future<void> Function() initialize, {Future<void>? after}) {
    final pending = _pending;
    if (pending != null) return pending;
    late final Future<void> work;
    work = (after == null
            ? Future<void>.sync(initialize)
            : after.then((_) => initialize()))
        .whenComplete(() {
      if (identical(_pending, work)) _pending = null;
    });
    _pending = work;
    return work;
  }
}
