import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/news/news_item.dart';
import 'package:student_platform_admin/features/content/news/news_repository.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  test('toPatchJson never includes audience fields', () {
    final item = NewsItem(
      id: 'n1',
      title: 'T',
      subtitle: 'S',
      variant: StudentHomeNewsVariant.gradientText,
      colors: const [Color(0xFF111111), Color(0xFF222222)],
      audienceType: NewsAudienceType.group,
      audienceGroupId: 'g1',
      audienceMode: NewsAudienceMode.groups,
      audienceGroupIds: const ['g1', 'g2'],
    );
    final patch = item.toPatchJson();
    expect(patch.containsKey('audience_type'), isFalse);
    expect(patch.containsKey('audience_group_id'), isFalse);
    expect(patch.containsKey('audience_mode'), isFalse);
  });

  test('LocalNewsRepository setAudience supports multi-group mode', () async {
    final repo = LocalNewsRepository();
    final created = await repo.createDraft(title: 'A', subtitle: 'B');
    final updated = await repo.setAudience(
      id: created.id,
      mode: NewsAudienceMode.groups,
      groupIds: const [
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
      ],
      expectedVersion: created.versionNumber,
    );
    expect(updated.audienceMode, NewsAudienceMode.groups);
    expect(updated.audienceGroupIds, hasLength(2));
    expect(updated.audienceType, NewsAudienceType.group);
    expect(updated.audienceGroupId, startsWith('11111111'));

    final preview = await repo.previewAudience(updated.id);
    expect(preview.recipientCount, greaterThan(0));
    expect(preview.groupCount, 2);
  });

  test('NewsAudiencePreview parses breakdown.groups', () {
    final preview = NewsAudiencePreview.fromJson({
      'recipient_count': 12,
      'audience_mode': 'groups',
      'breakdown': {
        'groups': [
          {'id': 'g1', 'name': 'A', 'member_count': 5},
          {'id': 'g2', 'name': 'B', 'member_count': 7},
        ],
        'explicit_users_count': 3,
      },
    });
    expect(preview.recipientCount, 12);
    expect(preview.groupCount, 2);
    expect(preview.explicitUserCount, 3);
  });

  test('fromJson infers legacy single-group mode', () {
    final item = NewsItem.fromJson({
      'id': 'n1',
      'title': 'T',
      'subtitle': 'S',
      'body': '',
      'variant': 'gradientText',
      'gradient_colors': ['#111111', '#222222'],
      'status': 'draft',
      'audience_type': 'group',
      'audience_group_id': 'g-legacy',
      'version_number': 1,
    });
    expect(item.audienceMode, NewsAudienceMode.groups);
    expect(item.audienceGroupIds, ['g-legacy']);
  });

  test('fromJson reads normalized audience arrays', () {
    final item = NewsItem.fromJson({
      'id': 'n1',
      'title': 'T',
      'subtitle': 'S',
      'body': '',
      'variant': 'gradientText',
      'gradient_colors': ['#111111', '#222222'],
      'status': 'draft',
      'audience_type': 'group',
      'audience_group_id': 'g1',
      'audience_mode': 'groups_and_users',
      'audience_group_ids': ['g1', 'g2'],
      'audience_user_ids': ['u1'],
      'version_number': 3,
    });
    expect(item.audienceMode, NewsAudienceMode.groupsAndUsers);
    expect(item.audienceGroupIds, ['g1', 'g2']);
    expect(item.audienceUserIds, ['u1']);
    expect(item.usesNormalizedAudience, isTrue);
  });
}
