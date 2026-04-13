package com.example.checkerpose_ar

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var pythonBridge: PythonBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pythonBridge = PythonBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
