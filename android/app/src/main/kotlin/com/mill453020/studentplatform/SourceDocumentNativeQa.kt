package com.mill453020.studentplatform

import android.app.Activity
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.security.MessageDigest
import java.util.IdentityHashMap
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean

/** Isolated fixture only. The registered native engine identity is never read
 * from a MethodChannel argument; the ordinary app cannot enable this guard. */
internal object SourceDocumentNativeQa {
    private data class Engine(val id: String, val primary: Boolean)
    private val engines = IdentityHashMap<FlutterEngine, Engine>()
    private var primaryEngine: FlutterEngine? = null
    @Synchronized fun register(engine: FlutterEngine, primary: Boolean) {
        if (!engines.containsKey(engine)) {
            val selected = primary && primaryEngine == null
            if (selected) primaryEngine = engine
            engines[engine] = Engine(UUID.randomUUID().toString(), selected)
        }
    }
    @Synchronized fun unregister(engine: FlutterEngine) { engines.remove(engine); if (primaryEngine === engine) primaryEngine = null }
    @Synchronized private fun engineId(engine: FlutterEngine): String? = engines[engine]?.id
    @Synchronized private fun isPrimary(engine: FlutterEngine): Boolean = engines[engine]?.primary == true

    // The transaction stays open until main-thread initiation has actually
    // finished. If the runnable has not started by the deadline it is canceled.
    private fun startOnMain(activity: Activity, intent: Intent, engine: FlutterEngine, expectedId: String): Boolean {
        val state = AtomicInteger(0)
        val done = CountDownLatch(1)
        val started = AtomicBoolean(false)
        activity.runOnUiThread {
            if (state.compareAndSet(0,1)) {
                try {
                    // Engine lifecycle handlers also run on main; no unregister
                    // can interleave this validation and startActivity.
                    if (engineId(engine) == expectedId) { activity.startActivity(intent); started.set(true) }
                } catch (_: Exception) {}
                finally { done.countDown() }
            } else { done.countDown() }
        }
        if (!done.await(3,TimeUnit.SECONDS)) {
            if (state.compareAndSet(0,2)) return false
            done.await() // already started: preserve SQLite ordering
        }
        return started.get()
    }

    private fun safeDb(activity: Activity, name: String): File? {
        val file = File(activity.filesDir.canonicalFile,"qa_native_fixture_v13/$name")
        val root = activity.filesDir.canonicalPath + File.separator
        return if (file.absolutePath == file.canonicalPath && file.canonicalPath.startsWith(root) && file.isFile) file else null
    }

    /** QA bootstrap for fabricated owner only; this is not production admission. */
    fun claim(activity: Activity, engine: FlutterEngine, args: Map<*, *>): Boolean {
        if (activity.packageName != "com.mill453020.studentplatform.attachfixture") return false
        if (!isPrimary(engine)) return false
        val id = engineId(engine) ?: return false
        val media = safeDb(activity,"media.db") ?: return false
        try {
            val db = SQLiteDatabase.openDatabase(media.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.rawQuery("PRAGMA busy_timeout=0", null).use { it.moveToFirst() }
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_docx_native_owner(project TEXT PRIMARY KEY, instance TEXT NOT NULL, revision INTEGER NOT NULL, engine TEXT NOT NULL)")
                db.beginTransactionNonExclusive()
                try {
                    val row = db.rawQuery("SELECT instance,revision FROM active_session_registry WHERE project=? AND uid=? AND sid=? AND state='active' AND (owner_engine IS NULL OR owner_engine=?)",arrayOf("https://example.invalid","synthetic","synthetic-session",id)).use {
                        if (!it.moveToFirst()) return false
                        val pair = Pair(it.getString(0),it.getLong(1)); if (it.moveToNext()) return false; pair
                    }
                    db.execSQL("UPDATE active_session_registry SET owner_engine=? WHERE project=? AND instance=? AND revision=? AND state='active' AND owner_engine IS NULL",arrayOf(id,"https://example.invalid",row.first,row.second))
                    db.execSQL("INSERT OR IGNORE INTO qa_docx_native_owner(project,instance,revision,engine) VALUES(?,?,?,?)",arrayOf("https://example.invalid",row.first,row.second,id))
                    val accepted = db.rawQuery("SELECT 1 FROM qa_docx_native_owner WHERE project=? AND instance=? AND revision=? AND engine=?",arrayOf("https://example.invalid",row.first,row.second.toString(),id)).use { it.count == 1 }
                    db.setTransactionSuccessful(); return accepted
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_: Exception) { return false }
    }

    /** Synthetic committed authority revoke before the SDK logout call. */
    fun revoke(activity: Activity, engine: FlutterEngine): Boolean {
        if (activity.packageName != "com.mill453020.studentplatform.attachfixture") return false
        val id = engineId(engine) ?: return false
        val media = safeDb(activity,"media.db") ?: return false
        try {
            val db = SQLiteDatabase.openDatabase(media.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.rawQuery("PRAGMA busy_timeout=0",null).use { it.moveToFirst() }
                db.beginTransactionNonExclusive()
                try {
                    val row = db.rawQuery("SELECT a.instance,a.revision FROM active_session_registry a JOIN qa_docx_native_owner o ON o.project=a.project AND o.instance=a.instance AND o.revision=a.revision AND o.engine=a.owner_engine WHERE a.project=? AND a.uid=? AND a.sid=? AND a.state='active' AND o.engine=?",arrayOf("https://example.invalid","synthetic","synthetic-session",id)).use {
                        if (!it.moveToFirst()) return false
                        val value = Pair(it.getString(0),it.getLong(1)); if (it.moveToNext()) return false; value
                    }
                    if (engineId(engine) != id) return false
                    val values = android.content.ContentValues().apply { put("state","revoked"); put("revision",row.second+1) }
                    val changed = db.update("active_session_registry",values,"project=? AND instance=? AND revision=? AND state='active' AND owner_engine=?",arrayOf("https://example.invalid",row.first,row.second.toString(),id))
                    if (changed != 1 || engineId(engine) != id) return false
                    db.setTransactionSuccessful(); return true
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_: Exception) { return false }
    }

    /** Returns `uncertain` after reservation: caller must never replay it. */
    fun dispatch(activity: Activity, engine: FlutterEngine, args: Map<*, *>): String {
        if (activity.packageName != "com.mill453020.studentplatform.attachfixture") return "blocked"
        val id = engineId(engine) ?: return "blocked"
        val request = args["request"] as? String ?: return "blocked"
        if (!Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) return "blocked"
        val media = safeDb(activity,"media.db") ?: return "blocked"
        val chat = safeDb(activity,"chat.db") ?: return "blocked"
        val names = listOf("project","uid","sid","chat","message","file","key","url")
        val v = names.map { args[it] as? String ?: return "blocked" }
        if (v[0] != "https://example.invalid" || v[1] != "synthetic" || v[2] != "synthetic-session") return "blocked"
        var reserved = false
        try {
            val db = SQLiteDatabase.openDatabase(media.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.rawQuery("PRAGMA busy_timeout=0", null).use { it.moveToFirst() }
                db.execSQL("ATTACH DATABASE ? AS source_snapshot", arrayOf(chat.path))
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_docx_dispatch(request TEXT PRIMARY KEY,state TEXT NOT NULL)")
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_docx_dispatch_snapshot(request TEXT PRIMARY KEY,sha TEXT NOT NULL,bytes BLOB NOT NULL,project TEXT NOT NULL,uid TEXT NOT NULL,sid TEXT NOT NULL,chat TEXT NOT NULL,message TEXT NOT NULL,file TEXT NOT NULL,key TEXT NOT NULL,url TEXT NOT NULL,instance TEXT NOT NULL,revision INTEGER NOT NULL)")
                db.execSQL("CREATE TRIGGER IF NOT EXISTS qa_docx_snapshot_no_update BEFORE UPDATE ON qa_docx_dispatch_snapshot BEGIN SELECT RAISE(ABORT,'immutable'); END")
                db.execSQL("CREATE TRIGGER IF NOT EXISTS qa_docx_snapshot_no_delete BEFORE DELETE ON qa_docx_dispatch_snapshot BEGIN SELECT RAISE(ABORT,'immutable'); END")
                fun permitted(): Boolean = db.rawQuery("SELECT 1 FROM active_session_registry a JOIN qa_docx_native_owner o ON o.project=a.project AND o.instance=a.instance AND o.revision=a.revision AND o.engine=a.owner_engine WHERE a.project=? AND a.uid=? AND a.sid=? AND a.state='active' AND o.engine=?",arrayOf(v[0],v[1],v[2],id)).use { it.count == 1 } && engineId(engine) == id
                db.beginTransactionNonExclusive()
                try {
                    if (!permitted()) return "blocked"
                    val count = db.rawQuery("SELECT COUNT(*) FROM qa_docx_dispatch",null).use { if (!it.moveToFirst()) return "blocked"; it.getLong(0) }
                    if (count >= 10000) return "blocked"
                    // An attempted commit can fail ambiguously; never retry it.
                    reserved = true
                    db.execSQL("INSERT INTO qa_docx_dispatch(request,state) VALUES(?,'uncertain')",arrayOf(request))
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
                db.beginTransactionNonExclusive()
                try {
                    if (!permitted()) return "uncertain"
                    val source = SourceDocumentProofQa.Source(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7])
                    val bytes = SourceDocumentProofQa.bytesInTransaction(db,source,chat) ?: return "uncertain"
                    val total = db.rawQuery("SELECT COALESCE(SUM(length(bytes)),0) FROM qa_docx_dispatch_snapshot",null).use { if (!it.moveToFirst()) return "uncertain"; it.getLong(0) }
                    if (total + bytes.size > 64L*1024*1024) return "uncertain"
                    val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                    val authority = db.rawQuery("SELECT instance,revision FROM active_session_registry WHERE project=? AND uid=? AND sid=? AND state='active' AND owner_engine=?",arrayOf(v[0],v[1],v[2],id)).use {
                        if (!it.moveToFirst()) return "uncertain"
                        val row = Pair(it.getString(0),it.getLong(1)); if (it.moveToNext()) return "uncertain"; row
                    }
                    db.execSQL("INSERT INTO qa_docx_dispatch_snapshot(request,sha,bytes,project,uid,sid,chat,message,file,key,url,instance,revision) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",arrayOf(request,sha,bytes,v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],authority.first,authority.second))
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
                if (args["prepareOnly"] == true) return "prepared"
                db.beginTransactionNonExclusive()
                try {
                    if (!permitted()) return "uncertain"
                    val source = SourceDocumentProofQa.Source(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7])
                    val bytes = SourceDocumentProofQa.bytesInTransaction(db,source,chat) ?: return "uncertain"
                    val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                    val pinned = db.rawQuery("SELECT sha FROM qa_docx_dispatch_snapshot WHERE request=?",arrayOf(request)).use { it.moveToFirst() && it.getString(0)==sha && !it.moveToNext() }
                    if (!pinned) return "uncertain"
                    if (engineId(engine) != id) return "uncertain"
                    val uri = Uri.parse("content://${activity.packageName}.source_document_qa/content/$request")
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri,"application/vnd.openxmlformats-officedocument.wordprocessingml.document")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    if (!startOnMain(activity,intent,engine,id)) return "uncertain"
                    db.setTransactionSuccessful()
                    return "started"
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_: Exception) { return if (reserved) "uncertain" else "blocked" }
    }
}
