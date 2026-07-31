package com.mill453020.studentplatform

import android.content.Context
import android.graphics.BitmapFactory
import com.googlecode.tesseract.android.TessBaseAPI
import java.io.File
import java.io.FileOutputStream

/** On-device Tesseract OCR for topic-list images (rus+eng). Never logs text. */
object TopicOcrRecognizer {
    /** True when bundled rus+eng tessdata can be prepared offline. */
    fun isAvailable(context: Context): Boolean {
        return try {
            val dataPath = ensureTessdata(context)
            val tessDir = File(dataPath, "tessdata")
            val rus = File(tessDir, "rus.traineddata")
            val eng = File(tessDir, "eng.traineddata")
            rus.exists() && rus.length() > 1024L && eng.exists() && eng.length() > 1024L
        } catch (_: Exception) {
            false
        }
    }

    fun recognize(
        context: Context,
        imagePath: String,
        languages: String = "rus+eng",
    ): String {
        val imageFile = File(imagePath)
        if (!imageFile.exists()) {
            throw IllegalArgumentException("Файл изображения не найден.")
        }
        val bitmap = BitmapFactory.decodeFile(imagePath)
            ?: throw IllegalArgumentException("Не удалось открыть изображение.")

        val dataPath = ensureTessdata(context)
        val api = TessBaseAPI()
        try {
            if (!api.init(dataPath, languages)) {
                throw IllegalStateException("Не удалось инициализировать OCR.")
            }
            api.setImage(bitmap)
            val text = api.getUTF8Text()?.trim().orEmpty()
            if (text.isEmpty()) {
                throw IllegalStateException(
                    "Не удалось распознать текст на изображении. Попробуйте другое фото.",
                )
            }
            return text
        } finally {
            api.recycle()
            bitmap.recycle()
        }
    }

    private fun ensureTessdata(context: Context): String {
        val baseDir = File(context.filesDir, "topic_ocr")
        val tessDir = File(baseDir, "tessdata")
        if (!tessDir.exists()) {
            tessDir.mkdirs()
        }
        for (name in listOf("rus.traineddata", "eng.traineddata")) {
            val out = File(tessDir, name)
            if (out.exists() && out.length() > 1024L) continue
            val assetPath = "flutter_assets/assets/tessdata/$name"
            val tmp = File(tessDir, "$name.partial")
            context.assets.open(assetPath).use { input ->
                FileOutputStream(tmp).use { output -> input.copyTo(output) }
            }
            if (!tmp.renameTo(out)) {
                tmp.copyTo(out, overwrite = true)
                tmp.delete()
            }
        }
        return baseDir.absolutePath
    }
}
