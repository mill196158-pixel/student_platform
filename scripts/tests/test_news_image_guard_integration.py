"""Integration tests for guarded news media on a disposable LOCAL PostgreSQL.

Explicitly enabled via NEWS_GUARD_LOCAL_TEST=1. Tests connect only to
127.0.0.1:55439/codex_media_guard_test and require the fixture schema.
Never point this tool at production or an SSH tunnel.
"""
from __future__ import annotations

import concurrent.futures
import os
import subprocess
import unittest

PSQL = os.environ.get('NEWS_GUARD_TEST_PSQL', 'psql')
ENABLED = os.environ.get('NEWS_GUARD_LOCAL_TEST') == '1'
ACTOR = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
POST = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
ARCHIVE = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
OLD = 'news/dddddddd-dddd-dddd-dddd-dddddddddddd/old.jpg'
BACKUP = f'news/{ACTOR}/backup.jpg'
NEW = f'news/{ACTOR}/optimized.jpg'
ETAG_OLD = 'a' * 32
ETAG_NEW = 'b' * 32
PROMO = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
PROMO_ASSET = 'ffffffff-ffff-ffff-ffff-ffffffffffff'


def sql(code: str, *, check: bool = True):
    result = subprocess.run(
        [PSQL, '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1',
         '-h', '127.0.0.1', '-p', '55439', '-U', 'postgres',
         '-d', 'codex_media_guard_test', '-c', code],
        text=True, capture_output=True, timeout=20)
    if check and result.returncode:
        raise AssertionError(result.stderr)
    return result


def auth(write=True, publish=True):
    return ("set role authenticated; "
            f"set test.uid='{ACTOR}'; "
            f"set test.write='{int(write)}'; set test.publish='{int(publish)}'; ")


def apply_query(version=4, old=OLD, backup=BACKUP, new=NEW,
                old_tag=ETAG_OLD, new_tag=ETAG_NEW):
    return ("select public.admin_optimize_news_image_guarded("
            f"'{POST}',{version},'{old}','{backup}','{new}',"
            f"'{old_tag}',2400,'image/jpeg','{new_tag}',300)->>'run_id';")


@unittest.skipUnless(ENABLED, 'requires explicitly enabled isolated local PostgreSQL fixture')
class NewsGuardIntegration(unittest.TestCase):
    def setUp(self):
        # Refuse to reset anything unless the deliberately named test fixture exists.
        check = sql("select to_regclass('public.codex_news_guard_fixture') is not null;")
        if check.stdout.strip() != 't':
            raise RuntimeError('Dedicated test fixture marker missing; refusing writes')
        sql(f"""
          truncate public.content_item_working_drafts, public.content_assets, public.content_items,
            private.news_image_upload_reservations, private.news_image_optimization_runs, public.news_versions,
            public.test_audit, public.news_posts, storage.objects;
          insert into public.news_posts(id,status,version_number,image_path) values
            ('{POST}','published',4,'{OLD}'),('{ARCHIVE}','archived',9,'{OLD}');
          insert into public.news_versions values
            ('{ARCHIVE}',8,jsonb_build_object('image_path','{OLD}'));
          insert into storage.objects values
            ('news-media','{OLD}',jsonb_build_object('eTag','\"{ETAG_OLD}\"','size',2400,'mimetype','image/jpeg')),
            ('news-media','{BACKUP}',jsonb_build_object('eTag','\"{ETAG_OLD}\"','size',2400,'mimetype','image/jpeg')),
            ('news-media','{NEW}',jsonb_build_object('eTag','\"{ETAG_NEW}\"','size',300,'mimetype','image/jpeg'));
          insert into private.news_image_upload_reservations(actor_id,path,purpose,mime_type) values
            ('{ACTOR}','{BACKUP}','backup','image/jpeg'),
            ('{ACTOR}','{NEW}','optimized','image/jpeg');
          insert into public.content_items values ('{PROMO}','home_promo_v1','published',4,
            jsonb_build_object('image_asset_id','{PROMO_ASSET}'));
          insert into public.content_assets values ('{PROMO_ASSET}','{PROMO}','content-media','content/promo/old.png');
          insert into storage.objects values ('content-media','content/promo/old.png',jsonb_build_object('size',1115));
        """)

    def test_permissions_and_invalid_input_fail_closed(self):
        self.assertNotEqual(sql('set role anon; ' + apply_query(), check=False).returncode, 0)
        self.assertNotEqual(sql(auth(publish=False) + apply_query(), check=False).returncode, 0)
        self.assertNotEqual(sql(auth() + apply_query(version='null'), check=False).returncode, 0)
        self.assertNotEqual(sql(auth() + apply_query(new_tag='c' * 32), check=False).returncode, 0)
        self.assertEqual(sql(f"select version_number from public.news_posts where id='{POST}';").stdout.strip(), '4')
        self.assertEqual(sql('select count(*) from private.news_image_optimization_runs;').stdout.strip(), '0')

    def test_valid_apply_retains_old_history_and_protects_objects(self):
        run_id = sql(auth() + apply_query()).stdout.strip()
        self.assertTrue(run_id)
        self.assertEqual(sql(f"select image_path from public.news_posts where id='{POST}';").stdout.strip(), NEW)
        self.assertEqual(sql(f"select snapshot->>'image_path' from public.news_versions where news_post_id='{POST}' and version_number=4;").stdout.strip(), OLD)
        self.assertEqual(sql(f"select image_path from public.news_posts where id='{ARCHIVE}';").stdout.strip(), OLD)
        for path in (OLD, BACKUP, NEW):
            self.assertEqual(sql(auth() + f"select public.admin_can_delete_news_media_guarded('{path}');").stdout.strip(), 'f')
        self.assertEqual(sql(auth() + f"select public.admin_can_delete_news_media_guarded('news/{ACTOR}/orphan.jpg');").stdout.strip(), 't')
        # Even if all post/history references are removed in the fixture,
        # normal archive cleanup must still treat retained objects as in use.
        sql('delete from public.news_versions; delete from public.news_posts;')
        for path in (OLD, BACKUP, NEW):
            self.assertEqual(sql(f"select private.news_media_path_still_referenced('{path}');").stdout.strip(), 't')

    def test_rollback_requires_version_and_uses_verified_backup(self):
        run_id = sql(auth() + apply_query()).stdout.strip()
        self.assertNotEqual(sql(auth() + f"select public.admin_rollback_news_image_guarded('{run_id}',4);", check=False).returncode, 0)
        sql(f"delete from storage.objects where name='{OLD}';")
        sql(auth() + f"select public.admin_rollback_news_image_guarded('{run_id}',5);")
        self.assertEqual(sql(f"select image_path from public.news_posts where id='{POST}';").stdout.strip(), BACKUP)
        self.assertEqual(sql(f"select version_number from public.news_posts where id='{POST}';").stdout.strip(), '6')
        self.assertNotEqual(sql(auth() + f"select public.admin_rollback_news_image_guarded('{run_id}',6);", check=False).returncode, 0)

    def test_concurrent_same_version_only_one_wins(self):
        operation = 'begin; ' + auth() + apply_query() + ' select pg_sleep(0.5); commit;'
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: sql(operation, check=False), range(2)))
        self.assertEqual(sorted(r.returncode == 0 for r in results), [False, True])
        self.assertEqual(sql('select count(*) from private.news_image_optimization_runs;').stdout.strip(), '1')
        self.assertEqual(sql(f"select version_number from public.news_posts where id='{POST}';").stdout.strip(), '5')

    def test_changed_or_missing_backup_refuses_without_modifying_post(self):
        sql(f"update storage.objects set metadata=jsonb_set(metadata,'{{size}}','1') where name='{BACKUP}';")
        self.assertNotEqual(sql(auth() + apply_query(), check=False).returncode, 0)
        self.assertEqual(sql(f"select image_path from public.news_posts where id='{POST}';").stdout.strip(), OLD)
        self.assertEqual(sql('select count(*) from private.news_image_optimization_runs;').stdout.strip(), '0')

    def test_reservation_blocks_delete_before_upload_or_switch_and_can_be_released(self):
        self.assertEqual(sql(auth() + f"select public.admin_can_delete_news_media_guarded('{BACKUP}');").stdout.strip(), 'f')
        reservation = sql(f"select id from private.news_image_upload_reservations where path='{BACKUP}';").stdout.strip()
        sql(auth() + f"select public.admin_release_news_optimization_upload('{reservation}');")
        self.assertEqual(sql(auth() + f"select public.admin_can_delete_news_media_guarded('{BACKUP}');").stdout.strip(), 't')
        self.assertNotEqual(sql(auth() + apply_query(), check=False).returncode, 0)
        self.assertEqual(sql(f"select image_path from public.news_posts where id='{POST}';").stdout.strip(), OLD)

    def test_new_reservation_requires_both_permissions_and_protects_path(self):
        command = "select public.admin_reserve_news_optimization_upload('optimized','image/jpeg');"
        self.assertNotEqual(sql(auth(publish=False) + command, check=False).returncode, 0)
        self.assertNotEqual(sql(auth() + "select public.admin_reserve_news_optimization_upload('optimized','image/png');", check=False).returncode, 0)
        result = sql(auth() + command).stdout.strip()
        self.assertTrue(result)
        reservation = sql(f"select id from private.news_image_upload_reservations where actor_id='{ACTOR}' and path not in ('{BACKUP}','{NEW}') order by created_at desc limit 1;").stdout.strip()
        path = sql(f"select path from private.news_image_upload_reservations where id='{reservation}';").stdout.strip()
        self.assertTrue(path.startswith(f'news/{ACTOR}/'))
        self.assertEqual(sql(auth() + f"select public.admin_can_delete_news_media_guarded('{path}');").stdout.strip(), 'f')
        foreign = auth().replace(ACTOR, str(ARCHIVE))
        self.assertNotEqual(sql(foreign + f"select public.admin_release_news_optimization_upload('{reservation}');", check=False).returncode, 0)
        sql(auth() + f"select public.admin_release_news_optimization_upload('{reservation}');")
        self.assertEqual(sql(auth() + f"select public.admin_can_delete_news_media_guarded('{path}');").stdout.strip(), 't')

    def test_promo_rejects_existing_draft_and_changed_version_without_modifying_draft(self):
        sql(f"insert into public.content_item_working_drafts(content_item_id,base_canonical_row_version,payload,row_version,created_by) values ('{PROMO}',4,'{{\"untouched\":true}}',7,'{ARCHIVE}');")
        command = auth() + f"select public.admin_begin_home_promo_image_optimization('{PROMO}',4,'{PROMO_ASSET}');"
        self.assertNotEqual(sql(command, check=False).returncode, 0)
        self.assertEqual(sql(f"select payload->>'untouched' from public.content_item_working_drafts where content_item_id='{PROMO}';").stdout.strip(), 'true')
        sql('delete from public.content_item_working_drafts;')
        self.assertNotEqual(sql(auth() + f"select public.admin_begin_home_promo_image_optimization('{PROMO}',3,'{PROMO_ASSET}');", check=False).returncode, 0)
        self.assertEqual(sql('select count(*) from public.content_item_working_drafts;').stdout.strip(), '0')

    def test_promo_concurrent_begins_do_not_reuse_an_existing_draft(self):
        operation = ('begin; ' + auth() +
          f"select public.admin_begin_home_promo_image_optimization('{PROMO}',4,'{PROMO_ASSET}');" +
          ' select pg_sleep(0.5); commit;')
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: sql(operation, check=False), range(2)))
        self.assertEqual(sorted(r.returncode == 0 for r in results), [False, True])
        self.assertEqual(sql('select count(*) from public.content_item_working_drafts;').stdout.strip(), '1')
        self.assertEqual(sql(f"select payload->>'image_asset_id' from public.content_items where id='{PROMO}';").stdout.strip(), PROMO_ASSET)


if __name__ == '__main__':
    unittest.main()
