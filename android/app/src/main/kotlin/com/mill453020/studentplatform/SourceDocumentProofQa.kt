package com.mill453020.studentplatform

import android.database.sqlite.SQLiteDatabase
import android.app.Activity
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/** QA-only verification of the actual source-bound schema; not a dispatcher. */
internal object SourceDocumentProofQa {
    data class Source(val project: String, val uid: String, val sid: String,
        val chat: String, val message: String, val file: String, val key: String, val url: String)

    private fun hash(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    fun verifyFixture(activity: Activity, args: Map<*, *>): Boolean {
        if (activity.packageName != "com.mill453020.studentplatform.attachfixture") return false
        val names = listOf("project","uid","sid","chat","message","file","key","url")
        val values = names.map { args[it] as? String ?: return false }
        val media = File(args["media"] as? String ?: return false)
        val snapshot = File(args["chatDb"] as? String ?: return false)
        try {
            Log.i("SourceProofQA", "VERIFY_PATH")
            Log.i("SourceProofQA", "PATH_CANON_ROOT")
            val expectedRoot = File(activity.filesDir.canonicalFile,"qa_native_fixture_v9")
            val expectedMedia = File(expectedRoot,"media.db")
            val expectedSnapshot = File(expectedRoot,"chat.db")
            if (expectedMedia.absolutePath != expectedMedia.canonicalPath || expectedSnapshot.absolutePath != expectedSnapshot.canonicalPath ||
                media.canonicalPath != expectedMedia.absolutePath || snapshot.canonicalPath != expectedSnapshot.absolutePath ||
                !media.isFile || !snapshot.isFile || media == snapshot) { Log.i("SourceProofQA", "PATH_REJECT"); return false }
            Log.i("SourceProofQA", "PATH_OK")
            val db = SQLiteDatabase.openDatabase(media.canonicalPath,null,SQLiteDatabase.OPEN_READWRITE)
            try {
                Log.i("SourceProofQA", "DB_OPEN_OK")
                db.rawQuery("PRAGMA busy_timeout=0", null).use { it.moveToFirst() }
                Log.i("SourceProofQA", "PRAGMA_OK")
                db.execSQL("ATTACH DATABASE ? AS source_snapshot", arrayOf(snapshot.canonicalPath))
                Log.i("SourceProofQA", "ATTACH_OK")
                db.beginTransactionNonExclusive()
                try {
                    Log.i("SourceProofQA", "TXN_OK")
                    Log.i("SourceProofQA", "VERIFY_SOURCE")
                    val result = bytesInTransaction(db, Source(values[0],values[1],values[2],values[3],
                        values[4],values[5],values[6],values[7]), expectedSnapshot) != null
                    Log.i("SourceProofQA", if (result) "VERIFY_OK" else "VERIFY_REJECT")
                    db.setTransactionSuccessful()
                    return result
                } finally { db.endTransaction() }
            } finally { db.close() }
        } catch (e: Exception) { Log.i("SourceProofQA", "VERIFY_EXCEPTION type=${e.javaClass.simpleName}"); return false }
    }

    // Android and Dart JSON quote differently for slash and non-ASCII in some
    // versions; fail closed unless their byte representation is unambiguous.
    private fun fenceId(s: Source): String? {
        val parts = listOf(s.project, s.uid, s.key)
        if (parts.any { it.any { ch -> ch.code < 0x20 || ch.code > 0x7e || ch == '"' || ch == '\\' } }) return null
        val encoded = parts.joinToString(",", "[", "]") { "\"$it\"" }
        return hash(encoded.toByteArray(Charsets.UTF_8))
    }

    /** Caller owns BEGIN IMMEDIATE and must keep it through native dispatch. */
    fun bytesInTransaction(db: SQLiteDatabase, s: Source, expectedSnapshot: File): ByteArray? {
        if (!db.inTransaction() || listOf(s.project,s.uid,s.sid,s.chat,s.message,s.file,s.key,s.url).any { it.isEmpty() }) return null
        if (s.message.startsWith("local_")) return null
        try {
            Log.i("SourceProofQA", "SOURCE_ATTACH")
            val snapshotPath = db.rawQuery("PRAGMA database_list",null).use {
                var found: String? = null
                while (it.moveToNext()) if (it.getString(1) == "source_snapshot") {
                    if (found != null) return null
                    found = it.getString(2)
                }
                found
            } ?: return null
            if (expectedSnapshot.absolutePath != expectedSnapshot.canonicalPath ||
                File(snapshotPath).absolutePath != expectedSnapshot.canonicalPath || !expectedSnapshot.isFile) return null
            val sourceArgs = arrayOf(s.project,s.uid,s.sid,s.chat,s.message,s.file)
            Log.i("SourceProofQA", "SOURCE_DOCUMENT")
            val where = "project=? AND uid=? AND sid=? AND chat=? AND message=? AND file=?"
            val documentMeta = db.rawQuery("SELECT key,url,sha,length(bytes) FROM source_bound_documents WHERE $where",sourceArgs).use {
                if (!it.moveToFirst()) return null
                val key = it.getString(0); val url = it.getString(1); val sha = it.getString(2); val length = it.getInt(3)
                if (it.moveToNext() || key != s.key || url != s.url || sha == null || length <= 0 || length > 8*1024*1024) return null
                Pair(sha, length)
            }
            val output = ByteArrayOutputStream(documentMeta.second)
            var offset = 1
            while (offset <= documentMeta.second) {
                val chunk = db.rawQuery("SELECT substr(bytes,?,?) FROM source_bound_documents WHERE $where",
                    arrayOf(offset.toString(), (512*1024).toString(), *sourceArgs)).use {
                    if (!it.moveToFirst()) return null
                    val blob = it.getBlob(0)
                    if (blob == null || blob.isEmpty() || it.moveToNext()) return null
                    blob
                }
                output.write(chunk)
                offset += chunk.size
            }
            val document = Pair(documentMeta.first, output.toByteArray())
            if (document.second.size != documentMeta.second || hash(document.second) != document.first) return null
            val id = fenceId(s) ?: return null
            Log.i("SourceProofQA", "SOURCE_FENCE")
            val fenceRevision = db.rawQuery("SELECT revision,denied,dirty,content_hash FROM pinned_fence_state WHERE id=?",arrayOf(id)).use {
                if (!it.moveToFirst()) return null
                val revision = it.getLong(0)
                if (it.getInt(1) != 0 || it.getInt(2) != 0 || it.getString(3) != document.first || it.moveToNext()) return null
                revision
            }
            if (db.rawQuery("SELECT 1 FROM pinned_fence_pending WHERE id=? LIMIT 1",arrayOf(id)).use { it.moveToFirst() }) return null
            val proof = db.rawQuery("SELECT revision,sha FROM source_bound_proofs WHERE $where",sourceArgs).use {
                it.moveToFirst() && it.getLong(0) == fenceRevision && it.getString(1) == document.first && !it.moveToNext()
            }
            if (!proof || db.rawQuery("SELECT 1 FROM media_cache_logout_tombstones WHERE project=? AND uid=? AND sid=? LIMIT 1",arrayOf(s.project,s.uid,s.sid)).use { it.moveToFirst() }) return null
            val chatArgs = arrayOf(s.project,s.uid,s.sid,s.chat)
            Log.i("SourceProofQA", "SOURCE_CHAT")
            val attempt = db.rawQuery("SELECT blocked FROM source_snapshot.chat_server_attempt WHERE project=? AND uid=? AND sid=? AND chat=?",chatArgs).use {
                it.moveToFirst() && it.getInt(0) == 0 && !it.moveToNext()
            }
            if (!attempt) return null
            val payload = db.rawQuery("SELECT payload FROM source_snapshot.chat_server_snapshot WHERE project=? AND uid=? AND sid=? AND chat=?",chatArgs).use {
                if (!it.moveToFirst()) return null
                val value = it.getString(0)
                if (value == null || value.length > 8*1024*1024 || it.moveToNext()) return null
                value
            }
            val messages = JSONArray(payload)
            Log.i("SourceProofQA", "SOURCE_MESSAGE")
            var foundMessage: JSONObject? = null
            for (i in 0 until messages.length()) {
                val m = messages.optJSONObject(i) ?: continue
                if (m.optString("id") == s.message && m.optString("chat_id") == s.chat) {
                    if (foundMessage != null) return null
                    foundMessage = m
                }
            }
            val message = foundMessage ?: return null
            if (!message.isNull("client_id") || message.optString("delivery_status") != "sent") return null
            val attachments = message.optJSONArray("attachments") ?: return null
            Log.i("SourceProofQA", "SOURCE_ATTACHMENT")
            var foundFile: JSONObject? = null
            for (i in 0 until attachments.length()) {
                val f = attachments.optJSONObject(i) ?: continue
                if (f.optString("id") == s.file) { if (foundFile != null) return null; foundFile = f }
            }
            val f = foundFile ?: return null
            if (f.optString("chat_id") != s.chat || f.optString("message_id") != s.message ||
                f.optString("file_key") != s.key || f.optString("file_url") != s.url ||
                !f.has("is_deleted") || f.opt("is_deleted") != false || f.opt("deletion_verified") != true) return null
            return document.second
        } catch (_: Exception) { return null }
    }
}
