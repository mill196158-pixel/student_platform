package com.mill453020.studentplatform

import android.app.Activity
import android.database.sqlite.SQLiteDatabase
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.util.IdentityHashMap
import java.util.UUID

/** Isolated QA experiment. Native creates and holds each engine's OS lease;
 * a DB token by itself is not a capability. No ordinary app wiring. */
internal object SourceEngineLeaseQa {
    private data class Lease(val token: String, val file: RandomAccessFile, val lock: FileLock)
    private val engines = IdentityHashMap<FlutterEngine,Lease>()
    private fun dbFile(activity: Activity): File? {
        val f = File(activity.filesDir.canonicalFile,"qa_native_fixture_v13/media.db")
        return if (f.absolutePath == f.canonicalPath && f.isFile) f else null
    }
    @Synchronized fun create(activity: Activity, engine: FlutterEngine): Boolean {
        if (activity.packageName != "com.mill453020.studentplatform.attachfixture" || engines.containsKey(engine)) return false
        val dbFile = dbFile(activity) ?: return false
        var marker: RandomAccessFile? = null
        var lock: FileLock? = null
        try {
            val dir = File(dbFile.parentFile,"engine_guards")
            if ((!dir.exists() && !dir.mkdir()) || dir.absolutePath != dir.canonicalPath) return false
            val token = UUID.randomUUID().toString()
            val path = File(dir,token)
            if (!path.createNewFile() || path.absolutePath != path.canonicalPath) return false
            val opened = RandomAccessFile(path,"rw")
            marker = opened
            val acquired = opened.channel.tryLock() ?: return false
            lock = acquired
            val db = SQLiteDatabase.openDatabase(dbFile.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_engine_native_lease(project TEXT PRIMARY KEY,uid TEXT NOT NULL,sid TEXT NOT NULL,token TEXT NOT NULL,epoch INTEGER NOT NULL)")
                db.beginTransactionNonExclusive()
                try {
                    db.execSQL("INSERT INTO qa_engine_native_lease(project,uid,sid,token,epoch) VALUES(?,?,?, ?,1)",arrayOf("https://example.invalid","synthetic","synthetic-session",token))
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
            } finally { db.close() }
            engines[engine] = Lease(token,opened,acquired)
            marker = null; lock = null
            return true
        } catch (_: Exception) { return false }
        finally { try { lock?.release() } catch (_: Exception) {}; try { marker?.close() } catch (_: Exception) {} }
    }
    @Synchronized fun validate(activity: Activity, engine: FlutterEngine, token: String): Boolean {
        if (activity.packageName != "com.mill453020.studentplatform.attachfixture") return false
        val lease = engines[engine] ?: return false
        if (lease.token != token || !lease.lock.isValid || !lease.file.channel.isOpen) return false
        val file = dbFile(activity) ?: return false
        return try {
            val db = SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READONLY)
            try {
                db.rawQuery("SELECT l.token FROM qa_engine_native_lease l JOIN active_session_registry a ON a.project=l.project AND a.uid=l.uid AND a.sid=l.sid AND a.owner_engine=l.token WHERE l.project=? AND l.uid=? AND l.sid=? AND l.token=? AND l.epoch=1 AND a.instance='qa-instance' AND a.revision=1 AND a.state='active'",arrayOf("https://example.invalid","synthetic","synthetic-session",token)).use { it.count == 1 }
            } finally { db.close() }
        } catch (_: Exception) { false }
    }
    @Synchronized fun admit(activity: Activity, engine: FlutterEngine): Boolean {
        val lease = engines[engine] ?: return false
        if (!lease.lock.isValid || !lease.file.channel.isOpen) return false
        val file = dbFile(activity) ?: return false
        return try {
            val db = SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.beginTransactionNonExclusive()
                try {
                    val exists = db.rawQuery("SELECT token FROM qa_engine_native_lease WHERE project=? AND uid=? AND sid=? AND token=? AND epoch=1",arrayOf("https://example.invalid","synthetic","synthetic-session",lease.token)).use { it.count == 1 }
                    if (!exists || !lease.lock.isValid) return false
                    val values = android.content.ContentValues().apply { put("owner_engine",lease.token) }
                    val changed = db.update("active_session_registry",values,"project=? AND uid=? AND sid=? AND instance=? AND revision=? AND state='active' AND owner_engine IS NULL",arrayOf("https://example.invalid","synthetic","synthetic-session","qa-instance","1"))
                    if (changed != 1 || !lease.lock.isValid) return false
                    db.setTransactionSuccessful(); true
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_: Exception) { false }
    }
    @Synchronized fun close(activity: Activity, engine: FlutterEngine): Boolean {
        val lease = engines[engine] ?: return false
        val file = dbFile(activity) ?: return false
        val blocked = try {
            val db = SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.beginTransactionNonExclusive()
                try {
                    val owner = db.rawQuery("SELECT revision,state FROM active_session_registry WHERE project=? AND owner_engine=?",arrayOf("https://example.invalid",lease.token)).use {
                        if (!it.moveToFirst()) null else Pair(it.getLong(0),it.getString(1))
                    }
                    if (owner != null && owner.second == "active") {
                        val values = android.content.ContentValues().apply { put("state","transition"); put("revision",owner.first+1) }
                        if (db.update("active_session_registry",values,"project=? AND owner_engine=? AND revision=? AND state='active'",arrayOf("https://example.invalid",lease.token,owner.first.toString())) != 1) return false
                    }
                    db.setTransactionSuccessful(); true
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_: Exception) { false }
        if (!blocked) return false
        engines.remove(engine)
        try { lease.lock.release() } catch (_: Exception) {}
        try { lease.file.close() } catch (_: Exception) {}
        return true
    }
}
