import 'package:flutter/services.dart';
import 'dart:io';

/// QA-only handle for a native-created guard. The native handler ties this
/// token to the calling FlutterEngine and retains the actual OS lock.
class QaNativeProjectGuard {
  QaNativeProjectGuard._(this._channel,this.token,this._canonicalPath);
  final MethodChannel _channel;
  final String token;
  final String _canonicalPath;
  bool _released=false;
  bool _claimed=false;
  bool get isCurrent => !_released;

  static Future<QaNativeProjectGuard?> acquire({MethodChannel? channel}) async {
    final bound=channel ?? const MethodChannel('student_platform/document_authority_qa');
    try {
      final result=await bound.invokeMapMethod<String,dynamic>('createGuard');
      final token=result?['guard'], path=result?['path'];
      return token is! String || token.isEmpty || path is! String || path.isEmpty
          ? null : QaNativeProjectGuard._(bound,token,path);
    } catch (_) { return null; }
  }

  Future<bool> claimForPath(String path) async {
    if (_released || _claimed) return false;
    try {
      final canonical=await File(path).resolveSymbolicLinks();
      final native=await File(_canonicalPath).resolveSymbolicLinks();
      if (_released || _claimed || canonical!=native) return false;
      _claimed=true;
      return true;
    } catch (_) { return false; }
  }

  Future<bool> release() async {
    if (_released) return true;
    try {
      final ok=await _channel.invokeMethod<bool>('releaseGuard',{'guard':token}) == true;
      if (ok) _released=true;
      return ok;
    } catch (_) { return false; }
  }
}
