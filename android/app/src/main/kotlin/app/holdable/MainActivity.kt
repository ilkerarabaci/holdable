package app.holdable

import android.content.pm.PackageManager
import android.os.Debug
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val gpuChannel = "holdable/gpu"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }
}
