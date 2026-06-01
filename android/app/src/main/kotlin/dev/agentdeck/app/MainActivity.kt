package dev.agentdeck.app

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "dev.agentdeck.app/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val fileName = call.argument<String>("fileName")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (fileName.isNullOrBlank() || bytes == null) {
                            result.error("BAD_ARGS", "fileName and bytes are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(saveToDownloads(fileName, bytes))
                        } catch (err: Exception) {
                            result.error("SAVE_FAILED", err.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Writes [bytes] into the public Downloads folder and returns a path the
    /// user can recognise. On Android 10+ this uses MediaStore (no storage
    /// permission needed); older versions write the file directly.
    private fun saveToDownloads(fileName: String, bytes: ByteArray): String {
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
            resolver.openOutputStream(uri).use { out ->
                requireNotNull(out) { "could not open Downloads stream" }.write(bytes)
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            "${Environment.DIRECTORY_DOWNLOADS}/$safeName"
        } else {
            val dir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS,
            )
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, safeName)
            file.outputStream().use { it.write(bytes) }
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
