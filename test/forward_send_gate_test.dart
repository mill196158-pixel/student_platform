import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/forward/forward_send_gate.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';

LocalAttach file(String localId, {String? id, bool uploaded = false}) =>
    LocalAttach(
        localId: localId,
        path: '/$localId',
        name: localId,
        mimeType: 'application/pdf',
        size: 4,
        isImage: false,
        uploadedFileId: id,
        uploadStatus: uploaded
            ? LocalAttachUploadStatus.uploaded
            : LocalAttachUploadStatus.uploading);

Message message(String id,
        {List<ChatFile>? files,
        MessageType type = MessageType.text,
        String? fileId,
        List<String> outboundFileIds = const []}) => Message(
    id: id,
    chatId: 'chat',
    authorId: 'a',
    authorLogin: 'a',
    authorName: 'A',
    text: 'hello',
    at: DateTime.utc(2026),
    type: type,
    fileId: fileId,
    outboundFileIds: outboundFileIds,
    attachments: files);
ChatFile attachment(
        {String id = 'id', String url = 'https://example.test/file'}) =>
    ChatFile(
        id: id,
        chatId: 'chat',
        messageId: 'm',
        fileName: 'a.pdf',
        fileKey: 'key',
        fileUrl: url,
        fileType: 'application/pdf',
        fileSize: 5,
        uploadedBy: 'a',
        uploadedAt: DateTime.utc(2026));
ForwardPayload payload(List<ForwardFileRef> files) =>
    ForwardPayload(fromChatId: 'chat', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: '',
          files: files)
    ]);

void main() {
  test('group: one unfinished attachment prevents send and keeps draft',
      () async {
    final first = file('one', id: 'id-one', uploaded: true);
    final second = file('two');
    final pending = [first, second];
    var sends = 0;
    final sent = await sendPreparedForwardIfComplete(
        requiredFiles: List.of(pending),
        currentFiles: pending,
        stagedFileIds: [],
        expectedForwardFileIds: {'id-one', 'id-two'},
        isCurrent: () => true,
        send: (_) async {
          sends++;
        });
    expect(sent, isFalse);
    expect(sends, 0);
    expect(pending, [first, second]);
  });
  test('DM: a removed required file cannot produce an incomplete send',
      () async {
    final first = file('one', id: 'id-one', uploaded: true),
        second = file('two', id: 'id-two', uploaded: true);
    var sends = 0;
    final sent = await sendPreparedForwardIfComplete(
        requiredFiles: [first, second],
        currentFiles: [first],
        stagedFileIds: [],
        expectedForwardFileIds: {'id-one', 'id-two'},
        isCurrent: () => true,
        send: (_) async {
          sends++;
        });
    expect(sent, isFalse);
    expect(sends, 0);
  });
  test('missing prepared ID blocks even if no local file remains', () async {
    var sends = 0;
    final sent = await sendPreparedForwardIfComplete(
        requiredFiles: [],
        currentFiles: [],
        stagedFileIds: [],
        expectedForwardFileIds: {'id-one'},
        isCurrent: () => true,
        send: (_) async {
          sends++;
        });
    expect(sent, isFalse);
    expect(sends, 0);
  });
  test('complete uploads send their IDs once', () async {
    final first = file('one', id: 'id-one', uploaded: true),
        second = file('two', id: 'id-two', uploaded: true);
    List<String>? output;
    final sent = await sendPreparedForwardIfComplete(
        requiredFiles: [first, second],
        currentFiles: [first, second],
        stagedFileIds: ['id-one'],
        expectedForwardFileIds: {'id-one', 'id-two'},
        isCurrent: () => true,
        send: (ids) async {
          output = ids;
        });
    expect(sent, isTrue);
    expect(output!.toSet(), {'id-one', 'id-two'});
  });
  test('ordinary text-only forward remains sendable', () async {
    var calls = 0;
    final sent = await sendPreparedForwardIfComplete(
        requiredFiles: [],
        currentFiles: [],
        stagedFileIds: [],
        expectedForwardFileIds: {},
        isCurrent: () => true,
        send: (ids) async {
          expect(ids, isEmpty);
          calls++;
        });
    expect(sent, isTrue);
    expect(calls, 1);
  });
  test('late session or target cancellation cannot send or clear', () async {
    final f = file('one', id: 'id-one', uploaded: true);
    var sends = 0;
    var draft = 'keep';
    final result = await sendPreparedForwardIfComplete(
        requiredFiles: [f],
        currentFiles: [f],
        stagedFileIds: [],
        expectedForwardFileIds: {'id-one'},
        isCurrent: () => false,
        send: (_) async {
          sends++;
          draft = '';
        });
    expect(result, isFalse);
    expect(sends, 0);
    expect(draft, 'keep');
  });
  test('DM selected messages and attachment metadata must be complete', () {
    expect(completeForwardSelection(['one', 'two'], [message('one')]), isNull);
    expect(
        completeForwardSelection([
          'one'
        ], [
          message('one', files: [attachment(url: '')])
        ]),
        isNull);
    expect(
        completeForwardSelection([
          'one'
        ], [
          message('one', files: [attachment(id: '')])
        ]),
        isNull);
    expect(
        completeForwardSelection([
          'one'
        ], [
          message('one', files: [attachment()])
        ]),
        hasLength(1));
  });
  test('file messages require all known attachments before selection', () {
    for (final incomplete in [
      message('one', type: MessageType.file),
      message('one', fileId: 'missing'),
      message('one', files: [attachment()], outboundFileIds: ['id', 'missing']),
    ]) {
      expect(completeForwardSelection(['one'], [incomplete]), isNull);
    }
    expect(
        completeForwardSelection(['one'], [
          message('one', type: MessageType.file, fileId: 'id',
              outboundFileIds: ['id'], files: [attachment()])
        ]),
        hasLength(1));
  });
  test('selection snapshot rejects later changes to file references', () {
    final initial = message('one');
    final snapshot = ForwardSelectionSnapshot([initial]);
    expect(snapshot.matches([message('one', fileId: 'missing')]), isFalse);
    expect(snapshot.matches([message('one', type: MessageType.file)]), isFalse);
  });
  test('ID-only or mismatched handoff cannot become text-only forward', () {
    expect(forwardSourceReferencesComplete(payload([]), ['file-id']), isFalse);
    final ref = ForwardFileRef(
        id: 'file-id',
        url: 'https://example.test/file',
        name: 'a',
        type: 'application/pdf',
        size: 5);
    expect(
        forwardSourceReferencesComplete(payload([ref]), ['other-id']), isFalse);
    expect(
        forwardSourceReferencesComplete(payload([ref]), ['file-id']), isTrue);
  });
  for (final chatType in ['team', 'DM']) {
    test('$chatType send completion cannot clear later attachments', () async {
      final first = file('one', id: 'id-one', uploaded: true);
      final pending = [first];
      final initial = ForwardAttachmentSnapshot(pending);
      ForwardAttachmentSnapshot? sentState;
      final started = Completer<void>(), finish = Completer<void>();
      var forwardAttached = true;
      var text = 'old draft';
      const sentText = 'old draft';
      bool current() =>
          initial.sameFiles(pending) && (sentState?.sameState(pending) ?? true);
      final send = sendPreparedForwardIfComplete(
          requiredFiles: [first],
          currentFiles: pending,
          stagedFileIds: [],
          expectedForwardFileIds: {'id-one'},
          isCurrent: current,
          send: (_) async {
            sentState = ForwardAttachmentSnapshot(pending);
            started.complete();
            await finish.future;
          });
      await started.future;
      pending.add(file('new', id: 'id-new', uploaded: true));
      text = 'new draft';
      finish.complete();
      final sent = await send;
      if (sent) {
        pending.removeWhere(sentState!.containsUnchanged);
        if (text == sentText) text = '';
        forwardAttached = false;
      }
      expect(forwardAttached, isFalse);
      expect(text, 'new draft');
      expect(pending.map((item) => item.localId), ['new']);
    });
  }
  test('malformed nested forward and excessive depth are rejected', () {
    ForwardPayload wrap(String text) =>
        ForwardPayload(fromChatId: 'chat', items: [
          ForwardItem(
              messageId: 'm',
              authorId: 'a',
              authorName: 'A',
              at: DateTime.utc(2026),
              text: text,
              files: [])
        ]);
    expect(
        forwardSourceReferencesComplete(wrap('__FG__:{broken'), []), isFalse);
    final good = wrap('plain').encodeForText();
    expect(forwardSourceReferencesComplete(wrap(good), []), isTrue);
    var deep = good;
    for (var i = 0; i < 10; i++) {
      deep = wrap(deep).encodeForText();
    }
    expect(forwardSourceReferencesComplete(wrap(deep), []), isFalse);
  });
  for (final chatType in ['team', 'DM']) {
    test('$chatType confirmed same-chat forward keeps newer draft and reply',
        () {
      final cleanup = confirmedForwardCleanup(
          sentText: 'old',
          currentText: 'new',
          sentReplyId: 'old-reply',
          currentReplyId: 'new-reply');
      expect(cleanup.clearText, isFalse);
      expect(cleanup.clearReply, isFalse);
      final unchanged = confirmedForwardCleanup(
          sentText: 'old',
          currentText: 'old',
          sentReplyId: 'old-reply',
          currentReplyId: 'old-reply');
      expect(unchanged.clearText, isTrue);
      expect(unchanged.clearReply, isTrue);
    });
  }
  test(
      'same-chat rejects malformed nested forward but accepts valid old payload',
      () {
    final corrupt = message('one').copyWith(text: '__FG__:{broken');
    expect(completeForwardSelection(['one'], [corrupt]), isNull);
    final valid = message('one').copyWith(text: payload([]).encodeForText());
    expect(completeForwardSelection(['one'], [valid]), hasLength(1));
  });
  for (final chatType in ['team', 'DM']) {
    test('$chatType late lookup rejects changed same-ID message and attachment',
        () async {
      final initial = message('one', files: [attachment()]);
      var messages = [initial];
      final selected = completeForwardSelection(['one'], messages)!;
      final snapshot = ForwardSelectionSnapshot(selected);
      final lookup = Completer<void>();
      var sends = 0;
      Future<void> afterLookup() async {
        await lookup.future;
        if (!snapshot.matches(messages)) return;
        sends++;
      }

      final operation = afterLookup();
      messages = [initial.copyWith(text: 'edited')];
      lookup.complete();
      await operation;
      expect(sends, 0);
      expect(
          snapshot.matches([
            initial.copyWith(
                attachments: [attachment(url: 'https://example.test/changed')])
          ]),
          isFalse);
      expect(
          snapshot.matches([
            message('one', files: [attachment()])
          ]),
          isTrue);
    });
  }
}
