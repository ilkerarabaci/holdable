package app.holdable

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors

/// F4 hand-tracking POC — native camera + on-device hand-landmark inference.
///
/// Owns the back camera via CameraX. Two use cases off one camera:
///   - Preview  → rendered into a Flutter SurfaceTexture (so Flutter widgets,
///                including the model, composite cleanly on top of it).
///   - ImageAnalysis → each frame goes to MediaPipe HandLandmarker in
///                LIVE_STREAM mode; the 21 landmarks/hand are streamed to Dart.
///
/// Channels (see [hand_landmarker_channel.dart] on the Dart side):
///   MethodChannel `holdable/hands`        — start (returns textureId) / stop
///   EventChannel  `holdable/hands/events` — per-frame landmark payloads
///
/// Landmarks are normalized to the *upright* analysis image (we rotate frames
/// to sensor-upright before inference), so the Dart gesture core sees a stable
/// [0,1] space regardless of device rotation.
class HandTracker(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val lifecycleOwner: LifecycleOwner,
    messenger: BinaryMessenger,
) {
    private val methodChannel = MethodChannel(messenger, "holdable/hands")
    private val eventChannel = EventChannel(messenger, "holdable/hands/events")

    private val mainHandler = Handler(Looper.getMainLooper())
    private val analysisExecutor = Executors.newSingleThreadExecutor()

    private var eventSink: EventChannel.EventSink? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var handLandmarker: HandLandmarker? = null

    init {
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }

            override fun onCancel(args: Any?) {
                eventSink = null
            }
        })

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> start(result)
                "stop" -> {
                    stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Starts the camera + landmarker. Replies with the Flutter texture id the
    /// preview renders into (Dart shows it via a `Texture` widget).
    private fun start(result: MethodChannel.Result) {
        try {
            setupLandmarker()
        } catch (e: Exception) {
            result.error("LANDMARKER_INIT", e.message, null)
            return
        }

        val entry = textureRegistry.createSurfaceTexture()
        textureEntry = entry
        val surfaceTexture = entry.surfaceTexture()

        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            try {
                val provider = providerFuture.get()
                cameraProvider = provider

                val preview = Preview.Builder()
                    .setTargetResolution(Size(720, 1280))
                    .build()
                preview.setSurfaceProvider { request ->
                    val res = request.resolution
                    surfaceTexture.setDefaultBufferSize(res.width, res.height)
                    val surface = Surface(surfaceTexture)
                    request.provideSurface(surface, analysisExecutor) { surface.release() }
                }

                val analysis = ImageAnalysis.Builder()
                    .setTargetResolution(Size(480, 640))
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .build()
                analysis.setAnalyzer(analysisExecutor) { proxy -> analyze(proxy) }

                provider.unbindAll()
                provider.bindToLifecycle(
                    lifecycleOwner,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis,
                )
                mainHandler.post { result.success(entry.id()) }
            } catch (e: Exception) {
                mainHandler.post { result.error("CAMERA_START", e.message, null) }
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /// Runs MediaPipe on one frame. CameraX gives RGBA_8888; we copy it to a
    /// Bitmap, rotate to upright, and feed the landmarker asynchronously.
    private fun analyze(proxy: ImageProxy) {
        val landmarker = handLandmarker
        if (landmarker == null) {
            proxy.close()
            return
        }
        try {
            val bitmap = Bitmap.createBitmap(
                proxy.width, proxy.height, Bitmap.Config.ARGB_8888
            )
            bitmap.copyPixelsFromBuffer(proxy.planes[0].buffer)

            val rotation = proxy.imageInfo.rotationDegrees
            val upright = if (rotation != 0) {
                val m = Matrix().apply { postRotate(rotation.toFloat()) }
                Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
            } else {
                bitmap
            }

            val mpImage = BitmapImageBuilder(upright).build()
            landmarker.detectAsync(mpImage, SystemClock.uptimeMillis())
        } catch (_: Exception) {
            // Drop the frame; the next one will catch up (KEEP_ONLY_LATEST).
        } finally {
            proxy.close()
        }
    }

    private fun setupLandmarker() {
        if (handLandmarker != null) return
        val base = BaseOptions.builder()
            .setModelAssetPath("hand_landmarker.task")
            .build()
        val options = HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(base)
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setNumHands(2)
            .setMinHandDetectionConfidence(0.5f)
            .setMinHandPresenceConfidence(0.5f)
            .setMinTrackingConfidence(0.5f)
            .setResultListener { result, input -> onResults(result, input.width, input.height) }
            .setErrorListener { /* swallow; transient frames can fail */ }
            .build()
        handLandmarker = HandLandmarker.createFromOptions(context, options)
    }

    /// Packs the result into a flat, channel-friendly payload and ships it to
    /// Dart on the UI thread.
    private fun onResults(result: HandLandmarkerResult, w: Int, h: Int) {
        val sink = eventSink ?: return
        val hands = ArrayList<HashMap<String, Any>>(result.landmarks().size)
        for (i in result.landmarks().indices) {
            val lms = result.landmarks()[i]
            val flat = DoubleArray(lms.size * 3)
            for (j in lms.indices) {
                flat[j * 3] = lms[j].x().toDouble()
                flat[j * 3 + 1] = lms[j].y().toDouble()
                flat[j * 3 + 2] = lms[j].z().toDouble()
            }
            // Handedness: back camera is not mirrored, so MediaPipe's label is
            // correct as-is.
            val isRight = result.handednesses().getOrNull(i)
                ?.firstOrNull()?.categoryName()?.equals("Right", true) ?: true
            hands.add(hashMapOf("right" to isRight, "lm" to flat.toList()))
        }
        val payload = hashMapOf<String, Any>("w" to w, "h" to h, "hands" to hands)
        mainHandler.post { eventSink?.success(payload) }
    }

    fun stop() {
        try {
            cameraProvider?.unbindAll()
        } catch (_: Exception) {
        }
        cameraProvider = null
        textureEntry?.release()
        textureEntry = null
        try {
            handLandmarker?.close()
        } catch (_: Exception) {
        }
        handLandmarker = null
    }
}
