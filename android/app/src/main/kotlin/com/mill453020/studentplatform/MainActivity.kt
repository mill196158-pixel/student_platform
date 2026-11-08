package com.mill453020.studentplatform

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.os.Build
import android.provider.Settings
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import androidx.core.view.inputmethod.InputConnectionCompat.OnCommitContentListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val startupOrigin = SystemClock.elapsedRealtime()

    private fun startupTrace(stage: String) {
        if (intent?.getBooleanExtra("startupTrace", false) == true) {
            Log.i("StartupTrace", "$stage elapsed=${SystemClock.elapsedRealtime() - startupOrigin}ms uptime=${SystemClock.elapsedRealtime()}ms")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        startupTrace("activity-onCreate-start")
        super.onCreate(savedInstanceState)
        startupTrace("activity-onCreate-end")
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        startupTrace("flutter-ui-displayed")
    }


    private lateinit var channel: MethodChannel
    private var captureView: CommitEditText? = null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (packageName == "com.mill453020.studentplatform.attachfixture") {
            SourceDocumentNativeQa.unregister(flutterEngine)
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        startupTrace("plugins-start")
        super.configureFlutterEngine(flutterEngine)
        startupTrace("plugins-end")
        if (packageName == "com.mill453020.studentplatform.attachfixture") {
            SourceDocumentNativeQa.register(flutterEngine, primary = true)
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
                "student_platform/source_document_qa_guard").setMethodCallHandler { call, result ->
                val args = call.arguments as? Map<*, *>
                when (call.method) {
                    "dispatchSynthetic" -> result.success(args != null && SourceDocumentQaGuard.dispatch(this, args))
                    "verifyRealSchemaSynthetic" -> Thread {
                        val value = args != null && SourceDocumentProofQa.verifyFixture(this, args)
                        runOnUiThread { result.success(value) }
                    }.start()
                    "claimNativeOwnerSynthetic" -> result.success(args != null && SourceDocumentNativeQa.claim(this, flutterEngine, args))
                    "dispatchRealSchemaSynthetic" -> Thread {
                        val value = if (args == null) "blocked" else SourceDocumentNativeQa.dispatch(this, flutterEngine, args)
                        runOnUiThread { result.success(value) }
                    }.start()
                    "readPreparedSynthetic" -> Thread {
                        val request = args?.get("request") as? String
                        val value = try {
                            if (request == null || !Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) null else {
                                val uri = Uri.parse("content://${packageName}.source_document_qa/content/$request")
                                contentResolver.openInputStream(uri)?.use { input ->
                                    val digest = java.security.MessageDigest.getInstance("SHA-256")
                                    val buffer = ByteArray(64*1024)
                                    var total = 0
                                    while (true) {
                                        val n = input.read(buffer)
                                        if (n < 0) break
                                        total += n
                                        if (total > 8*1024*1024) throw IllegalStateException()
                                        digest.update(buffer,0,n)
                                    }
                                    digest.digest().joinToString("") { "%02x".format(it) }
                                }
                            }
                        } catch (_: Exception) { null }
                        runOnUiThread { result.success(value) }
                    }.start()
                    "holdPreparedSynthetic" -> Thread {
                        val request = args?.get("request") as? String
                        val value = try {
                            if (request == null || !Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) false else {
                                val uri = Uri.parse("content://${packageName}.source_document_qa/content/$request")
                                val opened = mutableListOf<android.os.ParcelFileDescriptor>()
                                try {
                                    val first = contentResolver.openFileDescriptor(uri,"r")?.also { opened.add(it) }
                                    val second = contentResolver.openFileDescriptor(uri,"r")?.also { opened.add(it) }
                                    val third = try { contentResolver.openFileDescriptor(uri,"r")?.also { opened.add(it) } } catch (_: Exception) { null }
                                    if (first == null || second == null || third != null) false else {
                                        Thread.sleep(5500)
                                        val afterTimeout = contentResolver.openFileDescriptor(uri,"r")?.also { opened.add(it) }
                                        afterTimeout != null
                                    }
                                } finally { opened.forEach { try { it.close() } catch (_: Exception) {} } }
                            }
                        } catch (_: Exception) { false }
                        runOnUiThread { result.success(value) }
                    }.start()
                    "dispatchOtherEngineSynthetic" -> {
                        val other = FlutterEngine(applicationContext)
                        SourceDocumentNativeQa.register(other, primary = false)
                        Thread {
                            val value = if (args == null) "blocked" else SourceDocumentNativeQa.dispatch(this, other, args)
                            runOnUiThread { SourceDocumentNativeQa.unregister(other); other.destroy(); result.success(value) }
                        }.start()
                    }
                    "claimOtherEngineSynthetic" -> {
                        val other = FlutterEngine(applicationContext)
                        SourceDocumentNativeQa.register(other, primary = false)
                        try { result.success(args != null && SourceDocumentNativeQa.claim(this, other, args)) }
                        finally { SourceDocumentNativeQa.unregister(other); other.destroy() }
                    }
                    "claimPrimaryContenderSynthetic" -> {
                        val other = FlutterEngine(applicationContext)
                        SourceDocumentNativeQa.register(other, primary = true)
                        try { result.success(args != null && SourceDocumentNativeQa.claim(this, other, args)) }
                        finally { SourceDocumentNativeQa.unregister(other); other.destroy() }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "student_platform/storage_space").setMethodCallHandler { call, result ->
            if (call.method == "availableSupportBytes") {
                try {
                    val bytes = filesDir.usableSpace
                    result.success(if (bytes > 0) bytes else null)
                } catch (_: Exception) { result.success(null) }
            } else result.notImplemented()
        }
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "keyboard_image_channel"
        )

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "focus" -> {
                    ensureCaptureView()
                    showKeyboard()
                    result.success(null)
                }
                "dispose" -> {
                    removeCaptureView()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "student_platform/notifications"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "clearNotifications" -> {
                    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancelAll()
                    result.success(null)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "student_platform/topic_ocr"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> {
                    Thread {
                        try {
                            val ok = TopicOcrRecognizer.isAvailable(applicationContext)
                            runOnUiThread { result.success(ok) }
                        } catch (_: Exception) {
                            runOnUiThread { result.success(false) }
                        }
                    }.start()
                }
                "recognize" -> {
                    val args = call.arguments as? Map<*, *>
                    val path = args?.get("path") as? String
                    val languages = (args?.get("languages") as? String) ?: "rus+eng"
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "Путь к изображению не передан.", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val text = TopicOcrRecognizer.recognize(
                                context = applicationContext,
                                imagePath = path,
                                languages = languages,
                            )
                            runOnUiThread { result.success(text) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "ocr_error",
                                    e.message ?: "Не удалось распознать текст.",
                                    null,
                                )
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openNotificationSettings() {
        val intent = Intent().apply {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                    action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
                else -> {
                    action = Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                    data = Uri.fromParts("package", packageName, null)
                }
            }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun ensureCaptureView() {
        if (captureView != null) return

        val v = CommitEditText(this).apply {
            // «невидимый» едитекст внизу экрана
            setSingleLine(true)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 1f)
            setPadding(0, 0, 0, 0)
            background = null
            alpha = 0f
            isFocusable = true
            isFocusableInTouchMode = true
            imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
            inputType = InputType.TYPE_CLASS_TEXT
            layoutParams = FrameLayout.LayoutParams(
                1, 1, Gravity.BOTTOM or Gravity.START
            )
        }

        addContentView(v, v.layoutParams)
        captureView = v
    }

    private fun showKeyboard() {
        val v = captureView ?: return
        v.requestFocus()
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(v, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun removeCaptureView() {
        val v = captureView ?: return
        (v.parent as? ViewGroup)?.removeView(v)
        captureView = null
    }

    /** EditText, который принимает контент из клавиатуры (GIF/WEBP/PNG/JPEG) */
    inner class CommitEditText(ctx: Context) : EditText(ctx) {
        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
            val ic = super.onCreateInputConnection(outAttrs)

            // Разрешаем типы, которые умеет отдавать клавиатура
            EditorInfoCompat.setContentMimeTypes(
                outAttrs,
                arrayOf(
                    "image/gif",
                    "image/webp",
                    "image/png",
                    "image/jpeg",
                    "image/*"
                )
            )

            val callback = OnCommitContentListener { info, flags, _ ->
                if (Build.VERSION.SDK_INT >= 25 &&
                    (flags and InputConnectionCompat.INPUT_CONTENT_GRANT_READ_URI_PERMISSION) != 0
                ) {
                    try { info.requestPermission() } catch (_: Exception) {}
                }

                try {
                    val uri = info.contentUri
                    val mime = contentResolver.getType(uri) ?: ""
                    val ext = when {
                        mime.contains("gif") -> "gif"
                        mime.contains("webp") -> "webp"
                        mime.contains("png") -> "png"
                        else -> "jpg"
                    }
                    val file = File(cacheDir, "kb_${System.currentTimeMillis()}.$ext")
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(file).use { output -> input.copyTo(output) }
                    }
                    // отправляем путь в Dart
                    channel.invokeMethod("onPicked", file.absolutePath)
                } catch (_: Exception) {
                } finally {
                    if (Build.VERSION.SDK_INT >= 25) {
                        try { info.releasePermission() } catch (_: Exception) {}
                    }
                }
                true
            }

            return InputConnectionCompat.createWrapper(ic, outAttrs, callback)
        }
    }
}
