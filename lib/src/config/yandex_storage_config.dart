class YandexStorageConfig {
  // Legacy/private direct S3 configuration. Flutter code must never contain or
  // expose Yandex Cloud secret keys; chat uploads use backend presigned URLs.
  static const String _accessKey = '';
  static const String _bucketName =
      String.fromEnvironment('YANDEX_STORAGE_BUCKET');
  static const String _region = String.fromEnvironment(
    'YANDEX_STORAGE_REGION',
    defaultValue: 'ru-central1',
  );
  static const String _endpoint = String.fromEnvironment(
    'YANDEX_STORAGE_ENDPOINT',
    defaultValue: 'storage.yandexcloud.net',
  );

  static String get accessKey => _accessKey;
  static String get secretKey => '';
  static String get bucketName => _bucketName;
  static String get region => _region;
  static String get endpoint => _endpoint;

  static bool get isConfigured => false;

  static String get missingConfigMessage =>
      'Direct Yandex Storage uploads are disabled in the Flutter client. '
      'Use backend-generated presigned upload URLs instead.';
}
