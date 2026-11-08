package com.mill453020.studentplatform;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteException;
import android.database.sqlite.SQLiteFullException;
import android.os.Build;
import android.system.Os;
import android.system.OsConstants;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.StandardOpenOption;
import java.nio.file.StandardCopyOption;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.DirectoryStream;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.io.FileDescriptor;
import java.util.regex.Pattern;
import java.util.HashMap;
import java.util.Map;

/** Standalone synthetic validation/writer component. It is not an admission
 * authority; provisioning and all production wiring are disabled. */
final class NewsPrivateStoreFactory {
    private static final Pattern MARKER = Pattern.compile("v1:[0-9a-f]{64}");
    private static final String SCHEMA = "CREATE TABLE news_quota_custody (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, token TEXT NOT NULL, root TEXT NOT NULL)";
    private static final String STATE_SCHEMA = "CREATE TABLE news_state (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL CHECK(generation>=0))";
    private static final String IMAGE_SCHEMA = "CREATE TABLE news_images (image_key TEXT PRIMARY KEY NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL, sha TEXT NOT NULL)";
    private static final String PATH_SCHEMA = "CREATE TABLE news_paths (image_key TEXT PRIMARY KEY NOT NULL, generation INTEGER NOT NULL CHECK(generation>=0))";
    private static final String HOLD_SCHEMA = "CREATE TABLE news_holds (token TEXT PRIMARY KEY NOT NULL, bytes INTEGER NOT NULL CHECK(bytes>0))";
    private static final Pattern FILE_NAME = Pattern.compile("[0-9a-f]{64}\\.bin");
    private static final Pattern SHA = Pattern.compile("[0-9a-f]{64}");
    private static final Map<String, RootFence> FENCES = new HashMap<>();
    private static final class RootFence { long epoch; boolean blocked; }
    private final Path root;
    private final RootFence fence;
    private final CloseHook testCloseHook;
    private final Long syntheticLimit;
    private final PutHook testPutHook;

    interface CloseHook { void beforeClose(SQLiteDatabase db) throws Exception; }
    interface PutHook { void stage(String name) throws Exception; default String blobName() { return null; } }
    private NewsPrivateStoreFactory(Path root, CloseHook testCloseHook, Long syntheticLimit, PutHook testPutHook) throws IOException {
        this.root = root; this.testCloseHook = testCloseHook; this.syntheticLimit = syntheticLimit; this.testPutHook = testPutHook;
        synchronized (FENCES) { this.fence = FENCES.computeIfAbsent(root.toRealPath().toString(), ignored -> new RootFence()); }
    }

    private long fenceEpoch() { synchronized (fence) { return fence.blocked ? -1 : fence.epoch; } }
    private boolean fenceCurrent(long epoch) { synchronized (fence) { return !fence.blocked && fence.epoch == epoch; } }

    /** Fixed app-private location only. Never creates or repairs a store. */
    static NewsPrivateStoreFactory openExisting(Context context) {
        if (context == null || Build.VERSION.SDK_INT < 28) return null;
        try {
            final Path root = context.getNoBackupFilesDir().toPath().resolve("news_quota_v1");
            final NewsPrivateStoreFactory factory = new NewsPrivateStoreFactory(root, null, null, null);
            return factory.validateExisting() ? factory : null;
        } catch (Exception failure) { return null; }
    }

    /** Isolated test APK only. Never used by the ordinary factory. */
    static NewsPrivateStoreFactory openForTesting(Context context, CloseHook hook) {
        if (context == null || Build.VERSION.SDK_INT < 28 || hook == null ||
                !"com.mill453020.studentplatform.newsfactoryfixture".equals(context.getPackageName())) return null;
        try {
            final Path root = context.getNoBackupFilesDir().toPath().resolve("news_quota_v1");
            final NewsPrivateStoreFactory factory = new NewsPrivateStoreFactory(root, hook, null, null);
            return factory.validateExisting() ? factory : null;
        } catch (Exception failure) { return null; }
    }

    /** Only the isolated fixture may exercise the unproven mutation profile. */
    static NewsPrivateStoreFactory openForMutationTesting(Context context, long limit) {
        return openForMutationTesting(context, limit, null);
    }

    static NewsPrivateStoreFactory openForMutationTesting(Context context, long limit, CloseHook hook) {
        return openForMutationTesting(context, limit, hook, null);
    }

    static NewsPrivateStoreFactory openForMutationTesting(Context context, long limit, CloseHook hook, PutHook putHook) {
        if (context == null || Build.VERSION.SDK_INT < 28 || limit < 0 ||
                !"com.mill453020.studentplatform.newsfactoryfixture".equals(context.getPackageName())) return null;
        try {
            final Path root = context.getNoBackupFilesDir().toPath().resolve("news_quota_v1");
            final NewsPrivateStoreFactory factory = new NewsPrivateStoreFactory(root, hook, limit, putHook);
            return factory.validateExisting() ? factory : null;
        } catch (Exception failure) { return null; }
    }

    private boolean validateExisting() {
        final Path lease = root.resolve("lease.lock");
        final boolean[] valid = {false};
        try {
            final boolean entered = NewsQuotaExclusiveGate.runSync(lease, () -> valid[0] = validateLocked());
            return entered && valid[0];
        } catch (Exception failure) { return false; }
    }

    /** Caller must hold the gate; no raw handles escape this method. */
    private boolean validateLocked() throws Exception {
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) ||
                !Files.isDirectory(root.resolve("blobs"), LinkOption.NOFOLLOW_LINKS) ||
                !Files.isRegularFile(root.resolve("marker"), LinkOption.NOFOLLOW_LINKS) ||
                !Files.isRegularFile(root.resolve("index.db"), LinkOption.NOFOLLOW_LINKS) ||
                !Files.isRegularFile(root.resolve("ledger.db"), LinkOption.NOFOLLOW_LINKS)) return false;
        final Path marker = root.resolve("marker");
        if (Files.size(marker) != 67) return false;
        final String token = new String(Files.readAllBytes(marker), StandardCharsets.US_ASCII);
        if (!MARKER.matcher(token).matches()) return false;
        final String canonical = root.toRealPath().toString();
        if (hasSidecars("index.db") || hasSidecars("ledger.db") ||
                !hasRollbackHeader(root.resolve("index.db")) || !hasRollbackHeader(root.resolve("ledger.db"))) return false;
        return verifyDb(root.resolve("index.db"), canonical, token) &&
                verifyDb(root.resolve("ledger.db"), canonical, token);
    }

    /** Opaque ticket captured before a network fetch; no disk mutation. */
    static final class ReadTicket {
        private final String root, token, key;
        private final long generation, localEpoch;
        private ReadTicket(String root, String token, String key, long generation, long localEpoch) {
            this.root = root; this.token = token; this.key = key; this.generation = generation; this.localEpoch = localEpoch;
        }
    }

    static final class WriteTicket {
        private final String root, token, key;
        private final long globalGeneration, pathGeneration, localEpoch;
        private WriteTicket(String root, String token, String key, long globalGeneration, long pathGeneration, long localEpoch) {
            this.root = root; this.token = token; this.key = key;
            this.globalGeneration = globalGeneration; this.pathGeneration = pathGeneration; this.localEpoch = localEpoch;
        }
    }

    /** Synthetic-only mutation admission. Ordinary factory has no profile. */
    WriteTicket beginFetch(String key) {
        if (syntheticLimit == null || key == null || key.isEmpty() || key.length() > 512) return null;
        final long localEpoch = fenceEpoch();
        if (localEpoch < 0) return null;
        final WriteTicket[] result = {null};
        try {
            if (!NewsQuotaExclusiveGate.runSync(root.resolve("lease.lock"), () -> {
                if (!fenceCurrent(localEpoch) || !validateLocked() || !syntheticHeadroom(0) || !fenceCurrent(localEpoch)) return;
                final String canonical = root.toRealPath().toString();
                final String token = new String(Files.readAllBytes(root.resolve("marker")), StandardCharsets.US_ASCII);
                final SQLiteDatabase db = openIndexForRead();
                WriteTicket pending = null;
                try {
                    if (!validImageSchema(db)) return;
                    final Long global = generation(db);
                    if (global == null || global.longValue() == Long.MAX_VALUE) return;
                    db.beginTransaction();
                    try {
                        long prior = 0;
                        try (Cursor row = db.rawQuery("SELECT generation FROM news_paths WHERE image_key=?", new String[] {key})) {
                            if (row.moveToFirst()) {
                                if (row.getType(0) != Cursor.FIELD_TYPE_INTEGER || row.getLong(0) < 0 || row.getLong(0) >= Long.MAX_VALUE - 1) return;
                                prior = row.getLong(0);
                                if (row.moveToNext()) return;
                            }
                        }
                        final long next = prior + 1;
                        db.execSQL("INSERT OR REPLACE INTO news_paths(image_key,generation) VALUES(?,?)", new Object[] {key, next});
                        db.setTransactionSuccessful();
                        pending = new WriteTicket(canonical, token, key, global, next, localEpoch);
                    } finally { db.endTransaction(); }
                } finally { closeConfirmed(db); }
                if (fenceCurrent(localEpoch)) result[0] = pending;
            })) return null;
            return fenceCurrent(localEpoch) ? result[0] : null;
        } catch (Exception failure) { return null; }
    }

    /** Synthetic bound only: never interpreted as proof for an ordinary app. */
    private boolean syntheticHeadroom(long prospectiveBytes) throws Exception {
        if (syntheticLimit == null) return false;
        try {
            long total = 0;
            int count = 0;
            try (DirectoryStream<Path> entries = Files.newDirectoryStream(root)) {
                for (Path entry : entries) {
                    if (++count > 1024 || Files.isSymbolicLink(entry)) return false;
                    final String name = entry.getFileName().toString();
                    if ("blobs".equals(name)) {
                        if (!Files.isDirectory(entry, LinkOption.NOFOLLOW_LINKS)) return false;
                        try (DirectoryStream<Path> blobs = Files.newDirectoryStream(entry)) {
                            for (Path blob : blobs) {
                                if (++count > 1024 || !(FILE_NAME.matcher(blob.getFileName().toString()).matches() ||
                                        blob.getFileName().toString().matches("\\.[0-9a-f]{64}\\.tmp")) ||
                                        !Files.isRegularFile(blob, LinkOption.NOFOLLOW_LINKS)) return false;
                                total = Math.addExact(total, Files.size(blob));
                            }
                        }
                    } else {
                        if (!(name.equals("marker") || name.equals("lease.lock") || name.equals("index.db") || name.equals("ledger.db")) ||
                                !Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) return false;
                        total = Math.addExact(total, Files.size(entry));
                    }
                }
            }
            // Holds remain charged until a proven reconciliation exists.
            final SQLiteDatabase ledger = openProfiled(root.resolve("ledger.db"));
            try {
                if (!validLedgerSchema(ledger)) return false;
                try (Cursor invalid = ledger.rawQuery("SELECT 1 FROM news_holds WHERE typeof(token)<>'text' OR length(token)=0 OR typeof(bytes)<>'integer' OR bytes<=0 LIMIT 1", null)) {
                    if (invalid.moveToFirst()) return false;
                }
                try (Cursor held = ledger.rawQuery("SELECT COALESCE(SUM(bytes),0) FROM news_holds", null)) {
                    if (!held.moveToFirst() || held.getType(0) != Cursor.FIELD_TYPE_INTEGER || held.getLong(0) < 0 || held.moveToNext()) return false;
                    held.moveToFirst();
                    total = Math.addExact(total, held.getLong(0));
                }
            } finally { closeConfirmed(ledger); }
            // Synthetic envelope only: both 256-page DBs, rollback journals,
            // sector/header alignment and control; no Android proof claimed.
            total = Math.addExact(total, 100L * 1024L * 1024L);
            total = Math.addExact(total, Math.multiplyExact(prospectiveBytes, 2));
            return total <= syntheticLimit;
        } catch (NewsQuotaExclusiveGate.UnsettledResourceException failure) { throw failure; }
        catch (Exception failure) { return false; }
    }

    enum PutResult { CONFIRMED_HELD, SKIPPED, UNCERTAIN }
    enum ClearResult { CONFIRMED_HELD, SKIPPED, UNKNOWN }

    /** Logical synthetic clear only. Blob files and durable holds are retained.
     * Other processes observe the invalidation after the committed generation.
     * Synchronous worker API: do not wrap it in an observer timeout; late
     * acknowledgement semantics are not implemented. */
    ClearResult clearForMutationTesting() {
        if (syntheticLimit == null) return ClearResult.SKIPPED;
        final long localEpoch;
        synchronized (fence) {
            fence.blocked = true;
            if (fence.epoch == Long.MAX_VALUE) return ClearResult.UNKNOWN;
            localEpoch = ++fence.epoch;
        }
        final boolean[] committed = {false};
        try {
            if (!NewsQuotaExclusiveGate.runSync(root.resolve("lease.lock"), () -> {
                synchronized (fence) { if (fence.epoch != localEpoch) return; }
                if (!validateLocked() || !syntheticHeadroom(0)) return;
                final String hold = randomHex();
                final SQLiteDatabase ledger = openProfiled(root.resolve("ledger.db"));
                try {
                    if (!validLedgerSchema(ledger)) return;
                    synchronized (fence) { if (fence.epoch != localEpoch) return; }
                    ledger.beginTransaction();
                    try {
                        ledger.execSQL("INSERT INTO news_holds(token,bytes) VALUES(?,1)", new Object[] {hold});
                        ledger.setTransactionSuccessful();
                    } finally { ledger.endTransaction(); }
                } finally { closeConfirmed(ledger); }
                if (testPutHook != null) testPutHook.stage("clearAfterHold");
                synchronized (fence) { if (fence.epoch != localEpoch) return; }
                final SQLiteDatabase index = openIndexForRead();
                try {
                    if (!validImageSchema(index)) return;
                    final Long global = generation(index);
                    if (global == null || global.longValue() == Long.MAX_VALUE) return;
                    synchronized (fence) { if (fence.epoch != localEpoch) return; }
                    index.beginTransaction();
                    try {
                        index.execSQL("UPDATE news_state SET generation=generation+1 WHERE id=1 AND generation=?", new Object[] {global});
                        if (!"1".equals(scalar(index, "SELECT changes()"))) return;
                        index.execSQL("DELETE FROM news_images");
                        if (testPutHook != null) testPutHook.stage("clearBeforeCommit");
                        index.setTransactionSuccessful();
                    } finally { index.endTransaction(); }
                } finally { closeConfirmed(index); }
                committed[0] = true;
            })) return ClearResult.UNKNOWN;
            synchronized (fence) {
                if (committed[0] && fence.epoch == localEpoch) {
                    fence.blocked = false;
                    return ClearResult.CONFIRMED_HELD;
                }
            }
            return ClearResult.UNKNOWN;
        } catch (Exception failure) { return ClearResult.UNKNOWN; }
    }

    /** Synthetic writer only, never an ordinary runtime quota admission. */
    PutResult putForMutationTesting(WriteTicket ticket, byte[] input) {
        if (syntheticLimit == null || ticket == null || input == null || input.length == 0 || input.length > 8 * 1024 * 1024 || !fenceCurrent(ticket.localEpoch)) return PutResult.SKIPPED;
        final byte[] bytes = input.clone();
        final PutResult[] result = {PutResult.SKIPPED};
        try {
            if (!NewsQuotaExclusiveGate.runSync(root.resolve("lease.lock"), () -> {
                if (!fenceCurrent(ticket.localEpoch) || !validateLocked() || !syntheticHeadroom(bytes.length) || !fenceCurrent(ticket.localEpoch) ||
                        !ticket.root.equals(root.toRealPath().toString()) ||
                        !ticket.token.equals(new String(Files.readAllBytes(root.resolve("marker")), StandardCharsets.US_ASCII))) return;
                final SQLiteDatabase index = openIndexForRead();
                try {
                    if (!validImageSchema(index) || !writeTicketCurrent(index, ticket)) return;
                } finally { closeConfirmed(index); }

                final String hold = randomHex();
                final SQLiteDatabase ledger = openProfiled(root.resolve("ledger.db"));
                try {
                    if (!validLedgerSchema(ledger) || !fenceCurrent(ticket.localEpoch)) return;
                    result[0] = PutResult.UNCERTAIN;
                    ledger.beginTransaction();
                    try {
                        try { ledger.execSQL("INSERT INTO news_holds(token,bytes) VALUES(?,?)", new Object[] {hold, bytes.length}); }
                        catch (SQLiteFullException full) {
                            if (testPutHook != null) testPutHook.stage("ledgerFull");
                            throw full;
                        }
                        ledger.setTransactionSuccessful();
                    } finally { ledger.endTransaction(); }
                } finally { closeConfirmed(ledger); }

                // Once a hold may have committed, any failure retains it.
                if (testPutHook != null) testPutHook.stage("afterHold");
                if (!fenceCurrent(ticket.localEpoch)) return;
                final String filename = writeBlobUnderGate(bytes);
                if (filename == null) return;
                final String sha = hex(MessageDigest.getInstance("SHA-256").digest(bytes));
                final SQLiteDatabase writeIndex = openIndexForRead();
                try {
                    if (!fenceCurrent(ticket.localEpoch) || !validImageSchema(writeIndex) || !writeTicketCurrent(writeIndex, ticket)) return;
                    writeIndex.beginTransaction();
                    try {
                        if (!writeTicketCurrent(writeIndex, ticket) || ticket.pathGeneration == Long.MAX_VALUE) return;
                        writeIndex.execSQL("UPDATE news_paths SET generation=generation+1 WHERE image_key=? AND generation=?", new Object[] {ticket.key, ticket.pathGeneration});
                        if (!"1".equals(scalar(writeIndex, "SELECT changes()"))) return;
                        try { writeIndex.execSQL("INSERT OR REPLACE INTO news_images(image_key,filename,size,sha) VALUES(?,?,?,?)", new Object[] {ticket.key, filename, bytes.length, sha}); }
                        catch (SQLiteFullException full) {
                            if (testPutHook != null) testPutHook.stage("indexFull");
                            throw full;
                        }
                        writeIndex.setTransactionSuccessful();
                    } finally { writeIndex.endTransaction(); }
                } finally { closeConfirmed(writeIndex); }
                if (testPutHook != null) testPutHook.stage("afterIndex");
                // No automatic release: a caller may have timed out while this
                // synchronous operation was still running. Reconciliation is
                // not implemented, so the committed hold remains durable.
                if (fenceCurrent(ticket.localEpoch)) result[0] = PutResult.CONFIRMED_HELD;
            })) return PutResult.SKIPPED;
            return fenceCurrent(ticket.localEpoch) ? result[0] : PutResult.UNCERTAIN;
        } catch (Exception failure) { return fenceCurrent(ticket.localEpoch) ? result[0] : PutResult.UNCERTAIN; }
    }

    private boolean writeTicketCurrent(SQLiteDatabase index, WriteTicket ticket) {
        final Long global = generation(index);
        if (global == null || global.longValue() != ticket.globalGeneration) return false;
        try (Cursor row = index.rawQuery("SELECT generation FROM news_paths WHERE image_key=?", new String[] {ticket.key})) {
            return row.moveToFirst() && row.getType(0) == Cursor.FIELD_TYPE_INTEGER &&
                    row.getLong(0) == ticket.pathGeneration && !row.moveToNext();
        }
    }

    private static String randomHex() {
        final byte[] random = new byte[32];
        new SecureRandom().nextBytes(random);
        return hex(random);
    }

    /** Invoked only while gate is held and after a durable hold. */
    private String writeBlobUnderGate(byte[] bytes) throws Exception {
        final Path directory = root.resolve("blobs");
        final String override = testPutHook == null ? null : testPutHook.blobName();
        final String name = override == null ? randomHex() : override;
        if (!SHA.matcher(name).matches()) return null;
        final Path temp = directory.resolve("." + name + ".tmp"), target = directory.resolve(name + ".bin");
        if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) return null;
        final FileChannel channel = FileChannel.open(temp, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
        try {
            final ByteBuffer buffer = ByteBuffer.wrap(bytes);
            while (buffer.hasRemaining()) if (channel.write(buffer) <= 0) throw new IOException("Blob write made no progress");
            channel.force(true);
        } finally {
            try { channel.close(); }
            catch (Throwable failure) { throw new NewsQuotaExclusiveGate.UnsettledResourceException(channel, failure); }
        }
        if (testPutHook != null) testPutHook.stage("afterTemp");
        if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) return null;
        Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE);
        if (testPutHook != null) testPutHook.stage("afterRename");
        final FileDescriptor directoryFd = Os.open(directory.toString(), OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW, 0);
        try {
            if (!OsConstants.S_ISDIR(Os.fstat(directoryFd).st_mode)) throw new IOException("Blob parent is not a directory");
            Os.fsync(directoryFd);
        }
        finally {
            try { Os.close(directoryFd); }
            catch (Throwable failure) { throw new NewsQuotaExclusiveGate.UnsettledResourceException(directoryFd, failure); }
        }
        if (testPutHook != null) testPutHook.stage("afterDirSync");
        return name + ".bin";
    }

    private static boolean validLedgerSchema(SQLiteDatabase db) {
        try (Cursor rows = db.rawQuery("SELECT type,name,sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'", null)) {
            int count = 0;
            while (rows.moveToNext()) {
                final String type = rows.getString(0), name = rows.getString(1), sql = rows.getString(2);
                if (!"table".equals(type)) return false;
                if (("news_quota_custody".equals(name) && SCHEMA.equals(sql)) ||
                        ("news_holds".equals(name) && HOLD_SCHEMA.equals(sql))) count++;
                else return false;
            }
            return count == 2;
        }
    }

    enum ReadState { HIT, MISS, UNKNOWN }
    static final class ReadResult {
        final ReadState state;
        final byte[] bytes;
        private ReadResult(ReadState state, byte[] bytes) { this.state = state; this.bytes = bytes; }
    }

    /** No raw file/SQLite handle escapes the gate. Null means unknown. */
    ReadTicket capture(String key) {
        if (key == null || key.isEmpty() || key.length() > 512) return null;
        final long localEpoch = fenceEpoch();
        if (localEpoch < 0) return null;
        final ReadTicket[] result = {null};
        try {
            if (!NewsQuotaExclusiveGate.runSync(root.resolve("lease.lock"), () -> {
                if (!fenceCurrent(localEpoch) || !validateLocked() || !fenceCurrent(localEpoch)) return;
                final String canonical = root.toRealPath().toString();
                final String token = new String(Files.readAllBytes(root.resolve("marker")), StandardCharsets.US_ASCII);
                final SQLiteDatabase db = openIndexForRead();
                try {
                    if (!validImageSchema(db)) return;
                    final Long generation = generation(db);
                    if (generation != null && fenceCurrent(localEpoch)) result[0] = new ReadTicket(canonical, token, key, generation, localEpoch);
                } finally { closeConfirmed(db); }
            })) return null;
            return fenceCurrent(localEpoch) ? result[0] : null;
        } catch (Exception failure) { return null; }
    }

    ReadResult read(ReadTicket ticket) {
        final ReadResult unknown = new ReadResult(ReadState.UNKNOWN, null);
        if (ticket == null || !fenceCurrent(ticket.localEpoch)) return unknown;
        final ReadResult[] result = {unknown};
        try {
            if (!NewsQuotaExclusiveGate.runSync(root.resolve("lease.lock"), () -> {
                if (!fenceCurrent(ticket.localEpoch) || !validateLocked() || !fenceCurrent(ticket.localEpoch) || !ticket.root.equals(root.toRealPath().toString()) ||
                        !ticket.token.equals(new String(Files.readAllBytes(root.resolve("marker")), StandardCharsets.US_ASCII))) return;
                final SQLiteDatabase db = openIndexForRead();
                try {
                    if (!validImageSchema(db)) return;
                    final Long generation = generation(db);
                    if (generation == null || generation.longValue() != ticket.generation) return;
                    try (Cursor row = db.rawQuery("SELECT filename,size,sha FROM news_images WHERE image_key=?", new String[] {ticket.key})) {
                        if (!row.moveToFirst()) { result[0] = new ReadResult(ReadState.MISS, null); return; }
                        if (row.getType(0) != Cursor.FIELD_TYPE_STRING || row.getType(1) != Cursor.FIELD_TYPE_INTEGER ||
                                row.getType(2) != Cursor.FIELD_TYPE_STRING) return;
                        final String filename = row.getString(0), sha = row.getString(2);
                        final long size = row.getLong(1);
                        if (row.moveToNext() || !FILE_NAME.matcher(filename).matches() || !SHA.matcher(sha).matches() || size <= 0 || size > 8L * 1024L * 1024L) return;
                        final Path file = root.resolve("blobs").resolve(filename);
                        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) || Files.size(file) != size) return;
                        final byte[] bytes = Files.readAllBytes(file);
                        if (bytes.length != size || !sha.equals(hex(MessageDigest.getInstance("SHA-256").digest(bytes)))) return;
                        result[0] = new ReadResult(ReadState.HIT, bytes);
                    }
                } finally { closeConfirmed(db); }
                if (testPutHook != null) testPutHook.stage("readBeforeReturn");
            })) return unknown;
            return fenceCurrent(ticket.localEpoch) ? result[0] : unknown;
        } catch (Exception failure) { return unknown; }
    }

    private SQLiteDatabase openIndexForRead() throws Exception {
        return openProfiled(root.resolve("index.db"));
    }

    private SQLiteDatabase openProfiled(Path databasePath) throws Exception {
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("DELETE").setSynchronousMode("FULL")
                .setErrorHandler(ignored -> { throw new SQLiteException("Corrupt news index"); }).build();
        final SQLiteDatabase db = SQLiteDatabase.openDatabase(databasePath.toFile(), params);
        boolean valid = false;
        try {
            if (!"delete".equalsIgnoreCase(scalar(db, "PRAGMA journal_mode")) ||
                    !"2".equals(scalar(db, "PRAGMA synchronous")) ||
                    !"0".equals(scalar(db, "PRAGMA auto_vacuum")) ||
                    !"4096".equals(scalar(db, "PRAGMA page_size")) ||
                    !"256".equals(scalar(db, "PRAGMA max_page_count=256"))) throw new SQLiteException("Unsupported index profile");
            db.execSQL("PRAGMA temp_store=MEMORY");
            if (!"2".equals(scalar(db, "PRAGMA temp_store"))) throw new SQLiteException("Unsupported temp profile");
            valid = true;
            return db;
        } finally { if (!valid) closeConfirmed(db); }
    }

    private static boolean validImageSchema(SQLiteDatabase db) {
        try (Cursor rows = db.rawQuery("SELECT type,name,sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'", null)) {
            int count = 0;
            while (rows.moveToNext()) {
                final String type = rows.getString(0), name = rows.getString(1), sql = rows.getString(2);
                if (!"table".equals(type)) return false;
                if (("news_state".equals(name) && STATE_SCHEMA.equals(sql)) ||
                        ("news_images".equals(name) && IMAGE_SCHEMA.equals(sql)) ||
                        ("news_paths".equals(name) && PATH_SCHEMA.equals(sql)) ||
                        ("news_quota_custody".equals(name) && SCHEMA.equals(sql))) count++;
                else return false;
            }
            return count == 4;
        }
    }

    private static Long generation(SQLiteDatabase db) {
        try (Cursor row = db.rawQuery("SELECT id,generation FROM news_state", null)) {
            if (!row.moveToFirst() || row.getType(0) != Cursor.FIELD_TYPE_INTEGER || row.getType(1) != Cursor.FIELD_TYPE_INTEGER ||
                    row.getLong(0) != 1 || row.getLong(1) < 0) return null;
            final long result = row.getLong(1);
            return row.moveToNext() ? null : result;
        }
    }

    private static String hex(byte[] bytes) {
        final StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
        return result.toString();
    }

    private static boolean hasRollbackHeader(Path file) throws IOException {
        final long size = Files.size(file);
        if (size < 20 || size > 256L * 4096L) return false;
        final byte[] header = new byte[20];
        try (InputStream input = Files.newInputStream(file)) {
            int offset = 0;
            while (offset < header.length) {
                final int read = input.read(header, offset, header.length - offset);
                if (read <= 0) return false;
                offset += read;
            }
        }
        final byte[] magic = "SQLite format 3\0".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < magic.length; i++) if (header[i] != magic[i]) return false;
        return header[18] == 1 && header[19] == 1;
    }

    private boolean hasSidecars(String base) {
        for (String suffix : new String[] {"-journal", "-wal", "-shm"}) {
            if (Files.exists(root.resolve(base + suffix), LinkOption.NOFOLLOW_LINKS)) return true;
        }
        return false;
    }

    private boolean verifyDb(Path file, String canonical, String token) throws NewsQuotaExclusiveGate.UnsettledResourceException {
        SQLiteDatabase db = null;
        try {
            // No CREATE flag. Unexpected hot journals were rejected above.
            final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                    .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                    .setJournalMode("DELETE").setSynchronousMode("FULL")
                    .setErrorHandler(ignored -> { throw new SQLiteException("Corrupt news validation database"); })
                    .build();
            db = SQLiteDatabase.openDatabase(file.toFile(), params);
            if (!"delete".equalsIgnoreCase(scalar(db, "PRAGMA journal_mode")) ||
                    !"0".equals(scalar(db, "PRAGMA auto_vacuum")) ||
                    !"2".equals(scalar(db, "PRAGMA synchronous"))) return false;
            final int page = Integer.parseInt(scalar(db, "PRAGMA page_size"));
            final long maxPages = Long.parseLong(scalar(db, "PRAGMA max_page_count=256"));
            if (page != 4096 || maxPages <= 0 || maxPages > 256) return false;
            db.execSQL("PRAGMA temp_store=MEMORY");
            if (!"2".equals(scalar(db, "PRAGMA temp_store"))) return false;
            try (Cursor schema = db.rawQuery("SELECT sql FROM sqlite_master WHERE type='table' AND name='news_quota_custody'", null)) {
                if (!schema.moveToFirst() || !SCHEMA.equals(schema.getString(0)) || schema.moveToNext()) return false;
            }
            try (Cursor row = db.rawQuery("SELECT id, version, token, root FROM news_quota_custody", null)) {
                return row.moveToFirst() && row.getType(0) == Cursor.FIELD_TYPE_INTEGER &&
                        row.getType(1) == Cursor.FIELD_TYPE_INTEGER && row.getType(2) == Cursor.FIELD_TYPE_STRING &&
                        row.getType(3) == Cursor.FIELD_TYPE_STRING && row.getLong(0) == 1L && row.getLong(1) == 1L &&
                        token.equals(row.getString(2)) && canonical.equals(row.getString(3)) && !row.moveToNext();
            }
        } catch (Exception failure) { return false; }
        finally { if (db != null) closeConfirmed(db); }
    }

    private void closeConfirmed(SQLiteDatabase db) throws NewsQuotaExclusiveGate.UnsettledResourceException {
        try {
            if (testCloseHook != null) testCloseHook.beforeClose(db);
            db.close();
        }
        catch (Throwable failure) { throw new NewsQuotaExclusiveGate.UnsettledResourceException(db, failure); }
    }

    private static String scalar(SQLiteDatabase db, String sql) {
        try (Cursor cursor = db.rawQuery(sql, null)) {
            if (!cursor.moveToFirst() || cursor.moveToNext()) throw new IllegalStateException("Invalid pragma result");
            cursor.moveToFirst();
            return cursor.getString(0);
        }
    }
}
