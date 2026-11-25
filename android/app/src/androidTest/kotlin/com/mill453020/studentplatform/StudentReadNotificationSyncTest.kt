package com.mill453020.studentplatform

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class StudentReadNotificationSyncTest {
    @Test fun aReadCancelsOnlyItsOwnCardAndSuppressesAnOlderDelayedDisplay() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        check(context.packageName == "com.mill453020.studentplatform.offlinefixture")
        check(Build.VERSION.SDK_INT >= 26)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val uid = UUID.randomUUID().toString()
        val otherUser = UUID.randomUUID().toString()
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        val channel = "student_read_test_$uid"
        fun tag(user: String, id: String) = "student:$user:$id"
        fun display(user: String, id: String) = Intent(StudentReadNotificationSync.RECEIVE)
            .putExtra("recipient_id", user).putExtra("notification_id", id)
            .putExtra("gcm.n.e", "1").putExtra("gcm.n.tag", tag(user, id))
        fun read(user: String, id: String) = Intent(StudentReadNotificationSync.RECEIVE)
            .putExtra("recipient_id", user).putExtra("notification_id", id)
            .putExtra("type", "notification_read").putExtra("version", "1")
            .putExtra("student_sync_action", "dismiss_v1")
        val service = context.packageManager.getServiceInfo(
            ComponentName(context, StudentFirebaseMessagingService::class.java), 0)
        assertFalse(service.exported)
        val receiver = context.packageManager.getReceiverInfo(
            ComponentName(context, StudentFirebaseMessagingReceiver::class.java), 0)
        assertEquals("com.google.android.c2dm.permission.SEND", receiver.permission)
        val ownTags = setOf(tag(uid, first), tag(uid, second), tag(otherUser, first))
        val survivingTags = ownTags - tag(uid, first)
        fun waitForTags(expected: Set<String>) {
            for (i in 1..100) {
                val current = manager.activeNotifications.mapNotNull { it.tag }.intersect(ownTags)
                if (current == expected) return
                Thread.sleep(20)
            }
            fail("Unexpected number or identity of delivered test alerts")
        }
        manager.createNotificationChannel(NotificationChannel(channel, "Read test", NotificationManager.IMPORTANCE_LOW))
        try {
            val card = Notification.Builder(context, channel)
                .setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle("Fixture").build()
            for (t in ownTags) manager.notify(t, 0, card)
            waitForTags(ownTags)
            StudentReadNotificationSync.prepare(context, read(uid, first).putExtra("version", "2"))
            StudentReadNotificationSync.prepare(context, read(uid, first).putExtra("gcm.n.e", "1"))
            StudentReadNotificationSync.prepare(context, read(uid, "invalid"))
            waitForTags(ownTags)
            assertFalse(StudentReadNotificationSync.wasRead(context, tag(uid, first)))
            repeat(2) { StudentReadNotificationSync.prepare(context, read(uid, first)) }
            waitForTags(survivingTags)
            val late = display(uid, first)
            StudentReadNotificationSync.prepare(context, late)
            assertEquals("1", late.getStringExtra("gcm.n.noui"))
            val oldSdkKeys = display(uid, first).apply {
                removeExtra("gcm.n.e")
                removeExtra("gcm.n.tag")
                putExtra("gcm.notification.e", "1")
                putExtra("gcm.notification.tag", tag(uid, first))
            }
            StudentReadNotificationSync.prepare(context, oldSdkKeys)
            assertEquals("1", oldSdkKeys.getStringExtra("gcm.n.noui"))
            for ((user, id) in listOf(uid to second, otherUser to first)) {
                val unaffected = display(user, id)
                StudentReadNotificationSync.prepare(context, unaffected)
                assertFalse(unaffected.hasExtra("gcm.n.noui"))
            }
            val legacy = display(uid, first).apply { removeExtra("gcm.n.tag") }
            StudentReadNotificationSync.prepare(context, legacy)
            assertFalse(legacy.hasExtra("gcm.n.noui"))
        } finally {
            for (t in ownTags) manager.cancel(t, 0)
            manager.deleteNotificationChannel(channel)
        }
    }
}
