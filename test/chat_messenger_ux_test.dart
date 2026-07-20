import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/message_receipt.dart';

void main() {
  group('normalizeDmTitle', () {
    test('maps empty and legacy technical titles to Пользователь', () {
      expect(normalizeDmTitle(null), kDmTitleFallback);
      expect(normalizeDmTitle(''), kDmTitleFallback);
      expect(normalizeDmTitle('   '), kDmTitleFallback);
      expect(normalizeDmTitle('Личный чат'), kDmTitleFallback);
      expect(normalizeDmTitle('Анна С.'), 'Анна С.');
    });

    test('unresolved detects placeholders that need peer hydrate', () {
      expect(isUnresolvedDmTitle(null), isTrue);
      expect(isUnresolvedDmTitle('Личный чат'), isTrue);
      expect(isUnresolvedDmTitle('Пользователь'), isTrue);
      expect(isUnresolvedDmTitle('Иван'), isFalse);
    });
  });

  group('dmReceiptTicks / formatMessageTimeLabel', () {
    final at = DateTime.utc(2026, 7, 20, 12, 0, 0);

    test('sending shows clock marker without ticks', () {
      expect(
        dmReceiptTicks(
          isMine: true,
          enableDmReceipts: true,
          messageAt: at,
          peerLastReadAt: at.add(const Duration(minutes: 1)),
          isSending: true,
          isFailed: false,
        ),
        0,
      );
      expect(
        formatMessageTimeLabel(
          time: '15:04',
          isMe: true,
          receiptTicks: 0,
          isSending: true,
        ),
        '15:04 ◌',
      );
    });

    test('delivered and read use compact ticks next to time', () {
      expect(
        dmReceiptTicks(
          isMine: true,
          enableDmReceipts: true,
          messageAt: at,
          peerLastReadAt: null,
          isSending: false,
          isFailed: false,
        ),
        1,
      );
      expect(
        dmReceiptTicks(
          isMine: true,
          enableDmReceipts: true,
          messageAt: at,
          peerLastReadAt: at,
          isSending: false,
          isFailed: false,
        ),
        2,
      );
      expect(
        formatMessageTimeLabel(
          time: '15:04',
          isMe: true,
          receiptTicks: 1,
        ),
        '15:04 ✓',
      );
      expect(
        formatMessageTimeLabel(
          time: '15:04',
          isMe: true,
          receiptTicks: 2,
        ),
        '15:04 ✓✓',
      );
    });

    test('failed keeps stable time without ticks', () {
      expect(
        dmReceiptTicks(
          isMine: true,
          enableDmReceipts: true,
          messageAt: at,
          peerLastReadAt: at,
          isSending: false,
          isFailed: true,
        ),
        0,
      );
      expect(
        formatMessageTimeLabel(
          time: '15:04',
          isMe: true,
          receiptTicks: 0,
        ),
        '15:04',
      );
    });

    test('peer messages never show ticks', () {
      expect(
        dmReceiptTicks(
          isMine: false,
          enableDmReceipts: true,
          messageAt: at,
          peerLastReadAt: at,
          isSending: false,
          isFailed: false,
        ),
        isNull,
      );
      expect(
        formatMessageTimeLabel(time: '15:04', isMe: false, receiptTicks: 2),
        '15:04',
      );
    });
  });
}
