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
import java.util.regex.Pattern;

/** Standalone validation component. Not an admission authority or a writer;
 * provisioning and all production wiring are disabled. */
final class NewsPrivateStoreFactory {
    private static final Pattern MARKER = Pattern.compile("v1:[0-9a-f]{64}");
    private static final String SCHEMA = "CREATE TABLE news_quota_custody (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, token TEXT NOT NULL, root TEXT NOT NULL)";
    private final Path root;

    private NewsPrivateStoreFactory(Path root) { this.root = root; }

    /** Fixed app-private location only. Never creates or repairs a store. */
    static NewsPrivateStoreFactory openExisting(Context context) {
        if (context == null || Build.VERSION.SDK_INT < 28) return null;
        try {
            final Path root = context.getNoBackupFilesDir().toPath().resolve("news_quota_v1");
            final NewsPrivateStoreFactory factory = new NewsPrivateStoreFactory(root);
            return factory.validateExisting() ? factory : null;
        } catch (Exception failure) { return null; }
    }

    private boolean validateExisting() {
        final Path lease = root.resolve("lease.lock");
        final boolean[] valid = {false};
        try {
            final boolean entered = NewsQuotaExclusiveGate.runSync(lease, () -> {
                if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) ||
                        !Files.isDirectory(root.resolve("blobs"), LinkOption.NOFOLLOW_LINKS) ||
                        !Files.isRegularFile(root.resolve("marker"), LinkOption.NOFOLLOW_LINKS) ||
                        !Files.isRegularFile(root.resolve("index.db"), LinkOption.NOFOLLOW_LINKS) ||
                        !Files.isRegularFile(root.resolve("ledger.db"), LinkOption.NOFOLLOW_LINKS)) return;
                final Path marker = root.resolve("marker");
                if (Files.size(marker) != 67) return;
                final String token = new String(Files.readAllBytes(marker), StandardCharsets.US_ASCII);
                if (!MARKER.matcher(token).matches()) return;
                final String canonical = root.toRealPath().toString();
                if (hasSidecars("index.db") || hasSidecars("ledger.db") ||
                        !hasRollbackHeader(root.resolve("index.db")) || !hasRollbackHeader(root.resolve("ledger.db"))) return;
                valid[0] = verifyDb(root.resolve("index.db"), canonical, token) &&
                        verifyDb(root.resolve("ledger.db"), canonical, token);
            });
            return entered && valid[0];
        } catch (Exception failure) { return false; }
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

    private boolean verifyDb(Path file, String canonical, String token) {
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
        finally { if (db != null) db.close(); }
    }

    private static String scalar(SQLiteDatabase db, String sql) {
        try (Cursor cursor = db.rawQuery(sql, null)) {
            if (!cursor.moveToFirst() || cursor.moveToNext()) throw new IllegalStateException("Invalid pragma result");
            cursor.moveToFirst();
            return cursor.getString(0);
        }
    }
}
