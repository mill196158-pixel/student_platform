import 'package:http/http.dart' as http;

/// Security failures must never be classified as a transport outage.
class RefreshSecurityFenceException extends http.ClientException {
  RefreshSecurityFenceException() : super('Refresh security fence unavailable');
}

/// GoTrue wraps transport exceptions and loses their type. A caller considering
/// offline admission must capture this revision before refresh and check it
/// afterwards as well as validating the durable grant and current owner.
class RefreshSecurityFence {
  int _revision = 0;
  int get revision => _revision;
  bool unchangedSince(int revision) => revision == _revision;
  Never reject() {
    _revision++;
    throw RefreshSecurityFenceException();
  }
}
