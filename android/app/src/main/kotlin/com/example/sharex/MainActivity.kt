package com.example.sharex

import android.content.ContentResolver
import android.net.Uri
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.sharex/file_utils"
    private val TAG = "ShareXFileUtils"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyContentUri" -> {
                    val sourceUri = call.argument<String>("sourceUri")
                    val destinationPath = call.argument<String>("destinationPath")
                    
                    if (sourceUri == null || destinationPath == null) {
                        Log.e(TAG, "Missing required parameters for copyContentUri")
                        result.error("MISSING_ARGS", "Missing sourceUri or destinationPath", null)
                        return@setMethodCallHandler
                    }
                    
                    try {
                        val success = copyContentUri(sourceUri, destinationPath)
                        result.success(success)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error copying content URI: ${e.message}")
                        result.error("COPY_ERROR", "Failed to copy content URI: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    
    private fun copyContentUri(sourceUriString: String, destinationPath: String): Boolean {
        Log.d(TAG, "Copying from $sourceUriString to $destinationPath")
        val contentUri = Uri.parse(sourceUriString)
        val destinationFile = File(destinationPath)
        
        // Create parent directories if they don't exist
        destinationFile.parentFile?.mkdirs()
        
        try {
            contentResolver.openInputStream(contentUri)?.use { inputStream ->
                FileOutputStream(destinationFile).use { outputStream ->
                    val buffer = ByteArray(1024)
                    var length: Int
                    var totalCopied = 0L
                    
                    while (inputStream.read(buffer).also { length = it } > 0) {
                        outputStream.write(buffer, 0, length)
                        totalCopied += length
                    }
                    
                    Log.d(TAG, "Successfully copied $totalCopied bytes")
                    return true
                }
            } ?: run {
                Log.e(TAG, "Failed to open input stream for URI")
                return false
            }
        } catch (e: IOException) {
            Log.e(TAG, "IOException during copy: ${e.message}")
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Exception during copy: ${e.message}")
            return false
        }
    }
}
