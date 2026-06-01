package dev.agentdeck.app

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "dev.agentdeck.app/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importToDownloads" -> {
                        val srcPath = call.argument<String>("srcPath")
                        val fileName = call.argument<String>("fileName")
                        if (srcPath.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error("BAD_ARGS", "srcPath and fileName are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(importToDownloads(srcPath, fileName))
                        } catch (err: Exception) {
                            result.error("SAVE_FAILED", err.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Copies the already-downloaded temp file at [srcPath] into the public
    /// Downloads folder and returns a path the user can recognise. Streaming the
    /// file (rather than receiving its bytes over the method channel) keeps a
    /// large download off the heap. On Android 10+ this uses MediaStore (no
    /// storage permission needed); older versions write the file directly.
    private fun importToDownloads(srcPath: String, fileName: String): String {
        val src = File(srcPath)
        val safeName = uniqueDisplayName(fileName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val collection =
                MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("could not create Downloads entry")
            try {
                resolver.openOutputStream(uri).use { out ->
                    src.inputStream().use { input ->
                        input.copyTo(requireNotNull(out) { "could not open Downloads stream" })
                    }
                }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (err: Exception) {
                // Roll back the pending entry so a failed write leaves no junk row.
                resolver.delete(uri, null, null)
                throw err
            }
            "${Environment.DIRECTORY_DOWNLOADS}/$safeName"
        } else {
            val dir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS,
            )
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, safeName)
            file.outputStream().use { out: OutputStream ->
                src.inputStream().use { input -> input.copyTo(out) }
            }
            file.absolutePath
        }
    }

    /// Pre-Q we can check the filesystem to avoid overwriting; on Q+ MediaStore
    /// auto-deduplicates, so we just return the requested name there.
    private fun uniqueDisplayName(fileName: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return fileName
        val dir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        if (!File(dir, fileName).exists()) return fileName
        val dot = fileName.lastIndexOf('.')
        val stem = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var i = 1
        while (i < 1000) {
            val candidate = "$stem ($i)$ext"
            if (!File(dir, candidate).exists()) return candidate
            i++
        }
        return fileName
    }
}
