class YandexStorageConfig {
  // Данные Yandex Object Storage
  static const String _accessKey = 'YOUR_ACCESS_KEY';
  static const String _secretKey = 'YOUR_SECRET_KEY';
  static const String _bucketName = 'YOUR_BUCKET_NAME';
  static const String _region = 'ru-central1';
  static const String _endpoint = 'storage.yandexcloud.net';

  static String get accessKey => _accessKey;
  static String get secretKey => _secretKey;
  static String get bucketName => _bucketName;
  static String get region => _region;
  static String get endpoint => _endpoint;

  // Проверка конфигурации
  static bool get isConfigured {
    return _accessKey != 'YOUR_ACCESS_KEY' && 
           _secretKey != 'YOUR_SECRET_KEY' && 
           _bucketName != 'YOUR_BUCKET_NAME';
  }
}
