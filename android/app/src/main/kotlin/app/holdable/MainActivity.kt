package app.holdable

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Debug
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val gpuChannel = "holdable/gpu"
    private val notifyChannel = "holdable/notify"
    private var handTracker: HandTracker? = null

    /// #6: "conversion finished" heads-up while the app is backgrounded. Plain
    /// android.app Notification (minSdk 28 ⇒ channels exist) via a MethodChannel
    /// — no plugin, no desugaring, nothing new in the build. Dart gates on
    /// lifecycle state + the POST_NOTIFICATIONS runtime grant.
    private fun showNotification(title: String, body: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                "conversion", "Model conversion",
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        )
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = Notification.Builder(this, "conversion")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        nm.notify(1001, n)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // F4 hand-tracking POC: native CameraX + MediaPipe HandLandmarker. Uses
        // the engine's renderer as the Flutter TextureRegistry (for the camera
        // preview texture) and this activity as the CameraX LifecycleOwner.
        handTracker = HandTracker(
            context = this,
            textureRegistry = flutterEngine.renderer,
            lifecycleOwner = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, gpuChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // The native viewer (flutter_scene) needs Impeller's Vulkan
                    // backend; it crashes on GLES. Let Dart gate the viewer.
                    "supportsVulkan" -> result.success(
                        packageManager.hasSystemFeature(
                            PackageManager.FEATURE_VULKAN_HARDWARE_VERSION
                        )
                    )
                    // This process's total PSS in KB (own-process query, no
                    // permission needed). Lets us show memory in-app instead of
                    // needing `adb shell dumpsys meminfo` on a tethered PC.
                    "getPss" -> {
                        val mi = Debug.MemoryInfo()
                        Debug.getMemoryInfo(mi)
                        result.success(mi.totalPss)
                    }
                    // Full PSS breakdown (KB) — same buckets as dumpsys meminfo
                    // "App Summary". Tells us WHERE memory goes (graphics vs
                    // native heap vs dart vs code).
                    "getMemStats" -> {
                        val mi = Debug.MemoryInfo()
                        Debug.getMemoryInfo(mi)
                        fun stat(k: String) = mi.getMemoryStat(k)?.toIntOrNull() ?: 0
                        result.success(
                            hashMapOf(
                                "total" to mi.totalPss,
                                "java" to stat("summary.java-heap"),
                                "native" to stat("summary.native-heap"),
                                "code" to stat("summary.code"),
                                "stack" to stat("summary.stack"),
                                "graphics" to stat("summary.graphics"),
                                "other" to stat("summary.private-other"),
                                "system" to stat("summary.system")
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notifyChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        showNotification(
                            call.argument<String>("title") ?: "Holdable",
                            call.argument<String>("body") ?: "",
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        handTracker?.stop()
        handTracker = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
