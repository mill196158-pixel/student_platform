package com.mill453020.studentplatform;

import android.content.Context;
import android.content.ContextWrapper;
import android.database.sqlite.SQLiteDatabase;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;
import java.util.Arrays;

/** Synthetic fixture only. Invoke exclusively from an isolated test APK. */
final class NewsPrivateStoreFactoryFixture {
    private static final String SCHEMA = "CREATE TABLE news_quota_custody (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, token TEXT NOT NULL, root TEXT NOT NULL)";

    static void run(Context context) throws Exception {
        final Path sandbox = context.getCacheDir().toPath().resolve("news_factory_fixture_" + UUID.randomUUID());
        Files.createDirectory(sandbox);
        final Context synthetic = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return sandbox.toFile(); }
        };
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "missing root admitted");
        final Path root = sandbox.resolve("news_quota_v1");
        Files.createDirectory(root);
        Files.createDirectory(root.resolve("blobs"));
        Files.createFile(root.resolve("lease.lock"));
        final String token = "v1:" + new String(new char[64]).replace('\0', 'a');
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token, true);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token, false);
        final NewsPrivateStoreFactory factory = NewsPrivateStoreFactory.openExisting(synthetic);
        require(factory != null, "valid fixture rejected");
        final NewsPrivateStoreFactory.ReadTicket missing = factory.capture("missing");
        require(missing != null && factory.read(missing).state == NewsPrivateStoreFactory.ReadState.MISS, "missing image not a miss");
        final NewsPrivateStoreFactory.ReadTicket saved = factory.capture("saved");
        require(saved != null && factory.read(saved).state == NewsPrivateStoreFactory.ReadState.HIT &&
                Arrays.equals(factory.read(saved).bytes, new byte[] {1, 2, 3}), "saved image unavailable");
        final Path image = root.resolve("blobs").resolve(new String(new char[64]).replace('\0', 'a') + ".bin");
        Files.write(image, new byte[] {7, 8, 9});
        require(factory.read(saved).state == NewsPrivateStoreFactory.ReadState.UNKNOWN, "corrupt image returned");
        Files.write(image, new byte[] {1, 2, 3});
        setGeneration(root.resolve("index.db"), 1L);
        require(factory.read(saved).state == NewsPrivateStoreFactory.ReadState.UNKNOWN, "stale ticket accepted");
        final NewsPrivateStoreFactory.ReadTicket refreshed = factory.capture("saved");
        require(refreshed != null && factory.read(refreshed).state == NewsPrivateStoreFactory.ReadState.HIT, "fresh ticket rejected");
        require(factory.beginFetch("new") == null, "ordinary factory mutated without profile");
        require(pathGeneration(root.resolve("index.db"), "new") == 0, "ordinary path mutated");
        final NewsPrivateStoreFactory low = NewsPrivateStoreFactory.openForMutationTesting(synthetic, 1L);
        require(low != null && low.beginFetch("new") == null, "low budget admitted mutation");
        require(low.read(refreshed).state == NewsPrivateStoreFactory.ReadState.HIT, "low budget blocked existing read");
        final NewsPrivateStoreFactory writable = NewsPrivateStoreFactory.openForMutationTesting(synthetic, 200L * 1024L * 1024L);
        require(writable != null && writable.beginFetch("new") != null, "test beginFetch rejected");
        require(writable.beginFetch("new") != null && pathGeneration(root.resolve("index.db"), "new") == 2L, "path generation did not advance");
        final NewsPrivateStoreFactory.WriteTicket olderWrite = writable.beginFetch("upload");
        final NewsPrivateStoreFactory.WriteTicket currentWrite = writable.beginFetch("upload");
        require(olderWrite != null && currentWrite != null, "write tickets missing");
        require(factory.putForMutationTesting(currentWrite, new byte[] {4, 5}) == NewsPrivateStoreFactory.PutResult.SKIPPED && holdCount(root.resolve("ledger.db")) == 0, "ordinary factory wrote without profile");
        require(writable.putForMutationTesting(olderWrite, new byte[] {4, 5}) == NewsPrivateStoreFactory.PutResult.SKIPPED, "old write ticket accepted");
        require(holdCount(root.resolve("ledger.db")) == 0, "stale write created hold");
        require(writable.putForMutationTesting(currentWrite, new byte[] {4, 5}) == NewsPrivateStoreFactory.PutResult.CONFIRMED_HELD, "synthetic put failed");
        require(holdCount(root.resolve("ledger.db")) == 1, "synthetic successful hold lost");
        require(writable.putForMutationTesting(currentWrite, new byte[] {6, 7}) == NewsPrivateStoreFactory.PutResult.SKIPPED, "write ticket replay accepted");
        require(holdCount(root.resolve("ledger.db")) == 1, "replay created extra hold");
        final NewsPrivateStoreFactory.WriteTicket foreignTicket = writable.beginFetch("foreign");
        require(foreignTicket != null, "foreign ticket unavailable");
        checkForeignTicket(context, foreignTicket);
        final NewsPrivateStoreFactory.ReadTicket uploaded = writable.capture("upload");
        require(uploaded != null && writable.read(uploaded).state == NewsPrivateStoreFactory.ReadState.HIT &&
                Arrays.equals(writable.read(uploaded).bytes, new byte[] {4, 5}), "synthetic uploaded bytes unavailable");
        final long physical = fixtureBytes(root);
        final NewsPrivateStoreFactory heldBudget = NewsPrivateStoreFactory.openForMutationTesting(synthetic, physical + 100L * 1024L * 1024L);
        require(heldBudget != null && heldBudget.beginFetch("must-count-held") == null, "retained hold was not charged");
        require(heldBudget.read(uploaded).state == NewsPrivateStoreFactory.ReadState.HIT, "held budget blocked existing read");
        checkDelayedPut(synthetic, root, writable);
        for (String stage : new String[] {"afterHold", "afterTemp", "afterRename", "afterDirSync", "afterIndex"}) {
            final String key = "fault-" + stage;
            final NewsPrivateStoreFactory.WriteTicket baseline = writable.beginFetch(key);
            require(baseline != null && writable.putForMutationTesting(baseline, new byte[] {1, 1}) == NewsPrivateStoreFactory.PutResult.CONFIRMED_HELD, "fault baseline missing");
            final long before = holdCount(root.resolve("ledger.db"));
            final long beforeFiles = blobCount(root);
            final NewsPrivateStoreFactory fault = NewsPrivateStoreFactory.openForMutationTesting(synthetic,
                    200L * 1024L * 1024L, null, name -> { if (stage.equals(name)) throw new IllegalStateException("synthetic stage failure"); });
            require(fault != null, "fault factory unavailable");
            final NewsPrivateStoreFactory.WriteTicket faultTicket = fault.beginFetch(key);
            require(faultTicket != null, "fault ticket unavailable");
            require(fault.putForMutationTesting(faultTicket, new byte[] {3, 1, 4}) == NewsPrivateStoreFactory.PutResult.UNCERTAIN, "fault did not report uncertain");
            require(holdCount(root.resolve("ledger.db")) == before + 1, "fault released durable hold");
            final NewsPrivateStoreFactory.ReadTicket after = writable.capture(key);
            final byte[] expected = stage.equals("afterIndex") ? new byte[] {3, 1, 4} : new byte[] {1, 1};
            require(after != null && writable.read(after).state == NewsPrivateStoreFactory.ReadState.HIT &&
                    Arrays.equals(writable.read(after).bytes, expected), "fault damaged same-key indexed version");
            require(blobCount(root) == beforeFiles + (stage.equals("afterHold") ? 0 : 1), "fault evidence missing");
            if (stage.equals("afterIndex")) {
                require(fault.putForMutationTesting(faultTicket, new byte[] {6}) == NewsPrivateStoreFactory.PutResult.SKIPPED, "committed ticket replay accepted");
                require(holdCount(root.resolve("ledger.db")) == before + 1, "committed replay created hold");
            }
        }
        final String collisionName = new String(new char[64]).replace('\0', 'f');
        final Path collision = root.resolve("blobs").resolve(collisionName + ".bin");
        Files.write(collision, new byte[] {9, 9});
        final NewsPrivateStoreFactory collisionFactory = NewsPrivateStoreFactory.openForMutationTesting(synthetic,
                200L * 1024L * 1024L, null, new NewsPrivateStoreFactory.PutHook() {
                    @Override public void stage(String name) {}
                    @Override public String blobName() { return collisionName; }
                });
        require(collisionFactory != null, "collision factory unavailable");
        final NewsPrivateStoreFactory.WriteTicket collisionTicket = collisionFactory.beginFetch("collision");
        require(collisionTicket != null && collisionFactory.putForMutationTesting(collisionTicket, new byte[] {4}) == NewsPrivateStoreFactory.PutResult.UNCERTAIN, "collision was not uncertain");
        require(Arrays.equals(Files.readAllBytes(collision), new byte[] {9, 9}), "collision target overwritten");
        setGeneration(root.resolve("index.db"), Long.MAX_VALUE);
        final NewsPrivateStoreFactory.ReadTicket saturatedRead = writable.capture("saved");
        require(saturatedRead != null && writable.read(saturatedRead).state == NewsPrivateStoreFactory.ReadState.HIT, "saturated generation blocked read");
        require(writable.beginFetch("global-full") == null && pathGeneration(root.resolve("index.db"), "global-full") == 0, "saturated global generation mutated");
        setGeneration(root.resolve("index.db"), 1L);
        setPathGeneration(root.resolve("index.db"), "path-full", Long.MAX_VALUE);
        require(writable.beginFetch("path-full") == null && pathGeneration(root.resolve("index.db"), "path-full") == Long.MAX_VALUE, "saturated path generation mutated");
        final Path unknown = root.resolve("protected-unknown");
        Files.write(unknown, new byte[] {9, 8, 7});
        require(writable.beginFetch("unknown") == null && pathGeneration(root.resolve("index.db"), "unknown") == 0, "unknown file admitted mutation");
        require(Arrays.equals(Files.readAllBytes(unknown), new byte[] {9, 8, 7}), "unknown file modified");
        Files.delete(unknown);
        Files.write(root.resolve("marker"), ("v1:" + new String(new char[64]).replace('\0', 'b')).getBytes(StandardCharsets.US_ASCII));
        require(factory.read(refreshed).state == NewsPrivateStoreFactory.ReadState.UNKNOWN, "foreign marker accepted");
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        require(!hasLocaleMetadata(root.resolve("index.db")), "validation added locale metadata");
        require(!hasLocaleMetadata(root.resolve("ledger.db")), "validation added locale metadata");
        setVersion(root.resolve("index.db"), 4294967297L);
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "truncated version admitted");
        setVersion(root.resolve("index.db"), "invalid");
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "text version admitted");
        setVersion(root.resolve("index.db"), 1L);
        require(NewsPrivateStoreFactory.openExisting(synthetic) != null, "valid restored version rejected");
        final Path index = root.resolve("index.db");
        final byte[] original = Files.readAllBytes(index);
        final byte[] walHeader = original.clone();
        walHeader[18] = 2;
        walHeader[19] = 2;
        Files.write(index, walHeader);
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "WAL header admitted");
        require(Arrays.equals(Files.readAllBytes(index), walHeader), "WAL header converted");
        Files.write(index, original);
        require(NewsPrivateStoreFactory.openExisting(synthetic) != null, "valid restored WAL header rejected");
        final byte[] shortHeader = new byte[] {1, 2, 3};
        Files.write(index, shortHeader);
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "short header admitted");
        require(Arrays.equals(Files.readAllBytes(index), shortHeader), "short header modified");
        Files.write(index, original);
        require(NewsPrivateStoreFactory.openExisting(synthetic) != null, "valid restored short header rejected");
        Files.write(root.resolve("marker"), "invalid".getBytes(StandardCharsets.US_ASCII));
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "bad marker admitted");
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        require(NewsPrivateStoreFactory.openExisting(synthetic) != null, "valid restored marker rejected");
        Files.createFile(root.resolve("index.db-wal"));
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "unexpected WAL admitted");
        Files.delete(root.resolve("index.db-wal"));
        require(NewsPrivateStoreFactory.openExisting(synthetic) != null, "valid removed WAL rejected");
        final Path ledger = root.resolve("ledger.db");
        final byte[] goodLedger = Files.readAllBytes(ledger);
        final byte[] corrupt = goodLedger.clone();
        corrupt[100] = (byte) 0xff; // Valid SQLite header; invalid first B-tree page.
        Files.write(root.resolve("ledger.db"), corrupt);
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "corrupt DB admitted");
        require(Arrays.equals(Files.readAllBytes(root.resolve("ledger.db")), corrupt), "corrupt DB modified or deleted");
        Files.write(ledger, goodLedger);
        require(NewsPrivateStoreFactory.openExisting(synthetic) != null, "valid restored ledger rejected");
        Files.delete(root.resolve("lease.lock"));
        require(NewsPrivateStoreFactory.openExisting(synthetic) == null, "missing lock admitted");
        require(!Files.exists(root.resolve("lease.lock")), "lock recreated");
        checkUnsettledClose(context);
        checkMutationCloseFailure(context);
        checkSqliteFull(context);
        checkPutFull(context, true);
        checkPutFull(context, false);
        checkLogicalClear(context);
        checkClearFailureCases(context);
        checkClearObserverTimeout(context, "clearAfterHold");
        checkClearObserverTimeout(context, "clearAfterCommit");
        checkRunnerQueuedFence(context);
    }

    private static void checkRunnerQueuedFence(Context context) throws Exception {
        final SyntheticRoot a = newSyntheticRoot(context), b = newSyntheticRoot(context);
        final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), proceed = new java.util.concurrent.CountDownLatch(1);
        final NewsPrivateStoreFactory blocker = NewsPrivateStoreFactory.openForMutationTesting(a.context,
                200L * 1024L * 1024L, null, stage -> { if ("clearAfterHold".equals(stage)) { entered.countDown(); proceed.await(); } });
        final NewsPrivateStoreFactory queued = NewsPrivateStoreFactory.openForMutationTesting(b.context, 200L * 1024L * 1024L);
        require(blocker != null && queued != null, "queued fence fixtures unavailable");
        final NewsPrivateStoreFactory.ReadTicket old = queued.capture("saved");
        require(old != null && queued.read(old).state == NewsPrivateStoreFactory.ReadState.HIT, "queued fence baseline missing");
        final java.util.concurrent.ExecutorService observer = java.util.concurrent.Executors.newSingleThreadExecutor();
        try {
            final java.util.concurrent.Future<NewsPrivateStoreFactory.ClearResult> active = observer.submit(() -> NewsQuotaOperationRunner.clear(blocker, 200));
            require(entered.await(5, java.util.concurrent.TimeUnit.SECONDS), "blocking worker did not enter");
            require(NewsQuotaOperationRunner.clear(queued, 30) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "queued clear did not expire");
            require(queued.read(old).state == NewsPrivateStoreFactory.ReadState.UNKNOWN && queued.capture("saved") == null, "queued clear failed to block immediately");
            require(holdCount(b.root.resolve("ledger.db")) == 0, "queued clear wrote a hold");
            require(active.get(5, java.util.concurrent.TimeUnit.SECONDS) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "blocking clear did not expire");
            proceed.countDown();
            NewsQuotaOperationRunner.awaitIdleForTesting();
            require(queued.capture("saved") == null && holdCount(b.root.resolve("ledger.db")) == 0, "expired queue later mutated or unblocked");
            require(NewsQuotaOperationRunner.clear(queued, 10000) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "queued clear explicit retry failed");
        } finally { proceed.countDown(); observer.shutdown(); }

        final SyntheticRoot c = newSyntheticRoot(context);
        final NewsPrivateStoreFactory factory = NewsPrivateStoreFactory.openForMutationTesting(c.context, 200L * 1024L * 1024L);
        require(factory != null, "competing ack factory unavailable");
        final Object first = new Object(), second = new Object();
        final NewsPrivateStoreFactory.PendingClear receipt = factory.clearRawForMutationTesting(first);
        factory.prepareClearForMutationTesting(second);
        require(factory.acknowledgeClear(receipt, first) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "older ack unblocked newer clear");
        require(factory.capture("saved") == null, "newer prepared clear not blocked");
        require(NewsQuotaOperationRunner.clear(factory, 10000) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "competing clear explicit retry failed");
    }

    private static void checkClearObserverTimeout(Context context, String pauseAt) throws Exception {
        final SyntheticRoot s = newSyntheticRoot(context);
        final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), proceed = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.atomic.AtomicBoolean first = new java.util.concurrent.atomic.AtomicBoolean(true);
        final NewsPrivateStoreFactory factory = NewsPrivateStoreFactory.openForMutationTesting(s.context,
                200L * 1024L * 1024L, null, stage -> {
                    if (pauseAt.equals(stage) && first.compareAndSet(true, false)) { entered.countDown(); proceed.await(); }
                });
        require(factory != null, "runner factory unavailable");
        final java.util.concurrent.ExecutorService observer = java.util.concurrent.Executors.newSingleThreadExecutor();
        try {
            final java.util.concurrent.Future<NewsPrivateStoreFactory.ClearResult> result = observer.submit(() -> NewsQuotaOperationRunner.clear(factory, 250));
            require(entered.await(5, java.util.concurrent.TimeUnit.SECONDS), "runner did not reach stage");
            require(result.get(5, java.util.concurrent.TimeUnit.SECONDS) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "timed out clear accepted");
            require(factory.capture("saved") == null, "timed out clear released gate");
            final long holdsBeforeQueued = holdCount(s.root.resolve("ledger.db"));
            require(NewsQuotaOperationRunner.clear(factory, 30) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "queued timeout accepted");
            proceed.countDown();
            NewsQuotaOperationRunner.awaitIdleForTesting();
            require(holdCount(s.root.resolve("ledger.db")) == holdsBeforeQueued, "expired queued clear mutated ledger");
            require(factory.capture("saved") == null, "late clear unblocked readers");
            require(NewsQuotaOperationRunner.clear(factory, 10000) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "explicit retry clear failed");
            final NewsPrivateStoreFactory.ReadTicket after = factory.capture("saved");
            require(after != null && factory.read(after).state == NewsPrivateStoreFactory.ReadState.MISS, "retry did not clear index");
        } finally { proceed.countDown(); observer.shutdown(); }
    }

    private static final class SyntheticRoot {
        final Context context;
        final Path root;
        SyntheticRoot(Context context, Path root) { this.context = context; this.root = root; }
    }

    private static SyntheticRoot newSyntheticRoot(Context context) throws Exception {
        final Path sandbox = context.getCacheDir().toPath().resolve("news_clear_case_" + UUID.randomUUID());
        Files.createDirectory(sandbox);
        final Context synthetic = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return sandbox.toFile(); }
        };
        final Path root = sandbox.resolve("news_quota_v1");
        Files.createDirectory(root); Files.createDirectory(root.resolve("blobs"));
        Files.createFile(root.resolve("lease.lock"));
        final String token = "v1:" + new String(new char[64]).replace('\0', 'a');
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token, true);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token, false);
        return new SyntheticRoot(synthetic, root);
    }

    private static void checkClearFailureCases(Context context) throws Exception {
        final long limit = 200L * 1024L * 1024L;
        {
            final SyntheticRoot s = newSyntheticRoot(context);
            final NewsPrivateStoreFactory f = NewsPrivateStoreFactory.openForMutationTesting(s.context, limit);
            require(f != null, "MAX clear fixture unavailable");
            setGeneration(s.root.resolve("index.db"), Long.MAX_VALUE);
            final NewsPrivateStoreFactory.ReadTicket ticket = f.capture("saved");
            require(ticket != null && f.read(ticket).state == NewsPrivateStoreFactory.ReadState.HIT, "MAX clear baseline unavailable");
            final long holds = holdCount(s.root.resolve("ledger.db"));
            require(clearSync(f) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "MAX clear accepted");
            require(f.capture("saved") == null && f.read(ticket).state == NewsPrivateStoreFactory.ReadState.UNKNOWN, "MAX clear unblocked");
            require(holdCount(s.root.resolve("ledger.db")) == holds + 1, "MAX clear lost hold");
            setGeneration(s.root.resolve("index.db"), 0L);
            require(clearSync(f) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "MAX recovery clear failed");
        }
        {
            final SyntheticRoot s = newSyntheticRoot(context);
            final NewsPrivateStoreFactory fault = NewsPrivateStoreFactory.openForMutationTesting(s.context, limit, null,
                    stage -> { if ("clearBeforeCommit".equals(stage)) throw new IllegalStateException("synthetic clear rollback"); });
            require(fault != null && clearSync(fault) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "clear rollback accepted");
            require(fault.capture("saved") == null, "rollback clear unblocked");
            require(imageRowCount(s.root.resolve("index.db")) == 1, "rollback removed index row");
            require(holdCount(s.root.resolve("ledger.db")) == 1, "rollback lost hold");
            final NewsPrivateStoreFactory retry = NewsPrivateStoreFactory.openForMutationTesting(s.context, limit);
            require(retry != null && clearSync(retry) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "rollback retry failed");
        }
        {
            final SyntheticRoot s = newSyntheticRoot(context);
            final boolean[] inject = {false}, committed = {false};
            final int[] closes = {0};
            final NewsPrivateStoreFactory f = NewsPrivateStoreFactory.openForMutationTesting(s.context, limit, db -> {
                if (inject[0] && ++closes[0] == 5) {
                    try (android.database.Cursor row = db.rawQuery("SELECT generation,(SELECT COUNT(*) FROM news_images) FROM news_state WHERE id=1", null)) {
                        committed[0] = !db.inTransaction() && row.moveToFirst() && row.getLong(0) == 1 && row.getLong(1) == 0;
                    }
                    throw new IllegalStateException("synthetic clear close failure");
                }
            });
            require(f != null, "clear close fixture unavailable");
            inject[0] = true;
            require(clearSync(f) == NewsPrivateStoreFactory.ClearResult.UNKNOWN && closes[0] == 5 && committed[0], "clear close failure not observed");
            require(f.capture("saved") == null, "clear close quarantine allowed capture");
        }
        checkClearInterleavings(context);
    }

    private static long imageRowCount(Path path) {
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READONLY | SQLiteDatabase.NO_LOCALIZED_COLLATORS).build();
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(path.toFile(), params);
             android.database.Cursor row = db.rawQuery("SELECT COUNT(*) FROM news_images", null)) {
            return row.moveToFirst() ? row.getLong(0) : -1;
        }
    }

    private static void checkClearInterleavings(Context context) throws Exception {
        final long limit = 200L * 1024L * 1024L;
        {
            final SyntheticRoot s = newSyntheticRoot(context), other = newSyntheticRoot(context);
            final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), proceed = new java.util.concurrent.CountDownLatch(1);
            final NewsPrivateStoreFactory delayed = NewsPrivateStoreFactory.openForMutationTesting(s.context, limit, null,
                    stage -> { if ("clearAfterHold".equals(stage)) { entered.countDown(); proceed.await(); } });
            final NewsPrivateStoreFactory peer = NewsPrivateStoreFactory.openForMutationTesting(s.context, limit);
            final NewsPrivateStoreFactory unrelated = NewsPrivateStoreFactory.openForMutationTesting(other.context, limit);
            require(delayed != null && peer != null && unrelated != null, "delayed clear factories unavailable");
            final java.util.concurrent.ExecutorService executor = java.util.concurrent.Executors.newSingleThreadExecutor();
            try {
                final java.util.concurrent.Future<NewsPrivateStoreFactory.ClearResult> first = executor.submit(() -> clearSync(delayed));
                require(entered.await(5, java.util.concurrent.TimeUnit.SECONDS), "delayed clear did not enter");
                require(clearSync(peer) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "newer busy clear accepted");
                final NewsPrivateStoreFactory.ReadTicket independent = unrelated.capture("saved");
                require(independent != null && unrelated.read(independent).state == NewsPrivateStoreFactory.ReadState.HIT, "other root blocked");
                proceed.countDown();
                require(first.get(10, java.util.concurrent.TimeUnit.SECONDS) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "old clear unblocked newer epoch");
                require(peer.capture("saved") == null, "newer clear epoch unblocked");
                require(clearSync(peer) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "newer clear retry failed");
            } finally { proceed.countDown(); executor.shutdown(); }
        }
        {
            final SyntheticRoot s = newSyntheticRoot(context);
            final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), proceed = new java.util.concurrent.CountDownLatch(1);
            final NewsPrivateStoreFactory reader = NewsPrivateStoreFactory.openForMutationTesting(s.context, limit, null,
                    stage -> { if ("readBeforeReturn".equals(stage)) { entered.countDown(); proceed.await(); } });
            final NewsPrivateStoreFactory peer = NewsPrivateStoreFactory.openForMutationTesting(s.context, limit);
            require(reader != null && peer != null, "paused read factories unavailable");
            final NewsPrivateStoreFactory.ReadTicket ticket = reader.capture("saved");
            require(ticket != null, "paused read ticket unavailable");
            final java.util.concurrent.ExecutorService executor = java.util.concurrent.Executors.newSingleThreadExecutor();
            try {
                final java.util.concurrent.Future<NewsPrivateStoreFactory.ReadResult> work = executor.submit(() -> reader.read(ticket));
                require(entered.await(5, java.util.concurrent.TimeUnit.SECONDS), "read did not pause");
                require(clearSync(peer) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "busy clear accepted during read");
                proceed.countDown();
                require(work.get(10, java.util.concurrent.TimeUnit.SECONDS).state == NewsPrivateStoreFactory.ReadState.UNKNOWN, "stale read escaped failed clear");
                require(clearSync(peer) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "paused read clear retry failed");
            } finally { proceed.countDown(); executor.shutdown(); }
        }
    }

    private static void checkLogicalClear(Context context) throws Exception {
        final Path sandbox = context.getCacheDir().toPath().resolve("news_factory_clear_" + UUID.randomUUID());
        Files.createDirectory(sandbox);
        final Context synthetic = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return sandbox.toFile(); }
        };
        final Path root = sandbox.resolve("news_quota_v1");
        Files.createDirectory(root); Files.createDirectory(root.resolve("blobs"));
        Files.createFile(root.resolve("lease.lock"));
        final String token = "v1:" + new String(new char[64]).replace('\0', '9');
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token, true);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token, false);
        final NewsPrivateStoreFactory first = NewsPrivateStoreFactory.openForMutationTesting(synthetic, 200L * 1024L * 1024L);
        final NewsPrivateStoreFactory second = NewsPrivateStoreFactory.openForMutationTesting(synthetic, 200L * 1024L * 1024L);
        final NewsPrivateStoreFactory low = NewsPrivateStoreFactory.openForMutationTesting(synthetic, 1L);
        final NewsPrivateStoreFactory ordinary = NewsPrivateStoreFactory.openExisting(synthetic);
        require(first != null && second != null && low != null && ordinary != null, "clear factories unavailable");
        final NewsPrivateStoreFactory.ReadTicket oldRead = first.capture("saved");
        final NewsPrivateStoreFactory.WriteTicket oldWrite = first.beginFetch("saved");
        require(oldRead != null && oldWrite != null && first.read(oldRead).state == NewsPrivateStoreFactory.ReadState.HIT, "clear baseline unavailable");
        require(clearSync(ordinary) == NewsPrivateStoreFactory.ClearResult.SKIPPED &&
                first.read(oldRead).state == NewsPrivateStoreFactory.ReadState.HIT, "ordinary skip blocked read");
        final long blobs = blobCount(root), holds = holdCount(root.resolve("ledger.db"));
        require(clearSync(low) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "low budget clear accepted");
        require(first.read(oldRead).state == NewsPrivateStoreFactory.ReadState.UNKNOWN && second.capture("saved") == null, "failed clear did not block readers");
        require(first.putForMutationTesting(oldWrite, new byte[] {1}) == NewsPrivateStoreFactory.PutResult.SKIPPED, "failed clear admitted old writer");
        require(blobCount(root) == blobs && holdCount(root.resolve("ledger.db")) == holds, "failed clear changed blobs/holds");
        require(clearSync(second) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "retry clear failed");
        require(first.read(oldRead).state == NewsPrivateStoreFactory.ReadState.UNKNOWN, "old read revived");
        final NewsPrivateStoreFactory.ReadTicket after = first.capture("saved");
        require(after != null && first.read(after).state == NewsPrivateStoreFactory.ReadState.MISS, "cleared row revived");
        require(blobCount(root) == blobs && holdCount(root.resolve("ledger.db")) == holds + 1, "clear deleted blob or lost hold");
        final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch proceed = new java.util.concurrent.CountDownLatch(1);
        final NewsPrivateStoreFactory delayed = NewsPrivateStoreFactory.openForMutationTesting(synthetic,
                200L * 1024L * 1024L, null, stage -> {
                    if ("afterHold".equals(stage)) { entered.countDown(); proceed.await(); }
                });
        require(delayed != null, "overlap factory unavailable");
        final NewsPrivateStoreFactory.WriteTicket overlap = delayed.beginFetch("overlap");
        require(overlap != null, "overlap ticket unavailable");
        final java.util.concurrent.ExecutorService executor = java.util.concurrent.Executors.newSingleThreadExecutor();
        try {
            final java.util.concurrent.Future<NewsPrivateStoreFactory.PutResult> work = executor.submit(() -> delayed.putForMutationTesting(overlap, new byte[] {7}));
            require(entered.await(5, java.util.concurrent.TimeUnit.SECONDS), "overlap writer did not enter");
            require(clearSync(second) == NewsPrivateStoreFactory.ClearResult.UNKNOWN, "busy clear incorrectly confirmed");
            require(first.capture("overlap") == null, "busy clear did not block capture");
            proceed.countDown();
            require(work.get(10, java.util.concurrent.TimeUnit.SECONDS) == NewsPrivateStoreFactory.PutResult.UNCERTAIN, "old writer reported confirmed after clear request");
            require(first.capture("overlap") == null, "failed clear unblocked after old put");
            require(clearSync(second) == NewsPrivateStoreFactory.ClearResult.CONFIRMED_HELD, "overlap retry clear failed");
            final NewsPrivateStoreFactory.ReadTicket absent = first.capture("overlap");
            require(absent != null && first.read(absent).state == NewsPrivateStoreFactory.ReadState.MISS, "old put appeared after clear");
        } finally { proceed.countDown(); executor.shutdown(); }
    }

    private static void checkPutFull(Context context, boolean ledgerFull) throws Exception {
        final Path sandbox = context.getCacheDir().toPath().resolve("news_factory_put_full_" + UUID.randomUUID());
        Files.createDirectory(sandbox);
        final Context synthetic = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return sandbox.toFile(); }
        };
        final Path root = sandbox.resolve("news_quota_v1");
        Files.createDirectory(root); Files.createDirectory(root.resolve("blobs"));
        Files.createFile(root.resolve("lease.lock"));
        final String token = "v1:" + new String(new char[64]).replace('\0', ledgerFull ? '7' : '8');
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token, true);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token, false);
        final boolean[] targetFull = {false};
        final NewsPrivateStoreFactory factory = NewsPrivateStoreFactory.openForMutationTesting(synthetic,
                200L * 1024L * 1024L, null, stage -> {
                    if (stage.equals(ledgerFull ? "ledgerFull" : "indexFull")) targetFull[0] = true;
                });
        require(factory != null, "put FULL factory unavailable");
        final NewsPrivateStoreFactory.WriteTicket[] tickets = new NewsPrivateStoreFactory.WriteTicket[64];
        final String writeSuffix = new String(new char[500]).replace('\0', 'z');
        for (int i = 0; i < tickets.length; i++) {
            tickets[i] = factory.beginFetch(String.format(java.util.Locale.ROOT, "%08d", i) + writeSuffix);
            require(tickets[i] != null, "put FULL ticket unavailable");
        }
        final Path dbPath = root.resolve(ledgerFull ? "ledger.db" : "index.db");
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("DELETE").setSynchronousMode("FULL").build();
        boolean full = false;
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(dbPath.toFile(), params)) {
            try (android.database.Cursor cap = db.rawQuery("PRAGMA max_page_count=256", null)) {
                require(cap.moveToFirst() && cap.getLong(0) == 256, "put FULL page cap unavailable");
            }
            final String insert = ledgerFull ? "INSERT INTO news_holds(token,bytes) VALUES(?,1)" :
                    "INSERT INTO news_images(image_key,filename,size,sha) VALUES(?,'" + new String(new char[64]).replace('\0', 'a') + ".bin',3,'039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81')";
            final String huge = new String(new char[350000]).replace('\0', 'q');
            db.execSQL(insert, new Object[] {huge});
            final String suffix = new String(new char[ledgerFull ? 56 : 500]).replace('\0', 'x');
            for (int i = 0; i < 3000; i++) {
                try { db.execSQL(insert, new Object[] {String.format(java.util.Locale.ROOT, "%08d", i) + suffix}); }
                catch (android.database.sqlite.SQLiteFullException expected) { full = true; break; }
            }
        }
        require(full, "put FULL fixture did not fill database");
        for (NewsPrivateStoreFactory.WriteTicket ticket : tickets) {
            final long beforeBlobs = blobCount(root), beforeHolds = holdCount(root.resolve("ledger.db"));
            final NewsPrivateStoreFactory.PutResult result = factory.putForMutationTesting(ticket, new byte[] {7, 8, 9});
            if (targetFull[0]) {
                require(result == NewsPrivateStoreFactory.PutResult.UNCERTAIN, "target FULL not uncertain");
                require(blobCount(root) == beforeBlobs + (ledgerFull ? 0 : 1), "target FULL blob evidence wrong");
                require(holdCount(root.resolve("ledger.db")) == beforeHolds + (ledgerFull ? 0 : 1), "target FULL hold evidence wrong");
                final NewsPrivateStoreFactory.ReadTicket old = factory.capture("saved");
                require(old != null && factory.read(old).state == NewsPrivateStoreFactory.ReadState.HIT, "target FULL lost old image");
                break;
            }
            require(result == NewsPrivateStoreFactory.PutResult.CONFIRMED_HELD, "unexpected put before target FULL");
        }
        require(targetFull[0], "actual target mutation did not reach SQLITE_FULL");
    }

    private static void checkSqliteFull(Context context) throws Exception {
        final Path sandbox = context.getCacheDir().toPath().resolve("news_factory_full_" + UUID.randomUUID());
        Files.createDirectory(sandbox);
        final Context synthetic = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return sandbox.toFile(); }
        };
        final Path root = sandbox.resolve("news_quota_v1");
        Files.createDirectory(root); Files.createDirectory(root.resolve("blobs"));
        Files.createFile(root.resolve("lease.lock"));
        final String token = "v1:" + new String(new char[64]).replace('\0', 'e');
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token, true);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token, false);
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("DELETE").setSynchronousMode("FULL").build();
        final String suffix = new String(new char[500]).replace('\0', 'x');
        boolean full = false;
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(root.resolve("index.db").toFile(), params)) {
            try (android.database.Cursor cap = db.rawQuery("PRAGMA max_page_count=256", null)) {
                require(cap.moveToFirst() && cap.getLong(0) == 256, "FULL fixture page cap unavailable");
            }
            for (int i = 0; i < 3000; i++) {
                try { db.execSQL("INSERT INTO news_paths(image_key,generation) VALUES(?,1)", new Object[] {String.format(java.util.Locale.ROOT, "%08d", i) + suffix}); }
                catch (android.database.sqlite.SQLiteFullException expected) { full = true; break; }
            }
        }
        require(full, "fixture failed to reach SQLITE_FULL");
        final NewsPrivateStoreFactory factory = NewsPrivateStoreFactory.openForMutationTesting(synthetic, 200L * 1024L * 1024L);
        require(factory != null, "FULL fixture could not reopen");
        final String key = "fulltest" + suffix;
        require(factory.beginFetch(key) == null, "SQLITE_FULL returned ticket");
        require(pathGeneration(root.resolve("index.db"), key) == 0, "SQLITE_FULL committed generation");
    }

    private static void checkMutationCloseFailure(Context context) throws Exception {
        final Path sandbox = context.getCacheDir().toPath().resolve("news_factory_mutation_close_" + UUID.randomUUID());
        Files.createDirectory(sandbox);
        final Context synthetic = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return sandbox.toFile(); }
        };
        final Path root = sandbox.resolve("news_quota_v1");
        Files.createDirectory(root); Files.createDirectory(root.resolve("blobs"));
        Files.createFile(root.resolve("lease.lock"));
        final String token = "v1:" + new String(new char[64]).replace('\0', 'd');
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token, true);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token, false);
        final boolean[] inject = {false};
        final int[] closes = {0};
        final boolean[] committed = {false};
        final NewsPrivateStoreFactory factory = NewsPrivateStoreFactory.openForMutationTesting(synthetic,
                200L * 1024L * 1024L, db -> {
                    if (inject[0] && ++closes[0] == 4) {
                        try (android.database.Cursor row = db.rawQuery("SELECT generation FROM news_paths WHERE image_key=?", new String[] {"close-after-commit"})) {
                            committed[0] = !db.inTransaction() && row.moveToFirst() && row.getLong(0) == 1L;
                        }
                        throw new IllegalStateException("synthetic post-commit close failure");
                    }
                });
        require(factory != null, "mutation close fixture rejected");
        inject[0] = true;
        require(factory.beginFetch("close-after-commit") == null, "ticket escaped failed close");
        require(closes[0] == 4, "post-commit close failure not reached");
        require(committed[0], "mutation was not committed before injected close failure");
        require(factory.capture("saved") == null, "mutation close quarantine admitted capture");
        // Commit may have happened; the quarantined store is not cleaned up.
    }

    private static void checkDelayedPut(Context synthetic, Path root, NewsPrivateStoreFactory reader) throws Exception {
        final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch proceed = new java.util.concurrent.CountDownLatch(1);
        final NewsPrivateStoreFactory delayed = NewsPrivateStoreFactory.openForMutationTesting(synthetic,
                200L * 1024L * 1024L, null, name -> {
                    if ("afterHold".equals(name)) { entered.countDown(); proceed.await(); }
                });
        require(delayed != null, "delayed writer unavailable");
        final NewsPrivateStoreFactory.WriteTicket ticket = delayed.beginFetch("delayed");
        require(ticket != null, "delayed ticket missing");
        final byte[] original = new byte[] {2, 4, 6};
        final long before = holdCount(root.resolve("ledger.db"));
        final java.util.concurrent.ExecutorService executor = java.util.concurrent.Executors.newSingleThreadExecutor();
        try {
            final java.util.concurrent.Future<NewsPrivateStoreFactory.PutResult> work = executor.submit(() -> delayed.putForMutationTesting(ticket, original));
            require(entered.await(5, java.util.concurrent.TimeUnit.SECONDS), "delayed write did not start");
            original[0] = 9;
            try { work.get(30, java.util.concurrent.TimeUnit.MILLISECONDS); throw new AssertionError("missing observer timeout"); }
            catch (java.util.concurrent.TimeoutException expected) { /* no cancellation */ }
            require(reader.capture("saved") == null, "timeout released live writer gate");
            proceed.countDown();
            require(work.get(10, java.util.concurrent.TimeUnit.SECONDS) == NewsPrivateStoreFactory.PutResult.CONFIRMED_HELD, "delayed write did not settle");
            require(holdCount(root.resolve("ledger.db")) == before + 1, "timeout path lost hold");
            final NewsPrivateStoreFactory.ReadTicket result = reader.capture("delayed");
            require(result != null && Arrays.equals(reader.read(result).bytes, new byte[] {2, 4, 6}), "snapshot bytes changed after dispatch");
        } finally {
            proceed.countDown();
            executor.shutdown();
        }
    }

    private static void checkForeignTicket(Context context, NewsPrivateStoreFactory.WriteTicket ticket) throws Exception {
        final Path sandbox = context.getCacheDir().toPath().resolve("news_factory_foreign_" + UUID.randomUUID());
        Files.createDirectory(sandbox);
        final Context synthetic = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return sandbox.toFile(); }
        };
        final Path root = sandbox.resolve("news_quota_v1");
        Files.createDirectory(root); Files.createDirectory(root.resolve("blobs"));
        Files.createFile(root.resolve("lease.lock"));
        final String token = "v1:" + new String(new char[64]).replace('\0', 'a');
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token, true);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token, false);
        setGeneration(root.resolve("index.db"), 1L);
        setPathGeneration(root.resolve("index.db"), "foreign", 1L);
        final NewsPrivateStoreFactory foreign = NewsPrivateStoreFactory.openForMutationTesting(synthetic, 200L * 1024L * 1024L);
        require(foreign != null && foreign.putForMutationTesting(ticket, new byte[] {1}) == NewsPrivateStoreFactory.PutResult.SKIPPED, "foreign write ticket admitted");
        require(holdCount(root.resolve("ledger.db")) == 0, "foreign ticket created hold");
    }

    private static void checkUnsettledClose(Context context) throws Exception {
        final Path sandbox = context.getCacheDir().toPath().resolve("news_factory_close_" + UUID.randomUUID());
        Files.createDirectory(sandbox);
        final Context synthetic = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return sandbox.toFile(); }
        };
        final Path root = sandbox.resolve("news_quota_v1");
        Files.createDirectory(root);
        Files.createDirectory(root.resolve("blobs"));
        Files.createFile(root.resolve("lease.lock"));
        final String token = "v1:" + new String(new char[64]).replace('\0', 'c');
        Files.write(root.resolve("marker"), token.getBytes(StandardCharsets.US_ASCII));
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token, true);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token, false);
        final boolean[] inject = {false};
        final int[] closes = {0};
        final NewsPrivateStoreFactory factory = NewsPrivateStoreFactory.openForTesting(synthetic, db -> {
            if (inject[0] && ++closes[0] == 3) throw new IllegalStateException("synthetic close failure");
        });
        require(factory != null, "close fixture rejected");
        final NewsPrivateStoreFactory.ReadTicket ticket = factory.capture("saved");
        require(ticket != null, "close fixture ticket unavailable");
        require(factory.read(ticket).state == NewsPrivateStoreFactory.ReadState.HIT, "close fixture baseline not a hit");
        inject[0] = true;
        require(factory.read(ticket).state == NewsPrivateStoreFactory.ReadState.UNKNOWN, "HIT escaped failed close");
        require(closes[0] == 3, "synthetic close failure not reached");
        require(factory.capture("saved") == null, "quarantined gate admitted new capture");
        // No cleanup: the failed-close gate deliberately retains the OS lock
        // and resource until the isolated process exits.
    }

    private static void createDb(Path path, String root, String token, boolean index) throws Exception {
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(path.toString(), null,
                SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.CREATE_IF_NECESSARY |
                        SQLiteDatabase.NO_LOCALIZED_COLLATORS)) {
            db.execSQL("PRAGMA page_size=4096");
            db.execSQL("PRAGMA auto_vacuum=NONE");
            try (android.database.Cursor cursor = db.rawQuery("PRAGMA journal_mode=DELETE", null)) {
                require(cursor.moveToFirst() && "delete".equalsIgnoreCase(cursor.getString(0)), "fixture DELETE journal unavailable");
            }
            db.execSQL(SCHEMA);
            db.execSQL("INSERT INTO news_quota_custody(id,version,token,root) VALUES(1,1,?,?)", new Object[] {token, root});
            if (index) {
                db.execSQL("CREATE TABLE news_state (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL CHECK(generation>=0))");
                db.execSQL("CREATE TABLE news_images (image_key TEXT PRIMARY KEY NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL, sha TEXT NOT NULL)");
                db.execSQL("CREATE TABLE news_paths (image_key TEXT PRIMARY KEY NOT NULL, generation INTEGER NOT NULL CHECK(generation>=0))");
                db.execSQL("INSERT INTO news_state(id,generation) VALUES(1,0)");
                final String filename = new String(new char[64]).replace('\0', 'a') + ".bin";
                final byte[] bytes = new byte[] {1, 2, 3};
                Files.write(path.getParent().resolve("blobs").resolve(filename), bytes);
                db.execSQL("INSERT INTO news_images(image_key,filename,size,sha) VALUES(?,?,?,?)", new Object[] {
                    "saved", filename, 3, "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"});
            } else db.execSQL("CREATE TABLE news_holds (token TEXT PRIMARY KEY NOT NULL, bytes INTEGER NOT NULL CHECK(bytes>0))");
        }
    }

    private static boolean hasLocaleMetadata(Path path) {
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(path.toString(), null,
                SQLiteDatabase.OPEN_READONLY | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
             android.database.Cursor cursor = db.rawQuery("SELECT name FROM sqlite_master WHERE name='android_metadata'", null)) {
            return cursor.moveToFirst();
        }
    }

    private static void setVersion(Path path, Object version) {
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("DELETE").setSynchronousMode("FULL").build();
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(path.toFile(), params)) {
            db.execSQL("UPDATE news_quota_custody SET version=?", new Object[] {version});
        }
    }

    private static void setGeneration(Path path, long generation) {
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("DELETE").setSynchronousMode("FULL").build();
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(path.toFile(), params)) {
            db.execSQL("UPDATE news_state SET generation=?", new Object[] {generation});
        }
    }

    private static long pathGeneration(Path path, String key) {
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("DELETE").setSynchronousMode("FULL").build();
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(path.toFile(), params);
             android.database.Cursor row = db.rawQuery("SELECT generation FROM news_paths WHERE image_key=?", new String[] {key})) {
            return row.moveToFirst() ? row.getLong(0) : 0;
        }
    }

    private static long holdCount(Path path) {
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READONLY | SQLiteDatabase.NO_LOCALIZED_COLLATORS).build();
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(path.toFile(), params);
             android.database.Cursor row = db.rawQuery("SELECT COUNT(*) FROM news_holds", null)) {
            return row.moveToFirst() ? row.getLong(0) : -1;
        }
    }

    private static long fixtureBytes(Path root) throws Exception {
        long total = Files.size(root.resolve("marker")) + Files.size(root.resolve("lease.lock")) +
                Files.size(root.resolve("index.db")) + Files.size(root.resolve("ledger.db"));
        try (java.nio.file.DirectoryStream<Path> blobs = Files.newDirectoryStream(root.resolve("blobs"))) {
            for (Path file : blobs) total += Files.size(file);
        }
        return total;
    }

    private static long blobCount(Path root) throws Exception {
        try (java.util.stream.Stream<Path> files = Files.list(root.resolve("blobs"))) { return files.count(); }
    }

    private static void setPathGeneration(Path path, String key, long generation) {
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("DELETE").setSynchronousMode("FULL").build();
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(path.toFile(), params)) {
            db.execSQL("INSERT OR REPLACE INTO news_paths(image_key,generation) VALUES(?,?)", new Object[] {key, generation});
        }
    }

    private static NewsPrivateStoreFactory.ClearResult clearSync(NewsPrivateStoreFactory factory) {
        final Object operation = new Object();
        return factory.acknowledgeClear(factory.clearRawForMutationTesting(operation), operation);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
