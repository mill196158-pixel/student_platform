# Local verification for guarded content-image switching

These steps do **not** deploy or publish anything. Run against a disposable
PostgreSQL cluster only, never the connected project. The scripts require
Python with Pillow, Node.js and the official Deno npm package.

The integration tests connect **only** to `127.0.0.1:55439`, database
`codex_media_guard_test`, and refuse to reset a database without the explicit
fixture marker. Do not forward that port to any remote host.

Example on this Windows machine, from the repository root, with a **new**
empty directory for a disposable cluster (choose a fresh path if it exists):

```powershell
$pgBin = 'C:\Program Files\PostgreSQL\16\bin'
$testCluster = 'C:\Users\mill4\.codex\worktrees\product-design\student_platform\design_preview\optimizer_qa\pg_local16'
& "$pgBin\initdb.exe" -D $testCluster -A trust -U postgres --encoding=UTF8 --no-locale
& "$pgBin\pg_ctl.exe" -D $testCluster -l "$testCluster.log" -o '-p 55439 -h 127.0.0.1' start
& "$pgBin\createdb.exe" -h 127.0.0.1 -p 55439 -U postgres codex_media_guard_test
& "$pgBin\psql.exe" -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 55439 -U postgres -d codex_media_guard_test -f scripts/tests/news_guard_fixture.sql -f scripts/tests/promo_guard_fixture.sql -f supabase/migrations/20261106015413_news_image_guarded_optimization.sql
$env:NEWS_GUARD_LOCAL_TEST = '1'
$env:NEWS_GUARD_TEST_PSQL = "$pgBin\psql.exe"
python -m unittest discover -s scripts/tests -p test_news_image_guard_integration.py -v
```

If using the already-created disposable cluster at `$testCluster`, skip the
`initdb`, `createdb` and fixture commands and start it with the `pg_ctl` line.
Always stop that local cluster after testing, without deleting its files:

```powershell
& "$pgBin\pg_ctl.exe" -D $testCluster -m fast stop
```

Other reproducible checks:

```powershell
python -m unittest discover -s scripts/tests -p test_prepare_content_image_bundle.py -v
node --test scripts/tests/optimized_news_switch.test.mjs scripts/tests/optimized_promo_switch.test.mjs
npx --yes deno@2.5.2 test supabase/functions/news-media/delete_guard_test.ts
npx --yes deno@2.5.2 check supabase/functions/news-media/index.ts supabase/functions/news-media/delete_guard_test.ts
```

`prepare_content_image_bundle.py` produces a new local directory, copies the
original bytes and hashes, and writes smaller safe JPEG derivatives. It never
uploads or changes the source files. The manifest explicitly says
`NOT_PUBLISHED`; users must not confuse bundle creation with publication.

The operator scripts require a live **user** access token with `content.read`,
`content.write` and `content.publish`, plus the project's publishable/anon key.
They reject `service_role` and project URLs other than this specific project.
They default to preflight; even preflight calls the audited admin-get RPC and
thus writes an audit record. `--apply` may only follow review, verification of
backups and authorization for the specific live change. Both scripts' `--apply`
require a new exclusive local `--journal` path; journal records are synced before
each mutation and never contain credentials or signed URLs. A timeout after a write is an uncertain
outcome: inspect the journal, canonical post, and
`admin_find_news_image_optimization` or `admin_list_my_news_optimization_uploads`;
never blindly replay. For promo, run `node scripts/optimized_promo_switch.mjs
--plan plan.json --recover` with the same authorized session, then compare the
canonical item, working draft, asset IDs and downloaded SHA-256 values with the
journal. Recovery performs no content mutation, but the admin-get RPC records an
audit event. If an intent creation or finalize response was lost, unbound
intents/objects may require operator inspection beyond this report. No automatic
replay or discard is safe. Promo failures leave the draft alone. On rollback, use the guarded versioned RPC for
news and a fresh exclusive working draft with the prior asset ID for promo.

For this rollout the Edge delete action unconditionally returns `ok:false,
retained:true` and never calls Storage remove. A reference check followed by
remove is unsafe even for an apparently orphaned file. Deploy an updated admin
client that understands `retained` before the changed Edge; old clients otherwise
misreport retained files as deleted. The updated client reports archive removal
with retained file and does not enqueue a retry; draft replacement remains best
effort. Existing queued jobs and any independent privileged cleanup workers must
be inspected and disabled or adjusted before rollout: this code does not control
such workers. Then deploy the changed `news-media` Edge function with both
`index.ts` and `delete_guard.ts` and apply only the reviewed single migration.
Do not run optimization until each step has been reviewed and verified.
Originals and backups remain; this is not an archive migration.
