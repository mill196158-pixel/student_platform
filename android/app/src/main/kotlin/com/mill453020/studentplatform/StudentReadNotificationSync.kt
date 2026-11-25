package com.mill453020.studentplatform

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingReceiver
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/** Handles FCM in the same private service as normal FlutterFire delivery. */
class StudentFirebaseMessagingService : FlutterFirebaseMessagingService() {
    override fun handleIntent(intent: Intent) {
        if (intent.action != StudentReadNotificationSync.RECEIVE) {
            super.handleIntent(intent) // Includes FlutterFire's onNewToken callback.
            return
        }
        val revision = StudentReadNotificationSync.revision.get()
        val displayTag = StudentReadNotificationSync.prepare(this, intent)
        // Keep Firebase's own acknowledgement, deduplication and tap behavior.
        super.handleIntent(intent)
        if (displayTag != null && revision != StudentReadNotificationSync.revision.get() &&
            StudentReadNotificationSync.wasRead(this, displayTag)) {
            // A foreground read may have completed while Firebase built the alert.
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(displayTag, 0)
        }
    }
}

/** Firebase's transport receiver still delivers controls to the private service.
 * The FlutterFire receiver only forwards user-visible events to Dart. */
class StudentFirebaseMessagingReceiver : FlutterFirebaseMessagingReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == StudentReadNotificationSync.RECEIVE && StudentReadNotificationSync.isControl(intent)) return
        super.onReceive(context, intent)
    }
}

object StudentReadNotificationSync {
    internal const val RECEIVE = "com.google.android.c2dm.intent.RECEIVE"
    private const val TTL_MS = 35L * 24 * 60 * 60 * 1000
    private const val UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    private val address = Regex("student:${UUID}:${UUID}")
    internal val revision = AtomicLong()
    private val unsaved = mutableMapOf<String, Long>()
    private var helper: ReadStore? = null

    private class ReadStore(context: Context) : SQLiteOpenHelper(context,
        File(context.noBackupFilesDir, "student_read_notifications_v1.db").absolutePath, null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE read_alert(tag TEXT PRIMARY KEY, seen_ms INTEGER NOT NULL)")
            db.execSQL("CREATE INDEX read_alert_expiry ON read_alert(seen_ms)")
        }
        override fun onUpgrade(db: SQLiteDatabase, from: Int, to: Int) = Unit
    }

    @Synchronized private fun store(context: Context): ReadStore =
        helper ?: ReadStore(context.applicationContext).also { helper = it }

    internal fun isControl(intent: Intent) = intent.getStringExtra("type") == "notification_read" ||
        intent.hasExtra("student_sync_action")

    private fun debug(context: Context, event: String) {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) Log.d("StudentPush", event)
    }

    /** On entry the Firebase transport has authenticated the sender. Do not use with deep links. */
    internal fun prepare(context: Context, intent: Intent): String? {
        val extras = intent.extras ?: return null
        // Use Firebase's own normalization of gcm.n.* and gcm.notification.*.
        val notification = RemoteMessage(extras).notification
        val tag = "student:${intent.getStringExtra("recipient_id")}:${intent.getStringExtra("notification_id")}"
        if (isControl(intent)) {
            if (notification == null && intent.getStringExtra("type") == "notification_read" &&
                intent.getStringExtra("version") == "1" &&
                intent.getStringExtra("student_sync_action") == "dismiss_v1" && address.matches(tag)) {
                dismiss(context, tag)
                debug(context, "received_read_control")
            }
            // Even a malformed control can never become a visible alert.
            intent.putExtra("gcm.n.noui", "1")
            return null
        }
        if (notification == null) return null
        if (!address.matches(tag) || notification.tag != tag) {
            debug(context, "display_without_matching_address")
            return null
        }
        if (wasRead(context, tag)) {
            intent.putExtra("gcm.n.noui", "1")
            debug(context, "suppressed_read_display")
        } else {
            debug(context, "received_unread_display")
        }
        return tag
    }

    fun dismiss(context: Context, tag: String, id: Int = 0): Boolean {
        if (!address.matches(tag)) return false
        val now = System.currentTimeMillis()
        synchronized(unsaved) {
            unsaved.entries.removeAll { it.value < now - TTL_MS }
            unsaved[tag] = now
        }
        revision.incrementAndGet()
        try {
            val db = store(context).writableDatabase
            db.execSQL("INSERT OR REPLACE INTO read_alert(tag,seen_ms) VALUES(?,?)", arrayOf(tag, now))
            synchronized(unsaved) { if (unsaved[tag] == now) unsaved.remove(tag) }
            db.delete("read_alert", "seen_ms < ?", arrayOf((now - TTL_MS).toString()))
        } catch (_: SQLiteException) {
            // A full device must still dismiss an already displayed alert.
        } finally {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(tag, id)
        }
        return true
    }

    internal fun wasRead(context: Context, tag: String): Boolean {
        val cutoff = System.currentTimeMillis() - TTL_MS
        if (synchronized(unsaved) { (unsaved[tag] ?: 0L) >= cutoff }) return true
        return try {
            store(context).readableDatabase.rawQuery("SELECT 1 FROM read_alert WHERE tag=? AND seen_ms>=?",
                arrayOf(tag, cutoff.toString())).use { it.moveToFirst() }
        } catch (_: SQLiteException) {
            false
        }
    }
}
