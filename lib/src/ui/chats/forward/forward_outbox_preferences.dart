import 'package:shared_preferences/shared_preferences.dart';

import 'forward_outbox_store.dart';

/// SharedPreferences adapter for the versioned outbox store.
class PreferencesForwardOutboxStorage implements ForwardOutboxStorage {
  PreferencesForwardOutboxStorage(
      {Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<String?> read(String key) async =>
      (await _preferences()).getString(key);

  @override
  Future<bool> write(String key, String value) async =>
      (await _preferences()).setString(key, value);

  @override
  Future<bool> remove(String key) async => (await _preferences()).remove(key);
}
