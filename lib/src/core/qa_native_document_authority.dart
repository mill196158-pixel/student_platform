import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/durable_active_session_registry.dart';
import 'package:student_platform/src/core/qa_document_authority_host.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';

/// QA-only adapter. The channel is registered natively only in the separate
/// authorityqa Android package, against that FlutterEngine object.
class QaNativeDocumentAuthorityDriver implements QaNativeDocumentAuthority {
  QaNativeDocumentAuthorityDriver(this.db,this.owner,{MethodChannel? channel})
      : _channel=channel ?? const MethodChannel('student_platform/document_authority_qa');
  final Database db;
  final ProjectDatabaseOwnerCapability owner;
  final MethodChannel _channel;
  bool _registered=false;
  String? _recoveredTicket, _recoveredInstance;
  int? _recoveredRevision;

  /// Read-only QA preflight. Native chooses its own canonical databases and
  /// owner; the returned digest is not an authorization to export or dispatch.
  Future<String?> verifySource(SourceAttachmentIdentity source) async {
    if (!source.valid || !owner.isCurrentFor(db)) return null;
    try {
      final digest=await _channel.invokeMethod<String>('verifySource',{
        'project':source.project,'uid':source.uid,'sid':source.sid,
        'chat':source.chatId,'message':source.messageId,'file':source.fileId,
        'key':source.fileKey,'url':source.fileUrl,
      });
      if (!owner.isCurrentFor(db) || digest==null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) return null;
      return digest;
    } catch (_) { return null; }
  }

  /// Experimental native handoff. A non-started/unknown outcome is never
  /// replayed by this adapter and must not fall back to a local export.
  Future<String> dispatchSource(SourceAttachmentIdentity source,String request) async {
    if (!source.valid || !owner.isCurrentFor(db) || !RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(request)) return 'blocked';
    try {
      final value=await _channel.invokeMethod<String>('dispatchSource',{
        'project':source.project,'uid':source.uid,'sid':source.sid,
        'chat':source.chatId,'message':source.messageId,'file':source.fileId,
        'key':source.fileKey,'url':source.fileUrl,'request':request,
      });
      return value=='started' ? 'started' : value=='blocked' ? 'blocked' : 'uncertain';
    } catch (_) { return 'uncertain'; }
  }

  bool _ensureBarrier() {
    if (_registered) return true;
    if (!registerQaNativeCloseBarrier(db,owner,() async {
      try { return await _channel.invokeMethod<bool>('close') == true; } catch (_) { return false; }
    })) return false;
    _registered=true;
    return true;
  }

  /// Recovers only from a native-proven dead old pair of OS leases. Native
  /// always leaves document authority closed; a cache permit is still needed.
  Future<bool> recoverClosed(String project,String uid,String sid,ActiveSessionSnapshot old) async {
    if (!_ensureBarrier() || !owner.isCurrentFor(db) || old.state!='active' || old.uid!=uid || old.sid!=sid) return false;
    try {
      final ticket=await _channel.invokeMethod<String>('recoverClosed',{'project':project,'uid':uid,'sid':sid,
        'instance':old.instance,'revision':old.revision});
      if (ticket==null) return false;
      if (!owner.isCurrentFor(db)) { await _channel.invokeMethod<bool>('close',{'ticket':ticket}); return false; }
      _recoveredTicket=ticket; _recoveredInstance=old.instance; _recoveredRevision=old.revision+1;
      return true;
    } catch (_) { return false; }
  }

  @override
  Future<Object?> captureClosed(String project,String uid,String sid,ActiveSessionSnapshot snapshot) async {
    if (!_ensureBarrier()) return null;
    final token=owner.tokenFor(db);
    if (token==null || snapshot.state!='active' || snapshot.uid!=uid || snapshot.sid!=sid) return null;
    final recovered=_recoveredTicket;
    if (recovered!=null) {
      if (_recoveredInstance!=snapshot.instance || _recoveredRevision!=snapshot.revision) return null;
      _recoveredTicket=null;
      return recovered;
    }
    try {
      final ticket=await _channel.invokeMethod<String>('captureClosed',{'project':project,'uid':uid,'sid':sid,
        'instance':snapshot.instance,'revision':snapshot.revision,'guard':token});
      if (ticket==null) return null;
      if (!owner.isCurrentFor(db)) { await _channel.invokeMethod<bool>('close',{'ticket':ticket}); return null; }
      return ticket;
    } catch (_) { return null; }
  }

  @override
  Future<bool> admit(Object ticket,ActiveSessionSnapshot snapshot) async {
    if (ticket is! String || !owner.isCurrentFor(db)) return false;
    try {
      final ok=await _channel.invokeMethod<bool>('admit',{'ticket':ticket,'instance':snapshot.instance,'revision':snapshot.revision}) == true;
      if (!owner.isCurrentFor(db)) { await _channel.invokeMethod<bool>('close',{'ticket':ticket}); return false; }
      return ok;
    } catch (_) { return false; }
  }

  @override
  Future<bool> abandon(Object ticket) async {
    if (ticket is! String) return false;
    try { return await _channel.invokeMethod<bool>('close',{'ticket':ticket}) == true; } catch (_) { return false; }
  }
}
