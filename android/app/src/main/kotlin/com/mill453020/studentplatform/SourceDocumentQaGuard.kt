package com.mill453020.studentplatform

import android.app.Activity
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import java.io.File

/** Synthetic fixture only: this does not authorize or export real documents. */
internal object SourceDocumentQaGuard {
    fun dispatch(activity: Activity, args: Map<*, *>): Boolean {
        if (activity.packageName != "com.mill453020.studentplatform.attachfixture") return false
        val mediaArg = args["media"] as? String ?: return false
        val chatArg = args["chat"] as? String ?: return false
        val request = args["request"] as? String ?: return false
        if (!Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) return false
        val root = activity.filesDir.canonicalFile
        val media = File(mediaArg).canonicalFile
        val chat = File(chatArg).canonicalFile
        if (!media.path.startsWith(root.path + File.separator) ||
            !chat.path.startsWith(root.path + File.separator) ||
            media == chat || !media.isFile || !chat.isFile) return false
        var db: SQLiteDatabase? = null
        try {
            val database = SQLiteDatabase.openDatabase(media.path, null, SQLiteDatabase.OPEN_READWRITE)
            db = database
            database.execSQL("PRAGMA busy_timeout=0")
            database.execSQL("ATTACH DATABASE ? AS source_snapshot", arrayOf(chat.path))
            // Commit the unique reservation before any OS side effect. A crash
            // leaves it behind and the same request must never be replayed.
            database.beginTransactionNonExclusive()
            try {
                database.execSQL("INSERT INTO qa_dispatch(request,state) VALUES(?, 'reserved')", arrayOf(request))
                database.setTransactionSuccessful()
            } finally { database.endTransaction() }
            database.beginTransactionNonExclusive()
            try {
                fun exactlyOne(sql: String, args: Array<String>): Boolean =
                    database.rawQuery(sql, args).use { it.count == 1 }
                if (!exactlyOne("SELECT uid FROM qa_active_session WHERE uid=? AND sid=? AND active=1",
                        arrayOf("synthetic-user", "synthetic-session")) ||
                    !exactlyOne("SELECT revision FROM qa_fence WHERE revision=1 AND denied=0", emptyArray()) ||
                    !exactlyOne("SELECT revision FROM source_snapshot.qa_source WHERE uid=? AND sid=? AND revision=1 AND active=1",
                        arrayOf("synthetic-user", "synthetic-session"))) return false
                // Only a fixed non-user synthetic text is ever dispatched.
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, "Synthetic fixture; no user data")
                }
                activity.startActivity(Intent.createChooser(intent, "Synthetic QA"))
                database.execSQL("UPDATE qa_dispatch SET state='started' WHERE request=?", arrayOf(request))
                database.setTransactionSuccessful()
                return true
            } finally { database.endTransaction() }
        } catch (_: Exception) {
            return false
        } finally { db?.close() }
    }
}
