package com.mill453020.studentplatform

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import android.database.sqlite.SQLiteDatabase
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.util.IdentityHashMap
import java.util.UUID
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap

/** Isolated authorityqa package only. No path comes from Dart; no SDK token is
 * persisted here. A native engine object owns its own OS lease and ticket. */
internal object SourceDocumentAuthorityQa {
    private data class NativeGuard(val token:String,val file:RandomAccessFile,val lock:FileLock)
    private data class Lease(val ticket:String,val project:String,val uid:String,val sid:String,
        val instance:String,val initialRevision:Long,val guard:String,val engine:String,
        val file:RandomAccessFile,val lock:FileLock,val nativeGuard:NativeGuard,val marker:String)
    private val registered = IdentityHashMap<FlutterEngine,String>()
    private val leases = IdentityHashMap<FlutterEngine,Lease>()
    private val guards = IdentityHashMap<FlutterEngine,NativeGuard>()
    private var primary: FlutterEngine? = null
    private val cleanupWorker=Executors.newSingleThreadExecutor()
    private val closedEngines=ConcurrentHashMap.newKeySet<FlutterEngine>()
    @Volatile var testSlowProofReached=false
    @Synchronized fun register(engine:FlutterEngine) {
        if (primary == null && !closedEngines.contains(engine)) { primary=engine; registered[engine]=UUID.randomUUID().toString() }
    }
    private fun dbFile(activity:Context):File? {
        if (activity.packageName !in setOf("com.mill453020.studentplatform.authorityqa","com.mill453020.studentplatform.authorityfixture","com.mill453020.studentplatform.authorityrecoverfixture","com.mill453020.studentplatform.authorityrecoverdenyfixture","com.mill453020.studentplatform.authorityrecoverrevokedfixture","com.mill453020.studentplatform.authorityrecoverdiagnosticfixture","com.mill453020.studentplatform.authoritysourcefixture","com.mill453020.studentplatform.authoritysourcediagnosticv6","com.mill453020.studentplatform.authoritygatefixture","com.mill453020.studentplatform.authoritydispatchfixturev4")) return null
        val file=File(activity.filesDir.canonicalFile,"pinned_media_guard_ordinary_v1.db")
        return if (file.absolutePath==file.canonicalPath && file.isFile) file else null
    }
    /** QA provider reads only a previously reserved immutable snapshot while
     * the exact current engine lease and source remain valid. No UI calls or
     * waits for main thread are made under this monitor. */
    @Synchronized fun providerBytes(context:Context,request:String):ByteArray? {
        if (context.packageName !in setOf("com.mill453020.studentplatform.authorityqa","com.mill453020.studentplatform.authoritysourcediagnosticv6","com.mill453020.studentplatform.authoritygatefixture","com.mill453020.studentplatform.authoritydispatchfixturev4")) return null
        if (!Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) return null
        val engine=primary ?: return null
        val lease=leases[engine] ?: return null
        if (closedEngines.contains(engine) || registered[engine]!=lease.engine) return null
        val media=dbFile(context) ?: return null
        val snapshot=File(context.getDatabasePath("offline_chat_ordinary_v1.db").parentFile!!.canonicalFile,"offline_chat_ordinary_v1.db")
        if (snapshot.absolutePath!=snapshot.canonicalPath || !snapshot.isFile || media==snapshot) return null
        return try {
            val db=SQLiteDatabase.openDatabase(media.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.rawQuery("PRAGMA busy_timeout=0",null).use { it.moveToFirst() }
                db.execSQL("ATTACH DATABASE ? AS source_snapshot",arrayOf(snapshot.path))
                db.beginTransactionNonExclusive()
                try {
                    val row=db.rawQuery("SELECT s.chat,s.message,s.file,s.key,s.url,s.sha,s.revision,s.ticket FROM qa_authority_dispatch_snapshot s JOIN qa_authority_dispatch d ON d.request=s.request AND d.state IN ('uncertain','started') WHERE s.request=? AND s.project=? AND s.uid=? AND s.sid=? AND s.instance=? AND s.guard=? AND s.engine=?",arrayOf(request,lease.project,lease.uid,lease.sid,lease.instance,lease.guard,lease.engine)).use {
                        if (!it.moveToFirst()) return null
                        val values=(0..5).map { index -> it.getString(index) ?: return null }
                        val revision=it.getLong(6); val ticket=it.getString(7)
                        if (it.moveToNext() || ticket!=lease.ticket) return null
                        Pair(values,revision)
                    }
                    val values=row.first; val revision=row.second
                    if (!valid(db,lease,revision) || closedEngines.contains(engine) || primary !== engine || registered[engine]!=lease.engine) return null
                    val open=db.rawQuery("SELECT 1 FROM qa_native_document_authority_v2 WHERE project=? AND uid=? AND sid=? AND instance=? AND revision=? AND guard=? AND engine=? AND ticket=? AND state='open'",arrayOf(lease.project,lease.uid,lease.sid,lease.instance,revision.toString(),lease.guard,lease.engine,lease.ticket)).use { it.count==1 }
                    if (!open) return null
                    val source=SourceDocumentProofQa.Source(lease.project,lease.uid,lease.sid,values[0],values[1],values[2],values[3],values[4])
                    val bytes=SourceDocumentProofQa.bytesInTransaction(db,source,snapshot) ?: return null
                    val sha=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                    if (sha!=values[5] || closedEngines.contains(engine) || !valid(db,lease,revision)) return null
                    db.setTransactionSuccessful(); bytes
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_:Exception) { null }
    }
    private fun valid(db:SQLiteDatabase, lease:Lease, revision:Long):Boolean {
        if (!lease.lock.isValid || !lease.file.channel.isOpen || !lease.nativeGuard.lock.isValid || !lease.nativeGuard.file.channel.isOpen) return false
        val hasTombstone=db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name='media_cache_logout_tombstones'",null).use { it.moveToFirst() }
        if (!hasTombstone || db.rawQuery("SELECT 1 FROM media_cache_logout_tombstones WHERE project=? AND uid=? AND sid=? LIMIT 1",arrayOf(lease.project,lease.uid,lease.sid)).use { it.moveToFirst() }) return false
        val args=arrayOf(lease.project,lease.uid,lease.sid,lease.instance,revision.toString(),lease.guard)
        return db.rawQuery("SELECT 1 FROM active_session_registry a JOIN chat_app_guards g ON g.token=a.owner_engine WHERE a.project=? AND a.uid=? AND a.sid=? AND a.instance=? AND a.revision=? AND a.state='active' AND a.owner_engine=? AND g.project='*' AND g.sid=''",args).use { it.count==1 }
    }
    /** Durable QA reservation only; performs no external side effect. Once a
     * commit is attempted its result must never be replayed automatically. */
    @Synchronized fun reserveDispatch(activity:Activity,engine:FlutterEngine,args:Map<*,*>,deadline:Long=Long.MAX_VALUE):String {
        if (SystemClock.elapsedRealtime()>=deadline) return "blocked"
        if (activity.packageName !in setOf("com.mill453020.studentplatform.authorityqa","com.mill453020.studentplatform.authoritygatefixture","com.mill453020.studentplatform.authoritydispatchfixturev4")) return "blocked"
        val lease=leases[engine] ?: return "blocked"
        if (closedEngines.contains(engine) || primary !== engine || registered[engine]!=lease.engine) return "blocked"
        if (args["project"]!=lease.project || args["uid"]!=lease.uid || args["sid"]!=lease.sid) return "blocked"
        val request=args["request"] as? String ?: return "blocked"
        if (!Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) return "blocked"
        val source=SourceDocumentProofQa.Source(lease.project,lease.uid,lease.sid,
            args["chat"] as? String ?: return "blocked",args["message"] as? String ?: return "blocked",
            args["file"] as? String ?: return "blocked",args["key"] as? String ?: return "blocked",args["url"] as? String ?: return "blocked")
        val media=dbFile(activity) ?: return "blocked"
        val snapshot=File(activity.getDatabasePath("offline_chat_ordinary_v1.db").parentFile!!.canonicalFile,"offline_chat_ordinary_v1.db")
        if (snapshot.absolutePath!=snapshot.canonicalPath || !snapshot.isFile || media==snapshot) return "blocked"
        var commitAttempted=false
        return try {
            val db=SQLiteDatabase.openDatabase(media.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.rawQuery("PRAGMA busy_timeout=0",null).use { it.moveToFirst() }
                db.execSQL("ATTACH DATABASE ? AS source_snapshot",arrayOf(snapshot.path))
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_authority_dispatch(request TEXT PRIMARY KEY,state TEXT NOT NULL)")
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_authority_dispatch_snapshot(request TEXT PRIMARY KEY,project TEXT NOT NULL,uid TEXT NOT NULL,sid TEXT NOT NULL,chat TEXT NOT NULL,message TEXT NOT NULL,file TEXT NOT NULL,key TEXT NOT NULL,url TEXT NOT NULL,sha TEXT NOT NULL,instance TEXT NOT NULL,revision INTEGER NOT NULL,guard TEXT NOT NULL,engine TEXT NOT NULL,ticket TEXT NOT NULL)")
                db.beginTransactionNonExclusive()
                try {
                    val revision=db.rawQuery("SELECT revision FROM qa_native_document_authority_v2 WHERE project=? AND uid=? AND sid=? AND instance=? AND guard=? AND engine=? AND ticket=? AND state='open'",arrayOf(lease.project,lease.uid,lease.sid,lease.instance,lease.guard,lease.engine,lease.ticket)).use {
                        if (!it.moveToFirst()) return "blocked"
                        val v=it.getLong(0); if(it.moveToNext()) return "blocked"; v
                    }
                    if (closedEngines.contains(engine) || !valid(db,lease,revision)) return "blocked"
                    if (db.rawQuery("SELECT COUNT(*) FROM qa_authority_dispatch",null).use { !it.moveToFirst() || it.getLong(0)>=10000 }) return "blocked"
                    val pending=db.rawQuery("SELECT 1 FROM qa_authority_dispatch d JOIN qa_authority_dispatch_snapshot s ON d.request=s.request WHERE d.state='uncertain' AND s.project=? AND s.uid=? AND s.sid=? AND s.chat=? AND s.message=? AND s.file=? LIMIT 1",arrayOf(source.project,source.uid,source.sid,source.chat,source.message,source.file)).use { it.moveToFirst() }
                    if (pending) return "blocked"
                    val bytes=SourceDocumentProofQa.bytesInTransaction(db,source,snapshot) ?: return "blocked"
                    val sha=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                    if (activity.packageName=="com.mill453020.studentplatform.authoritygatefixture" && args["delayProofForTest"]==true) {
                        testSlowProofReached=true
                        Thread.sleep(500)
                    }
                    if (closedEngines.contains(engine) || !valid(db,lease,revision) || SystemClock.elapsedRealtime()>=deadline) return "blocked"
                    db.execSQL("INSERT INTO qa_authority_dispatch(request,state) VALUES(?,'uncertain')",arrayOf(request))
                    db.execSQL("INSERT INTO qa_authority_dispatch_snapshot(request,project,uid,sid,chat,message,file,key,url,sha,instance,revision,guard,engine,ticket) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",arrayOf(request,source.project,source.uid,source.sid,source.chat,source.message,source.file,source.key,source.url,sha,lease.instance,revision,lease.guard,lease.engine,lease.ticket))
                    if (SystemClock.elapsedRealtime()>=deadline || closedEngines.contains(engine)) return "blocked"
                    commitAttempted=true
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
                "reserved"
            } finally { db.close() }
        } catch (_:Exception) { if (commitAttempted) "uncertain" else "blocked" }
    }
    /** QA only. Runs on the channel worker: it never waits for Android main
     * while holding the authority monitor or the SQLite transaction. */
    @Synchronized fun dispatchSource(activity:Activity,engine:FlutterEngine,args:Map<*,*>,deadline:Long):String {
        if (activity.packageName !in setOf("com.mill453020.studentplatform.authorityqa","com.mill453020.studentplatform.authoritydispatchfixturev4","com.mill453020.studentplatform.authoritygatefixture")) return "blocked"
        if (SystemClock.elapsedRealtime()>=deadline) return "blocked"
        val reserved=reserveDispatch(activity,engine,args,deadline)
        if (reserved!="reserved") return reserved
        val lease=leases[engine] ?: return "uncertain"
        val request=args["request"] as? String ?: return "uncertain"
        val source=SourceDocumentProofQa.Source(lease.project,lease.uid,lease.sid,
            args["chat"] as? String ?: return "uncertain",args["message"] as? String ?: return "uncertain",
            args["file"] as? String ?: return "uncertain",args["key"] as? String ?: return "uncertain",args["url"] as? String ?: return "uncertain")
        val media=dbFile(activity) ?: return "uncertain"
        val snapshot=File(activity.getDatabasePath("offline_chat_ordinary_v1.db").parentFile!!.canonicalFile,"offline_chat_ordinary_v1.db")
        if (snapshot.absolutePath!=snapshot.canonicalPath || !snapshot.isFile) return "uncertain"
        return try {
            val db=SQLiteDatabase.openDatabase(media.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.rawQuery("PRAGMA busy_timeout=0",null).use { it.moveToFirst() }
                db.execSQL("ATTACH DATABASE ? AS source_snapshot",arrayOf(snapshot.path))
                db.beginTransactionNonExclusive()
                try {
                    val proof=db.rawQuery("SELECT s.sha,s.revision FROM qa_authority_dispatch d JOIN qa_authority_dispatch_snapshot s ON s.request=d.request WHERE d.request=? AND d.state='uncertain' AND s.project=? AND s.uid=? AND s.sid=? AND s.chat=? AND s.message=? AND s.file=? AND s.key=? AND s.url=? AND s.instance=? AND s.guard=? AND s.engine=? AND s.ticket=?",arrayOf(request,source.project,source.uid,source.sid,source.chat,source.message,source.file,source.key,source.url,lease.instance,lease.guard,lease.engine,lease.ticket)).use {
                        if(!it.moveToFirst()) return "uncertain"
                        val row=Pair(it.getString(0),it.getLong(1)); if(it.moveToNext()) return "uncertain"; row
                    }
                    val open=db.rawQuery("SELECT 1 FROM qa_native_document_authority_v2 WHERE project=? AND uid=? AND sid=? AND instance=? AND revision=? AND guard=? AND engine=? AND ticket=? AND state='open'",arrayOf(lease.project,lease.uid,lease.sid,lease.instance,proof.second.toString(),lease.guard,lease.engine,lease.ticket)).use { it.count==1 }
                    if (!open || closedEngines.contains(engine) || primary !== engine || registered[engine]!=lease.engine || !valid(db,lease,proof.second)) return "uncertain"
                    val bytes=SourceDocumentProofQa.bytesInTransaction(db,source,snapshot) ?: return "uncertain"
                    val sha=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                    if (sha!=proof.first || closedEngines.contains(engine) || !valid(db,lease,proof.second) || SystemClock.elapsedRealtime()>=deadline) return "uncertain"
                    val uri=Uri.parse("content://${activity.packageName}.authority_document_qa/document/$request")
                    val intent=Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri,"application/vnd.openxmlformats-officedocument.wordprocessingml.document")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        if (activity.packageName=="com.mill453020.studentplatform.authoritydispatchfixturev4") setClass(activity,SourceAuthorityViewerFixtureActivity::class.java)
                    }
                    activity.applicationContext.startActivity(intent)
                    // Keep the reservation uncertain even after start. Only
                    // an acknowledgement received from Dart may settle it;
                    // a lost channel response must not permit replay.
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
                "started"
            } finally { db.close() }
        } catch (_:Exception) { "uncertain" }
    }
    @Synchronized fun acknowledgeDispatch(activity:Activity,engine:FlutterEngine,request:String):Boolean {
        if (activity.packageName !in setOf("com.mill453020.studentplatform.authorityqa","com.mill453020.studentplatform.authoritydispatchfixturev4")) return false
        val lease=leases[engine] ?: return false
        if (closedEngines.contains(engine) || primary !== engine || registered[engine]!=lease.engine) return false
        val file=dbFile(activity) ?: return false
        return try {
            val db=SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.beginTransactionNonExclusive()
                try {
                    val revision=db.rawQuery("SELECT s.revision FROM qa_authority_dispatch d JOIN qa_authority_dispatch_snapshot s ON s.request=d.request WHERE d.request=? AND d.state='uncertain' AND s.project=? AND s.uid=? AND s.sid=? AND s.instance=? AND s.guard=? AND s.engine=? AND s.ticket=?",arrayOf(request,lease.project,lease.uid,lease.sid,lease.instance,lease.guard,lease.engine,lease.ticket)).use {
                        if(!it.moveToFirst()) return false
                        val value=it.getLong(0); if(it.moveToNext()) return false; value
                    }
                    if (closedEngines.contains(engine) || !valid(db,lease,revision)) return false
                    val values=android.content.ContentValues().apply { put("state","started") }
                    if(db.update("qa_authority_dispatch",values,"request=? AND state='uncertain'",arrayOf(request))!=1) return false
                    db.setTransactionSuccessful(); true
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_:Exception) { false }
    }
    /** QA only: verify a cached source under the exact live native owner.
     * No bytes, URI or filesystem path cross the channel. */
    @Synchronized fun verifySource(activity:Activity,engine:FlutterEngine,args:Map<*,*>):String? {
        var stage="ENTRY"
        fun mark(next:String) { stage=next; android.util.Log.i("AuthoritySourceQA","VERIFY_$next") }
        if (activity.packageName !in setOf("com.mill453020.studentplatform.authorityqa","com.mill453020.studentplatform.authoritysourcefixture","com.mill453020.studentplatform.authoritysourcediagnosticv6","com.mill453020.studentplatform.authoritygatefixture","com.mill453020.studentplatform.authoritydispatchfixturev4")) return null
        val lease=leases[engine] ?: return null
        if (closedEngines.contains(engine) || primary !== engine || registered[engine]!=lease.engine) return null
        if (args["project"]!=lease.project || args["uid"]!=lease.uid || args["sid"]!=lease.sid) return null
        val source=SourceDocumentProofQa.Source(lease.project,lease.uid,lease.sid,
            args["chat"] as? String ?: return null,args["message"] as? String ?: return null,
            args["file"] as? String ?: return null,args["key"] as? String ?: return null,
            args["url"] as? String ?: return null)
        val media=dbFile(activity) ?: return null
        // Android can expose /data/data as a symlink to /data/user/0. Resolve
        // the platform-owned directory first, then require the fixed child
        // itself to be canonical (do not accept an arbitrary supplied path).
        val snapshot=File(activity.getDatabasePath("offline_chat_ordinary_v1.db").parentFile!!.canonicalFile,"offline_chat_ordinary_v1.db")
        mark("PATH")
        if (snapshot.absolutePath!=snapshot.canonicalPath) { mark("PATH_NONCANONICAL"); return null }
        if (!snapshot.isFile) { mark("PATH_MISSING"); return null }
        if (media==snapshot) { mark("PATH_SAME"); return null }
        return try {
            val db=SQLiteDatabase.openDatabase(media.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.rawQuery("PRAGMA busy_timeout=0",null).use { it.moveToFirst() }
                db.execSQL("ATTACH DATABASE ? AS source_snapshot",arrayOf(snapshot.path))
                mark("ATTACH")
                db.beginTransactionNonExclusive()
                try {
                    val revision=db.rawQuery("SELECT revision FROM qa_native_document_authority_v2 WHERE project=? AND uid=? AND sid=? AND instance=? AND guard=? AND engine=? AND ticket=? AND state='open'",arrayOf(lease.project,lease.uid,lease.sid,lease.instance,lease.guard,lease.engine,lease.ticket)).use {
                        if (!it.moveToFirst()) return null
                        val value=it.getLong(0); if (it.moveToNext()) return null; value
                    }
                    if (!valid(db,lease,revision) || closedEngines.contains(engine) || registered[engine]!=lease.engine || primary !== engine) return null
                    mark("SOURCE")
                    val bytes=SourceDocumentProofQa.bytesInTransaction(db,source,snapshot) ?: return null
                    if (!valid(db,lease,revision) || closedEngines.contains(engine) || registered[engine]!=lease.engine || primary !== engine) return null
                    val hash=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                    db.setTransactionSuccessful()
                    mark("OK")
                    hash
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (e:Exception) { android.util.Log.i("AuthoritySourceQA","VERIFY_FAIL stage=$stage type=${e.javaClass.simpleName}"); null }
    }
    @Synchronized fun createGuard(activity:Activity,engine:FlutterEngine):String? {
        if (closedEngines.contains(engine) || registered[engine]==null || primary !== engine || guards.containsKey(engine)) return null
        val dbFile=dbFile(activity) ?: return null
        var file:RandomAccessFile?=null
        var lock:FileLock?=null
        try {
            val dir=File("${dbFile.path}.guards")
            if ((!dir.exists() && !dir.mkdir()) || dir.absolutePath!=dir.canonicalPath) return null
            val token=UUID.randomUUID().toString()
            val marker=File(dir,token)
            if (!marker.createNewFile() || marker.absolutePath!=marker.canonicalPath) return null
            val opened=RandomAccessFile(marker,"rw"); file=opened
            val held=opened.channel.tryLock() ?: return null; lock=held
            opened.write(token.toByteArray(Charsets.UTF_8)); opened.fd.sync()
            val db=SQLiteDatabase.openDatabase(dbFile.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.execSQL("INSERT INTO chat_app_guards(token,project,uid,sid,database_token) VALUES(?,'*',?,'',?)",arrayOf(token,android.os.Process.myPid().toString(),token))
            } finally { db.close() }
            guards[engine]=NativeGuard(token,opened,held); file=null; lock=null
            return token
        } catch (_:Exception) { return null }
        finally { try { lock?.release() } catch (_:Exception) {}; try { file?.close() } catch (_:Exception) {} }
    }
    @Synchronized fun releaseGuard(activity:Activity,engine:FlutterEngine,token:String):Boolean {
        val guard=guards[engine] ?: return false
        if (guard.token!=token || leases.containsKey(engine)) return false
        val dbFile=dbFile(activity) ?: return false
        val absent=try {
            val db=SQLiteDatabase.openDatabase(dbFile.path,null,SQLiteDatabase.OPEN_READONLY)
            try { db.rawQuery("SELECT 1 FROM chat_app_guards WHERE token=?",arrayOf(token)).use { !it.moveToFirst() } }
            finally { db.close() }
        } catch (_:Exception) { false }
        if (!absent) return false
        guards.remove(engine)
        try { guard.lock.release() } catch (_:Exception) {}
        try { guard.file.close() } catch (_:Exception) {}
        return true
    }
    @Synchronized fun capture(activity:Activity,engine:FlutterEngine,args:Map<*,*>):String? {
        val engineId=registered[engine] ?: return null
        if (closedEngines.contains(engine) || primary !== engine || leases.containsKey(engine)) return null
        val dbFile=dbFile(activity) ?: return null
        val project=args["project"] as? String ?: return null
        val uid=args["uid"] as? String ?: return null
        val sid=args["sid"] as? String ?: return null
        val instance=args["instance"] as? String ?: return null
        val revision=(args["revision"] as? Number)?.toLong() ?: return null
        val guard=args["guard"] as? String ?: return null
        if (listOf(project,uid,sid,instance,guard).any { it.isEmpty() } || revision<0) return null
        val nativeGuard=guards[engine] ?: return null
        if (nativeGuard.token!=guard || !nativeGuard.lock.isValid || !nativeGuard.file.channel.isOpen) return null
        var file:RandomAccessFile?=null
        var lock:FileLock?=null
        try {
            val dir=File(activity.filesDir.canonicalFile,"qa_document_authority_leases")
            if ((!dir.exists() && !dir.mkdir()) || dir.absolutePath!=dir.canonicalPath) return null
            val marker=File(dir,UUID.randomUUID().toString())
            if (!marker.createNewFile() || marker.absolutePath!=marker.canonicalPath) return null
            val opened=RandomAccessFile(marker,"rw"); file=opened
            val held=opened.channel.tryLock() ?: return null; lock=held
            val ticket=UUID.randomUUID().toString()
            opened.write(ticket.toByteArray(Charsets.UTF_8)); opened.fd.sync()
            val lease=Lease(ticket,project,uid,sid,instance,revision,guard,engineId,opened,held,nativeGuard,marker.name)
            val db=SQLiteDatabase.openDatabase(dbFile.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_native_document_authority_v2(project TEXT PRIMARY KEY,uid TEXT NOT NULL,sid TEXT NOT NULL,instance TEXT NOT NULL,revision INTEGER NOT NULL,guard TEXT NOT NULL,engine TEXT NOT NULL,ticket TEXT NOT NULL,state TEXT NOT NULL,marker TEXT NOT NULL,pid INTEGER NOT NULL)")
                db.execSQL("CREATE TABLE IF NOT EXISTS media_cache_logout_tombstones(project TEXT NOT NULL,uid TEXT NOT NULL,sid TEXT NOT NULL,PRIMARY KEY(project,uid,sid))")
                db.beginTransactionNonExclusive()
                try {
                    if (!valid(db,lease,revision) || closedEngines.contains(engine) || registered[engine]!=engineId || primary !== engine) return null
                    val legacy=db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name='qa_native_document_authority'",null).use { it.moveToFirst() }
                    if (legacy && db.rawQuery("SELECT 1 FROM qa_native_document_authority WHERE project=? LIMIT 1",arrayOf(project)).use { it.moveToFirst() }) return null
                    db.execSQL("INSERT INTO qa_native_document_authority_v2(project,uid,sid,instance,revision,guard,engine,ticket,state,marker,pid) VALUES(?,?,?,?,?,?,?,?, 'closed',?,?)",arrayOf(project,uid,sid,instance,revision,guard,engineId,ticket,marker.name,android.os.Process.myPid()))
                    if (closedEngines.contains(engine) || !valid(db,lease,revision)) return null
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
            } finally { db.close() }
            leases[engine]=lease; file=null; lock=null
            return ticket
        } catch (_:Exception) { return null }
        finally { try { lock?.release() } catch (_:Exception) {}; try { file?.close() } catch (_:Exception) {} }
    }

    /** Cold-start recovery, QA only. Both old native locks must be proven dead
     * by nonblocking OS locks from a different PID and held through COMMIT. */
    @Synchronized fun recover(activity:Activity,engine:FlutterEngine,args:Map<*,*>):String? {
        val engineId=registered[engine] ?: return null
        if (closedEngines.contains(engine) || primary !== engine || leases.containsKey(engine)) return null
        val dbFile=dbFile(activity) ?: return null
        val nextGuard=guards[engine] ?: return null
        if (!nextGuard.lock.isValid || !nextGuard.file.channel.isOpen) return null
        val project=args["project"] as? String ?: return null
        val uid=args["uid"] as? String ?: return null
        val sid=args["sid"] as? String ?: return null
        val instance=args["instance"] as? String ?: return null
        val revision=(args["revision"] as? Number)?.toLong() ?: return null
        if (listOf(project,uid,sid,instance).any { it.isEmpty() } || revision<0) return null
        val uuid=Regex("^[0-9a-fA-F-]{36}$")
        var newFile:RandomAccessFile?=null; var newLock:FileLock?=null
        var oldGuardFile:RandomAccessFile?=null; var oldGuardLock:FileLock?=null
        var oldDocFile:RandomAccessFile?=null; var oldDocLock:FileLock?=null
        try {
            val docDir=File(activity.filesDir.canonicalFile,"qa_document_authority_leases")
            if (!docDir.isDirectory || docDir.absolutePath!=docDir.canonicalPath) return null
            val newMarker=File(docDir,UUID.randomUUID().toString())
            if (!newMarker.createNewFile() || newMarker.absolutePath!=newMarker.canonicalPath) return null
            val opened=RandomAccessFile(newMarker,"rw"); newFile=opened
            val held=opened.channel.tryLock() ?: return null; newLock=held
            val ticket=UUID.randomUUID().toString()
            opened.write(ticket.toByteArray(Charsets.UTF_8)); opened.fd.sync()
            val nextRevision=revision+1
            val lease=Lease(ticket,project,uid,sid,instance,nextRevision,nextGuard.token,engineId,opened,held,nextGuard,newMarker.name)
            val db=SQLiteDatabase.openDatabase(dbFile.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.beginTransactionNonExclusive()
                try {
                    val old=db.rawQuery("SELECT a.owner_engine,d.marker,d.pid,d.ticket,g.uid FROM active_session_registry a JOIN qa_native_document_authority_v2 d ON d.project=a.project AND d.uid=a.uid AND d.sid=a.sid AND d.instance=a.instance AND d.revision=a.revision AND d.guard=a.owner_engine JOIN chat_app_guards g ON g.token=a.owner_engine WHERE a.project=? AND a.uid=? AND a.sid=? AND a.instance=? AND a.revision=? AND a.state='active' AND d.state='open' AND g.project='*' AND g.sid=''",arrayOf(project,uid,sid,instance,revision.toString())).use {
                        if (!it.moveToFirst()) return null
                        val v=listOf(it.getString(0),it.getString(1),it.getString(2),it.getString(3),it.getString(4))
                        if (it.moveToNext() || v.any { x -> x==null }) return null
                        v.map { x -> x!! }
                    }
                    val oldPid=old[2].toIntOrNull() ?: return null
                    if (oldPid<=0 || oldPid==android.os.Process.myPid() || old[4]!=old[2] || !uuid.matches(old[0]) || !uuid.matches(old[1]) || !uuid.matches(old[3])) return null
                    val hasTombstoneTable=db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name='media_cache_logout_tombstones'",null).use { it.moveToFirst() }
                    if (!hasTombstoneTable || db.rawQuery("SELECT 1 FROM media_cache_logout_tombstones WHERE project=? AND uid=? AND sid=? LIMIT 1",arrayOf(project,uid,sid)).use { it.moveToFirst() }) return null
                    val guardPath=File("${dbFile.path}.guards/${old[0]}")
                    val docPath=File(docDir,old[1])
                    if (guardPath.absolutePath!=guardPath.canonicalPath || docPath.absolutePath!=docPath.canonicalPath || !guardPath.isFile || !docPath.isFile) return null
                    val gf=RandomAccessFile(guardPath,"rw"); oldGuardFile=gf
                    if (gf.length()!=old[0].length.toLong()) return null
                    val guardContents=ByteArray(old[0].length); gf.readFully(guardContents)
                    if (String(guardContents,Charsets.UTF_8)!=old[0]) return null
                    oldGuardLock=gf.channel.tryLock() ?: return null
                    val df=RandomAccessFile(docPath,"rw"); oldDocFile=df
                    if (df.length()!=old[3].length.toLong()) return null
                    val docContents=ByteArray(old[3].length); df.readFully(docContents)
                    if (String(docContents,Charsets.UTF_8)!=old[3]) return null
                    oldDocLock=df.channel.tryLock() ?: return null
                    val values=android.content.ContentValues().apply { put("owner_engine",nextGuard.token); put("revision",nextRevision) }
                    val changed=db.update("active_session_registry",values,"project=? AND uid=? AND sid=? AND instance=? AND revision=? AND state='active' AND owner_engine=?",arrayOf(project,uid,sid,instance,revision.toString(),old[0]))
                    if (changed!=1) return null
                    val update=android.content.ContentValues().apply { put("guard",nextGuard.token); put("engine",engineId); put("ticket",ticket); put("state","closed"); put("revision",nextRevision); put("marker",newMarker.name); put("pid",android.os.Process.myPid()) }
                    val changedDoc=db.update("qa_native_document_authority_v2",update,"project=? AND uid=? AND sid=? AND instance=? AND revision=? AND guard=? AND ticket=? AND state='open'",arrayOf(project,uid,sid,instance,revision.toString(),old[0],old[3]))
                    if (changedDoc!=1 || !valid(db,lease,nextRevision) || closedEngines.contains(engine) || registered[engine]!=engineId || primary !== engine) return null
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
            } finally { db.close() }
            leases[engine]=lease; newFile=null; newLock=null
            return ticket
        } catch (_:Exception) { return null }
        finally {
            try { oldDocLock?.release() } catch (_:Exception) {}; try { oldDocFile?.close() } catch (_:Exception) {}
            try { oldGuardLock?.release() } catch (_:Exception) {}; try { oldGuardFile?.close() } catch (_:Exception) {}
            try { newLock?.release() } catch (_:Exception) {}; try { newFile?.close() } catch (_:Exception) {}
        }
    }
    @Synchronized fun admit(activity:Activity,engine:FlutterEngine,ticket:String,instance:String,revision:Long):Boolean {
        val lease=leases[engine] ?: return false
        if (closedEngines.contains(engine) || lease.ticket!=ticket || lease.instance!=instance || registered[engine]!=lease.engine || primary !== engine ||
            (revision!=lease.initialRevision && revision!=lease.initialRevision+2)) return false
        val file=dbFile(activity) ?: return false
        return try {
            val db=SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.beginTransactionNonExclusive()
                try {
                    if (closedEngines.contains(engine) || !valid(db,lease,revision)) return false
                    val values=android.content.ContentValues().apply { put("state","open"); put("revision",revision) }
                    val count=db.update("qa_native_document_authority_v2",values,"project=? AND uid=? AND sid=? AND instance=? AND guard=? AND engine=? AND ticket=? AND state='closed'",arrayOf(lease.project,lease.uid,lease.sid,lease.instance,lease.guard,lease.engine,ticket))
                    val alreadyOpen=count==0 && db.rawQuery("SELECT 1 FROM qa_native_document_authority_v2 WHERE project=? AND uid=? AND sid=? AND instance=? AND revision=? AND guard=? AND engine=? AND ticket=? AND state='open'",arrayOf(lease.project,lease.uid,lease.sid,lease.instance,revision.toString(),lease.guard,lease.engine,ticket)).use { it.count==1 }
                    if ((count!=1 && !alreadyOpen) || closedEngines.contains(engine) || !valid(db,lease,revision)) return false
                    db.setTransactionSuccessful(); true
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_:Exception) { false }
    }
    @Synchronized fun close(activity:Activity,engine:FlutterEngine,ticket:String? = null):Boolean {
        var stage="ENTRY"
        fun mark(next:String) { stage=next; android.util.Log.i("AuthoritySourceQA","CLOSE_$next") }
        val lease=leases[engine] ?: return true
        if (ticket!=null && ticket!=lease.ticket) return false
        val file=dbFile(activity) ?: return false
        val committed=try {
            val db=SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.beginTransactionNonExclusive()
                try {
                    mark("ROW")
                    val authorityRevision = db.rawQuery("SELECT revision FROM qa_native_document_authority_v2 WHERE project=? AND instance=? AND engine=? AND ticket=?",arrayOf(lease.project,lease.instance,lease.engine,lease.ticket)).use {
                        if (!it.moveToFirst()) return false
                        val value=it.getLong(0); if (it.moveToNext()) return false; value
                    }
                    val values=android.content.ContentValues().apply { put("state","closed") }
                    val count=db.update("qa_native_document_authority_v2",values,"project=? AND instance=? AND engine=? AND ticket=?",arrayOf(lease.project,lease.instance,lease.engine,lease.ticket))
                    if (count!=1) return false
                    mark("REVOKE")
                    db.execSQL("UPDATE active_session_registry SET state='revoked',revision=revision+1,transition=NULL,next_uid=NULL,next_sid=NULL WHERE project=? AND uid=? AND sid=? AND instance=? AND owner_engine=? AND state IN ('active','transition') AND revision IN (?,?,?)",arrayOf(lease.project,lease.uid,lease.sid,lease.instance,lease.guard,authorityRevision,authorityRevision+1,authorityRevision+2))
                    db.setTransactionSuccessful(); true
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (e:Exception) { android.util.Log.i("AuthoritySourceQA","CLOSE_FAIL stage=$stage type=${e.javaClass.simpleName}"); false }
        if (!committed) return false
        leases.remove(engine)
        try { lease.lock.release() } catch (_:Exception) {}
        try { lease.file.close() } catch (_:Exception) {}
        return true
    }
    @Synchronized fun unregister(activity:Activity,engine:FlutterEngine) {
        if (close(activity,engine)) { registered.remove(engine); if (primary === engine) primary=null }
    }
    /** Close the process-local gate immediately; retain OS leases until the
     * durable close succeeds off the Android UI thread. A failed close stays
     * fenced and keeps its lease for later recovery, never a false success. */
    fun unregisterOffMain(activity:Activity,engine:FlutterEngine) {
        closedEngines.add(engine)
        cleanupWorker.execute { unregister(activity,engine) }
    }
}
