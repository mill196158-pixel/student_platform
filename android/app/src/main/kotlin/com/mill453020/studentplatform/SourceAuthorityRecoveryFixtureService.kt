package com.mill453020.studentplatform

import android.app.Service
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.IBinder
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.util.UUID
import java.util.concurrent.Executors

/** Separate-process synthetic fixture only; no backend/account initialization. */
class SourceAuthorityRecoveryFixtureService : Service() {
    private var guardFile:RandomAccessFile?=null
    private var docFile:RandomAccessFile?=null
    private var guardLock:FileLock?=null
    private var docLock:FileLock?=null
    private val worker=Executors.newSingleThreadExecutor()
    override fun onBind(intent:Intent?):IBinder? = null
    override fun onDestroy() { worker.shutdown(); super.onDestroy() }
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        if (packageName !in setOf("com.mill453020.studentplatform.authorityrecoverfixture","com.mill453020.studentplatform.authorityrecoverdenyfixture","com.mill453020.studentplatform.authorityrecoverrevokedfixture","com.mill453020.studentplatform.authorityrecoverdiagnosticfixture","com.mill453020.studentplatform.authoritysourcefixture","com.mill453020.studentplatform.authoritysourcediagnosticv6")) return START_NOT_STICKY
        val mode=intent?.getStringExtra("fixtureLockMode")
        worker.execute { process(mode) }
        return START_NOT_STICKY
    }
    private fun process(mode:String?) {
        var stage="ENTRY"
        fun mark(next:String) { stage=next; android.util.Log.i("AuthorityRecoveryQA","SERVICE_$next") }
        try {
            mark("PATH")
            val dbFile=File(filesDir.canonicalFile,"pinned_media_guard_ordinary_v1.db")
            if (mode!=null) {
                when(mode) {
                    "guardOnly" -> { docLock?.release(); docLock=null }
                    "docOnly" -> { guardLock?.release(); guardLock=null }
                    "both" -> {
                        if (guardLock==null) guardLock=guardFile!!.channel.tryLock() ?: throw IllegalStateException()
                        if (docLock==null) docLock=docFile!!.channel.tryLock() ?: throw IllegalStateException()
                    }
                    else -> throw IllegalArgumentException()
                }
                val lockDb=SQLiteDatabase.openDatabase(dbFile.path,null,SQLiteDatabase.OPEN_READWRITE)
                try { lockDb.execSQL("UPDATE qa_recovery_fixture SET mode=?", arrayOf(mode)) } finally { lockDb.close() }
                return
            }
            val guardDir=File("${dbFile.path}.guards")
            val docDir=File(filesDir.canonicalFile,"qa_document_authority_leases")
            if (!guardDir.exists()) guardDir.mkdir()
            if (!docDir.exists()) docDir.mkdir()
            val guard=UUID.randomUUID().toString(); val marker=UUID.randomUUID().toString(); val ticket=UUID.randomUUID().toString()
            mark("LOCKS")
            guardFile=RandomAccessFile(File(guardDir,guard),"rw").also { it.write(guard.toByteArray()); it.fd.sync() }
            docFile=RandomAccessFile(File(docDir,marker),"rw").also { it.write(ticket.toByteArray()); it.fd.sync() }
            guardLock=guardFile!!.channel.tryLock() ?: return
            docLock=docFile!!.channel.tryLock() ?: return
            val db=SQLiteDatabase.openDatabase(dbFile.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                mark("SCHEMA")
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_native_document_authority_v2(project TEXT PRIMARY KEY,uid TEXT NOT NULL,sid TEXT NOT NULL,instance TEXT NOT NULL,revision INTEGER NOT NULL,guard TEXT NOT NULL,engine TEXT NOT NULL,ticket TEXT NOT NULL,state TEXT NOT NULL,marker TEXT NOT NULL,pid INTEGER NOT NULL)")
                db.execSQL("CREATE TABLE IF NOT EXISTS media_cache_logout_tombstones(project TEXT,uid TEXT,sid TEXT)")
                db.execSQL("CREATE TABLE IF NOT EXISTS qa_recovery_fixture(pid INTEGER NOT NULL, mode TEXT NOT NULL)")
                db.beginTransactionNonExclusive()
                try {
                    mark("PUBLISH")
                    val pid=android.os.Process.myPid()
                    db.execSQL("INSERT INTO chat_app_guards(token,project,uid,sid,database_token) VALUES(?,'*',?,'',?)",arrayOf(guard,pid.toString(),guard))
                    db.execSQL("UPDATE active_session_registry SET state='active',uid=?,sid=?,owner_engine=?,revision=1 WHERE project=?",arrayOf("synthetic","aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",guard,"https://example.invalid"))
                    db.execSQL("INSERT INTO qa_native_document_authority_v2(project,uid,sid,instance,revision,guard,engine,ticket,state,marker,pid) SELECT project,uid,sid,instance,revision,owner_engine,?,?, 'open',?,? FROM active_session_registry WHERE project=?",arrayOf("old-engine",ticket,marker,pid,"https://example.invalid"))
                    db.execSQL("INSERT INTO qa_recovery_fixture(pid,mode) VALUES(?,'both')",arrayOf(pid))
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
                mark("READY")
            } finally { db.close() }
        } catch (e:Exception) { android.util.Log.e("AuthorityRecoveryQA","SERVICE_FAIL stage=$stage type=${e.javaClass.simpleName}") }
    }
}
