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
        createDb(root.resolve("index.db"), root.toRealPath().toString(), token);
        createDb(root.resolve("ledger.db"), root.toRealPath().toString(), token);
        require(NewsPrivateStoreFactory.openExisting(synthetic) != null, "valid fixture rejected");
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
    }

    private static void createDb(Path path, String root, String token) {
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

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
