// Shared across JPEG and alpha codecs to bound parallel browser memory use.
bool _busy = false;

bool acquireAdminImageWorker() {
  if (_busy) return false;
  _busy = true;
  return true;
}

void releaseAdminImageWorker() { _busy = false; }
