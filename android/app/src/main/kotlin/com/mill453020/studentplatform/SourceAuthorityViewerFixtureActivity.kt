package com.mill453020.studentplatform

import android.app.Activity
import android.os.Bundle
import java.io.File
import java.security.MessageDigest

/** Isolated synthetic receiver, never enabled in the ordinary package. */
class SourceAuthorityViewerFixtureActivity:Activity() {
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        Thread {
            val status=try {
                val uri=intent?.data ?: throw IllegalStateException()
                val digest=MessageDigest.getInstance("SHA-256")
                contentResolver.openInputStream(uri).use { input ->
                    val stream=input ?: throw IllegalStateException()
                    val buffer=ByteArray(65536)
                    while(true) { val n=stream.read(buffer); if(n<0) break; digest.update(buffer,0,n) }
                }
                "ok:"+digest.digest().joinToString("") { "%02x".format(it) }
            } catch (_:Exception) { "failed" }
            File(filesDir,"qa_authority_viewer_result").writeText(status)
            runOnUiThread { finish() }
        }.start()
    }
}
