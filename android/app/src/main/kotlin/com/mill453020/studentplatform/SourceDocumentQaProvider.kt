package com.mill453020.studentplatform

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import android.system.OsConstants
import android.system.ErrnoException
import android.provider.OpenableColumns
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.storage.StorageManager
import android.os.ProxyFileDescriptorCallback

/** Synthetic fixture provider; app-private immutable snapshot, no file path. */
class SourceDocumentQaProvider : ContentProvider() {
    companion object {
        private val transfers = Semaphore(2)
        private val callbacks = HandlerThread("qa-docx-proxies").apply { start() }
        private val callbackHandler = Handler(callbacks.looper)
        private const val leaseMs = 8000L
    }
    override fun onCreate(): Boolean = context?.packageName == "com.mill453020.studentplatform.attachfixture"
    override fun getType(uri: Uri): String = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val ctx = context ?: return null
        val request = uri.lastPathSegment ?: return null
        if (ctx.packageName != "com.mill453020.studentplatform.attachfixture" ||
            uri.authority != "${ctx.packageName}.source_document_qa" || uri.pathSegments.size != 2 ||
            uri.pathSegments[0] != "content" || !Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) return null
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE)
        val row = columns.map { if (it == OpenableColumns.DISPLAY_NAME) "synthetic.docx" else null }.toTypedArray()
        return MatrixCursor(columns).apply { addRow(row) }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val ctx = context ?: throw FileNotFoundException()
        val request = uri.lastPathSegment ?: throw FileNotFoundException()
        if (ctx.packageName != "com.mill453020.studentplatform.attachfixture" || mode != "r" ||
            uri.authority != "${ctx.packageName}.source_document_qa" || uri.pathSegments.size != 2 ||
            uri.pathSegments[0] != "content" || !Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) throw FileNotFoundException()
        val file = File(ctx.filesDir.canonicalFile,"qa_native_fixture_v13/media.db")
        val snapshot = File(ctx.filesDir.canonicalFile,"qa_native_fixture_v13/chat.db")
        if (file.absolutePath != file.canonicalPath || !file.isFile || snapshot.absolutePath != snapshot.canonicalPath || !snapshot.isFile) throw FileNotFoundException()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !transfers.tryAcquire()) throw FileNotFoundException()
        val bytes: ByteArray
        var descriptor: ParcelFileDescriptor? = null
        val released = AtomicBoolean(false)
        val content = AtomicReference<ByteArray?>(null)
        fun release() { if (released.compareAndSet(false,true)) { content.set(null); transfers.release() } }
        try {
            val db = SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                db.execSQL("ATTACH DATABASE ? AS source_snapshot", arrayOf(snapshot.path))
                db.beginTransactionNonExclusive()
                try {
                    val meta = db.rawQuery("SELECT sha,length(bytes),project,uid,sid,chat,message,file,key,url,instance,revision FROM qa_docx_dispatch_snapshot WHERE request=?",arrayOf(request)).use {
                        if (!it.moveToFirst()) throw FileNotFoundException()
                        val sha = it.getString(0); val length = it.getInt(1)
                        val fields = (2..10).map { index -> it.getString(index) ?: throw FileNotFoundException() }
                        val revision = it.getLong(11)
                        if (sha == null || length <= 0 || length > 8*1024*1024 || it.moveToNext()) throw FileNotFoundException()
                        Triple(sha,length,Pair(fields,revision))
                    }
                    val f = meta.third.first
                    val allowed = db.rawQuery("SELECT 1 FROM active_session_registry a JOIN qa_docx_native_owner o ON o.project=a.project AND o.instance=a.instance AND o.revision=a.revision AND o.engine=a.owner_engine WHERE a.project=? AND a.uid=? AND a.sid=? AND a.instance=? AND a.revision=? AND a.state='active'",arrayOf(f[0],f[1],f[2],f[8],meta.third.second.toString())).use { it.count == 1 }
                    if (!allowed) throw FileNotFoundException()
                    val source = SourceDocumentProofQa.Source(f[0],f[1],f[2],f[3],f[4],f[5],f[6],f[7])
                    val current = SourceDocumentProofQa.bytesInTransaction(db,source,snapshot) ?: throw FileNotFoundException()
                    val currentSha = MessageDigest.getInstance("SHA-256").digest(current).joinToString("") { "%02x".format(it) }
                    if (currentSha != meta.first) throw FileNotFoundException()
                    val result = ByteArrayOutputStream(meta.second)
                    var offset = 1
                    while (offset <= meta.second) {
                        val chunk = db.rawQuery("SELECT substr(bytes,?,?) FROM qa_docx_dispatch_snapshot WHERE request=?",arrayOf(offset.toString(),(512*1024).toString(),request)).use {
                            if (!it.moveToFirst()) throw FileNotFoundException()
                            val blob = it.getBlob(0)
                            if (blob == null || blob.isEmpty() || it.moveToNext()) throw FileNotFoundException()
                            blob
                        }
                        result.write(chunk); offset += chunk.size
                    }
                    bytes = result.toByteArray()
                    val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                    if (bytes.size != meta.second || sha != meta.first) throw FileNotFoundException()
                    val manager = ctx.getSystemService(StorageManager::class.java) ?: throw FileNotFoundException()
                    content.set(bytes)
                    descriptor = manager.openProxyFileDescriptor(ParcelFileDescriptor.MODE_READ_ONLY,
                        object : ProxyFileDescriptorCallback() {
                            override fun onGetSize(): Long = (content.get() ?: throw ErrnoException("size",OsConstants.EIO)).size.toLong()
                            override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
                                val bytes = content.get() ?: throw ErrnoException("read",OsConstants.EIO)
                                if (offset < 0 || size < 0 || size > data.size) throw ErrnoException("read",OsConstants.EINVAL)
                                if (offset >= bytes.size) return 0
                                val n = minOf(size,bytes.size-offset.toInt())
                                System.arraycopy(bytes,offset.toInt(),data,0,n)
                                return n
                            }
                            override fun onRelease() = release()
                        }, callbackHandler)
                    callbackHandler.postDelayed({ release() },leaseMs)
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (_: Exception) {
            try { descriptor?.close() } catch (_: Exception) {}
            release()
            throw FileNotFoundException()
        }
        return descriptor ?: run { release(); throw FileNotFoundException() }
    }
}
