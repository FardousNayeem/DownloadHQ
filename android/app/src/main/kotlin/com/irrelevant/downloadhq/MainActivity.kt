package com.irrelevant.downloadhq

import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Thin bridge to youtubedl-android. Dart builds every yt-dlp argument; this
 * side only runs them off the main thread and streams progress back.
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var progressSink: EventChannel.EventSink? = null
    private var shareChannel: MethodChannel? = null

    /** Text of the share that launched the app, until Dart asks for it. */
    private var initialShare: String? = null

    @Volatile
    private var ready = false

    /** Unpacks Python/yt-dlp/ffmpeg on first use; slow once, instant after. */
    @Synchronized
    private fun ensureInit() {
        if (ready) return
        YoutubeDL.getInstance().init(applicationContext)
        FFmpeg.getInstance().init(applicationContext)
        ready = true
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                ensureInit()
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("ytdlp", e.message, null) }
            }
        }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        initialShare = sharedText(intent)
        shareChannel = MethodChannel(messenger, "downloadhq/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initial") {
                    result.success(initialShare)
                    initialShare = null
                } else {
                    result.notImplemented()
                }
            }
        }

        EventChannel(messenger, "downloadhq/ytdlp/progress").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })

        MethodChannel(messenger, "downloadhq/ytdlp").setMethodCallHandler { call, result ->
            when (call.method) {
                "nativeLibDir" -> result.success(applicationInfo.nativeLibraryDir)
                "version" -> background(result) { YoutubeDL.getInstance().version(applicationContext) }
                "update" -> background(result) {
                    YoutubeDL.getInstance().updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel.STABLE)
                    YoutubeDL.getInstance().version(applicationContext)
                }
                "cancel" -> {
                    YoutubeDL.getInstance().destroyProcessById(call.argument<String>("id")!!)
                    result.success(null)
                }
                "run" -> {
                    val id = call.argument<String>("id")!!
                    val args = call.argument<List<String>>("args")!!
                    background(result) { run(id, args) }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        sharedText(intent)?.let { shareChannel?.invokeMethod("shared", it) }
    }

    private fun sharedText(intent: Intent?): String? =
        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            intent.getStringExtra(Intent.EXTRA_TEXT)
        } else {
            null
        }

    private fun run(id: String, args: List<String>): Map<String, Any> {
        val request = YoutubeDLRequest(emptyList<String>()).addCommands(args)
        return try {
            val r = YoutubeDL.getInstance().execute(request, id) { progress, eta, line ->
                main.post {
                    progressSink?.success(mapOf("id" to id, "progress" to progress, "eta" to eta, "line" to line))
                }
            }
            mapOf("code" to r.exitCode, "out" to r.out, "err" to r.err)
        } catch (e: YoutubeDL.CanceledException) {
            mapOf("code" to -1, "out" to "", "err" to "ERROR: Cancelled")
        } catch (e: YoutubeDLException) {
            // Non-zero exit arrives as an exception whose message is stderr.
            mapOf("code" to 1, "out" to "", "err" to (e.message ?: "yt-dlp failed"))
        }
    }
}
