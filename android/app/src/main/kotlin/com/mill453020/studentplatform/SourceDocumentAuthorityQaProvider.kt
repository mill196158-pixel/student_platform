package com.mill453020.studentplatform

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.OsConstants
import java.io.FileNotFoundException
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** QA only. A handed-off FD may live until its bounded lease expires. */
class SourceDocumentAuthorityQaProvider:ContentProvider() {
    companion object {
        private val slots=Semaphore(2)
        private val worker=HandlerThread("qa-authority-docs").apply { start() }
        private val handler=Handler(worker.looper)
    }
    override fun onCreate():Boolean = context?.packageName in setOf("com.mill453020.studentplatform.authorityqa","com.mill453020.studentplatform.authoritysourcediagnosticv6")
    override fun getType(uri:Uri):String = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    private fun request(uri:Uri):String? {
        val ctx=context ?: return null
        if (uri.authority!="${ctx.packageName}.authority_document_qa" || uri.pathSegments.size!=2 || uri.pathSegments[0]!="document") return null
        return uri.lastPathSegment?.takeIf { Regex("^[A-Za-z0-9_-]{16,80}$").matches(it) }
    }
    override fun query(uri:Uri,projection:Array<out String>?,selection:String?,selectionArgs:Array<out String>?,sortOrder:String?):Cursor? {
        if (request(uri)==null) return null
        val columns=projection ?: arrayOf(OpenableColumns.DISPLAY_NAME)
        return MatrixCursor(columns).apply { addRow(columns.map { if(it==OpenableColumns.DISPLAY_NAME) "document.docx" else null }.toTypedArray()) }
    }
    override fun openFile(uri:Uri,mode:String):ParcelFileDescriptor {
        val ctx=context ?: throw FileNotFoundException()
        val id=request(uri) ?: throw FileNotFoundException()
        if(mode!="r" || Build.VERSION.SDK_INT<Build.VERSION_CODES.O || !slots.tryAcquire()) throw FileNotFoundException()
        val released=AtomicBoolean(false)
        val content=AtomicReference<ByteArray?>(null)
        fun release() { if(released.compareAndSet(false,true)) { content.set(null); slots.release() } }
        try {
            content.set(SourceDocumentAuthorityQa.providerBytes(ctx,id) ?: throw FileNotFoundException())
            val manager=ctx.getSystemService(StorageManager::class.java) ?: throw FileNotFoundException()
            val fd=manager.openProxyFileDescriptor(ParcelFileDescriptor.MODE_READ_ONLY,object:ProxyFileDescriptorCallback() {
                override fun onGetSize():Long=(content.get() ?: throw ErrnoException("size",OsConstants.EIO)).size.toLong()
                override fun onRead(offset:Long,size:Int,data:ByteArray):Int {
                    val bytes=content.get() ?: throw ErrnoException("read",OsConstants.EIO)
                    if(offset<0 || size<0 || size>data.size) throw ErrnoException("read",OsConstants.EINVAL)
                    if(offset>=bytes.size) return 0
                    val n=minOf(size,bytes.size-offset.toInt()); System.arraycopy(bytes,offset.toInt(),data,0,n); return n
                }
                override fun onRelease()=release()
            },handler)
            handler.postDelayed({ release() },8000L)
            return fd
        } catch (_:Exception) { release(); throw FileNotFoundException() }
    }
    override fun insert(uri:Uri,values:ContentValues?):Uri?=null
    override fun delete(uri:Uri,selection:String?,selectionArgs:Array<out String>?):Int=0
    override fun update(uri:Uri,values:ContentValues?,selection:String?,selectionArgs:Array<out String>?):Int=0
}
