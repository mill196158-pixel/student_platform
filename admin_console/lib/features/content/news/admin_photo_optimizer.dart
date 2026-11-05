import 'dart:typed_data';

import 'admin_photo_optimizer_stub.dart'
    if (dart.library.html) 'admin_photo_optimizer_web.dart' as platform;

/// Returns a smaller JPEG only when the platform can safely produce one.
/// The selected original remains intact for fallback.
Future<Uint8List?> optimizeAdminPhoto(Uint8List original) =>
    platform.optimizeAdminPhoto(original);
