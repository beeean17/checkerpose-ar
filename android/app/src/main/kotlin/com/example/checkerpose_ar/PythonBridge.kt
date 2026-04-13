package com.example.checkerpose_ar

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.chaquo.python.PyException
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class PythonBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    init {
        ensurePythonStarted()
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "calibrateCamera" -> calibrateCamera(call, result)
            "getArPose" -> getArPose(call, result)
            else -> result.notImplemented()
        }
    }

    private fun calibrateCamera(call: MethodCall, result: MethodChannel.Result) {
        val images = call.argument<List<Any?>>("images")
        val boardCols = call.argument<Int>("boardCols") ?: 10
        val boardRows = call.argument<Int>("boardRows") ?: 7
        val squareSizeMm = call.argument<Double>("squareSizeMm") ?: 25.0

        if (images.isNullOrEmpty()) {
            result.error("invalid_args", "Calibration requires at least one image.", null)
            return
        }

        executor.execute {
            try {
                val module = Python.getInstance().getModule("open_cv_bridge")
                val jsonStr = module.callAttr(
                    "calibrate_camera",
                    images,
                    boardCols,
                    boardRows,
                    squareSizeMm,
                ).toJava(String::class.java) as String
                val payload = jsonToMap(JSONObject(jsonStr))
                mainHandler.post { result.success(payload) }
            } catch (error: PyException) {
                Log.e(TAG, "calibrateCamera failed", error)
                mainHandler.post {
                    result.error("python_error", error.message, error.stackTraceToString())
                }
            } catch (error: Throwable) {
                Log.e(TAG, "calibrateCamera failed", error)
                mainHandler.post {
                    result.error("native_error", error.message, error.stackTraceToString())
                }
            }
        }
    }

    private fun getArPose(call: MethodCall, result: MethodChannel.Result) {
        val frame = call.argument<Map<String, Any?>>("frame")
        val calibration = call.argument<Map<String, Any?>>("calibration")
        val boardCols = call.argument<Int>("boardCols") ?: 10
        val boardRows = call.argument<Int>("boardRows") ?: 7
        val squareSizeMm = call.argument<Double>("squareSizeMm") ?: 25.0

        if (frame == null || calibration == null) {
            result.error("invalid_args", "Frame and calibration are required.", null)
            return
        }

        executor.execute {
            try {
                val module = Python.getInstance().getModule("open_cv_bridge")
                val jsonStr = module.callAttr(
                    "get_ar_pose",
                    frame,
                    calibration["K"],
                    calibration["dist"],
                    boardCols,
                    boardRows,
                    squareSizeMm,
                ).toJava(String::class.java) as String
                val payload = jsonToMap(JSONObject(jsonStr))
                mainHandler.post { result.success(payload) }
            } catch (error: PyException) {
                Log.e(TAG, "getArPose failed", error)
                mainHandler.post {
                    result.error("python_error", error.message, error.stackTraceToString())
                }
            } catch (error: Throwable) {
                Log.e(TAG, "getArPose failed", error)
                mainHandler.post {
                    result.error("native_error", error.message, error.stackTraceToString())
                }
            }
        }
    }

    private fun ensurePythonStarted() {
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(activity.applicationContext))
        }
    }

    /**
     * Recursively converts a [JSONObject] into a [HashMap] of native JVM types
     * that Flutter's MethodChannel can serialize without issues.
     */
    private fun jsonToMap(json: JSONObject): HashMap<String, Any?> {
        val map = HashMap<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            map[key] = toNativeValue(json.get(key))
        }
        return map
    }

    private fun jsonArrayToList(array: JSONArray): ArrayList<Any?> {
        val list = ArrayList<Any?>(array.length())
        for (i in 0 until array.length()) {
            list.add(toNativeValue(array.get(i)))
        }
        return list
    }

    private fun toNativeValue(value: Any?): Any? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonToMap(value)
            is JSONArray -> jsonArrayToList(value)
            is Int, is Long, is Double, is Boolean, is String -> value
            // JSONObject may parse numbers as other types in edge cases.
            is Number -> value.toDouble()
            else -> value.toString()
        }
    }

    companion object {
        private const val CHANNEL_NAME = "checkerpose/python"
        private const val TAG = "CheckerPosePython"
    }
}
