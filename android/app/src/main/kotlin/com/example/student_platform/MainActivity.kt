package com.example.student_platform

import android.content.Context
import android.os.Build
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

    private lateinit var channel: MethodChannel
    private var captureView: CommitEditText? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
