package io.github.ccch1mneyyy.dsh_app.update

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Read-only app info channel (`dsh/update`).
 *
 * The in-app update flow that used to live here is removed in this fork: our
 * applicationId and signing key differ from upstream's, so none of its releases can
 * be installed here, and checking for them every launch would only nag. What
 * remains is what other features still ask for — the installed versionName and
 * versionCode (关于, diagnostics, usage) and the free space downloads can use (workshop).
 */
class UpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var installer: ApkInstaller

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        installer = ApkInstaller(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "dsh/update")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> result.success(installer.info())
            else -> result.notImplemented()
        }
    }
}
