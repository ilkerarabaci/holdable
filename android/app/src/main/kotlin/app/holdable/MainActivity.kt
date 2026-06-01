package app.holdable

import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val gpuChannel = "holdable/gpu"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The native viewer (flutter_scene) needs Impeller's Vulkan backend; it
        // crashes on the GLES backend. Expose whether this device has a Vulkan
        // GPU so Dart can gate the viewer instead of crashing.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, gpuChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "supportsVulkan" -> result.success(
                        packageManager.hasSystemFeature(
                            PackageManager.FEATURE_VULKAN_HARDWARE_VERSION
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
