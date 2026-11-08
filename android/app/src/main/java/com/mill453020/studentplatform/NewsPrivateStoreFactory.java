package com.mill453020.studentplatform;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteException;
import android.os.Build;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.DirectoryStream;
import java.security.MessageDigest;
import java.util.regex.Pattern;

/** Standalone validation component. Not an admission authority or a writer;
 * provisioning and all production wiring are disabled. */
final class NewsPrivateStoreFactory {
    private static final Pattern MARKER = Pattern.compile("v1:[0-9a-f]{64}");
    private static final String SCHEMA = "CREATE TABLE news_quota_custody (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, token TEXT NOT NULL, root TEXT NOT NULL)";
    private static final String STATE_SCHEMA = "CREATE TABLE news_state (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL CHECK(generation>=0))";
    private static final String IMAGE_SCHEMA = "CREATE TABLE news_images (image_key TEXT PRIMARY KEY NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL, sha TEXT NOT NULL)";
    private static final String PATH_SCHEMA = "CREATE TABLE news_paths (image_key TEXT PRIMARY KEY NOT NULL, generation INTEGER NOT NULL CHECK(generation>=0))";
    private static final Pattern FILE_NAME = Pattern.compile("[0-9a-f]{64}\\.bin");
    private static final Pattern SHA = Pattern.compile("[0-9a-f]{64}");
    private final Path root;
    private final CloseHook testCloseHook;
    private final Long syntheticLimit;

    interface CloseHook { void beforeClose(SQLiteDatabase db) throws Exception; }
    private NewsPrivateStoreFactory(Path root, CloseHook testCloseHook, Long syntheticLimit) { this.root = root; this.testCloseHook = testCloseHook; this.syntheticLimit = syntheticLimit; }

    /** Fixed app-private location only. Never creates or repairs a store. */
    static NewsPrivateStoreFactory openExisting(Context context) {
        if (context == null || Build.VERSION.SDK_INT < 28) return null;
        try {
            final Path root = context.getNoBackupFilesDir().toPath().resolve("news_quota_v1");
            final NewsPrivateStoreFactory factory = new NewsPrivateStoreFactory(root, null, null);
            return factory.validateExisting() ? factory : null;
        } catch (Exception failure) { return null; }
    }

    /** Isolated test APK only. Never used by the ordinary factory. */
    static NewsPrivateStoreFactory openForTesting(Context context, CloseHook hook) {
        if (context == null || Build.VERSION.SDK_INT < 28 || hook == null ||
                !"com.mill453020.studentplatform.newsfactoryfixture".equals(context.getPackageName())) return null;
        try {
            final Path root = context.getNoBackupFilesDir().toPath().resolve("news_quota_v1");
            final NewsPrivateStoreFactory factory = new NewsPrivateStoreFactory(root, hook, null);
            return factory.validateExisting() ? factory : null;
        } catch (Exception failure) { return null; }
    }

    /** Only the isolated fixture may exercise the unproven mutation profile. */
    static NewsPrivateStoreFactory openForMutationTesting(Context context, long limit) {
        return openForMutationTesting(context, limit, null);
    }

    static NewsPrivateStoreFactory openForMutationTesting(Context context, long limit, CloseHook hook) {
        if (context == null || Build.VERSION.SDK_INT < 28 || limit < 0 ||
                !"com.mill453020.studentplatform.newsfactoryfixture".equals(context.getPackageName())) return null;
        try {
            final Path root = context.getNoBackupFilesDir().toPath().resolve("news_quota_v1");
            final NewsPrivateStoreFactory factory = new NewsPrivateStoreFactory(root, hook, limit);
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
        private final long generation;
        private ReadTicket(String root, String token, String key, long generation) {
            this.root = root; this.token = token; this.key = key; this.generation = generation;
        }
    }

    static final class WriteTicket {
        private final String root, token, key;
        private final long globalGeneration, pathGeneration;
        private WriteTicket(String root, String token, String key, long globalGeneration, long pathGeneration) {
            this.root = root; this.token = token; this.key = key;
            this.globalGeneration = globalGeneration; this.pathGeneration = pathGeneration;
        }
    }

    /** Synthetic-only mutation admission. Ordinary factory has no profile. */
    WriteTicket beginFetch(String key) {
        if (syntheticLimit == null || key == null || key.isEmpty() || key.length() > 512) return null;
        final WriteTicket[] result = {null};
        try {
            if (!NewsQuotaExclusiveGate.runSync(root.resolve("lease.lock"), () -> {
                if (!validateLocked() || !syntheticHeadroom()) return;
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
                                if (row.getType(0) != Cursor.FIELD_TYPE_INTEGER || row.getLong(0) < 0 || row.getLong(0) == Long.MAX_VALUE) return;
                                prior = row.getLong(0);
                                if (row.moveToNext()) return;
                            }
                        }
                        final long next = prior + 1;
                        db.execSQL("INSERT OR REPLACE INTO news_paths(image_key,generation) VALUES(?,?)", new Object[] {key, next});
                        db.setTransactionSuccessful();
                        pending = new WriteTicket(canonical, token, key, global, next);
                    } finally { db.endTransaction(); }
                } finally { closeConfirmed(db); }
                result[0] = pending;
            })) return null;
            return result[0];
        } catch (Exception failure) { return null; }
    }

    /** Synthetic bound only: never interpreted as proof for an ordinary app. */
    private boolean syntheticHeadroom() {
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
                                if (++count > 1024 || !FILE_NAME.matcher(blob.getFileName().toString()).matches() ||
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
            // Synthetic envelope only: both 256-page DBs, rollback journals,
            // sector/header alignment and control; no Android proof claimed.
            return Math.addExact(total, 100L * 1024L * 1024L) <= syntheticLimit;
        } catch (Exception failure) { return false; }
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
        final ReadTicket[] result = {null};
        try {
            if (!NewsQuotaExclusiveGate.runSync(root.resolve("lease.lock"), () -> {
                if (!validateLocked()) return;
                final String canonical = root.toRealPath().toString();
                final String token = new String(Files.readAllBytes(root.resolve("marker")), StandardCharsets.US_ASCII);
                final SQLiteDatabase db = openIndexForRead();
                try {
                    if (!validImageSchema(db)) return;
                    final Long generation = generation(db);
                    if (generation != null) result[0] = new ReadTicket(canonical, token, key, generation);
                } finally { closeConfirmed(db); }
            })) return null;
            return result[0];
        } catch (Exception failure) { return null; }
    }

    ReadResult read(ReadTicket ticket) {
        final ReadResult unknown = new ReadResult(ReadState.UNKNOWN, null);
        if (ticket == null) return unknown;
        final ReadResult[] result = {unknown};
        try {
            if (!NewsQuotaExclusiveGate.runSync(root.resolve("lease.lock"), () -> {
                if (!validateLocked() || !ticket.root.equals(root.toRealPath().toString()) ||
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
            })) return unknown;
            return result[0];
        } catch (Exception failure) { return unknown; }
    }

    private SQLiteDatabase openIndexForRead() throws Exception {
        final SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("DELETE").setSynchronousMode("FULL")
                .setErrorHandler(ignored -> { throw new SQLiteException("Corrupt news index"); }).build();
        final SQLiteDatabase db = SQLiteDatabase.openDatabase(root.resolve("index.db").toFile(), params);
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
