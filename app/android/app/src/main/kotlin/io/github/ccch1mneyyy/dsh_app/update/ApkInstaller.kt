package io.github.ccch1mneyyy.dsh_app.update

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import java.io.File

/**
 * What the installed APK is, for the few features that ask (关于 shows the version,
 * the workshop checks free space, diagnostics reports both).
 *
 * Install and inspection helpers went away with the in-app update flow; this fork
 * installs its own builds from outside the app (adb / the package installer).
 */
class ApkInstaller(private val context: Context) {

    private val pm: PackageManager get() = context.packageManager

    fun info(): Map<String, Any?> {
        val pkg = pm.getPackageInfo(context.packageName, 0)
        return mapOf(
            "versionName" to pkg.versionName,
            "versionCode" to versionCodeOf(pkg),
            // .../lib/arm64 or .../lib/x86_64: the ABI this APK was built for.
            "abi" to context.applicationInfo.nativeLibraryDir?.let { File(it).name },
            "sdkInt" to Build.VERSION.SDK_INT,
            "freeBytes" to context.cacheDir.usableSpace,
            "lastUpdateTime" to pkg.lastUpdateTime,
        )
    }

    companion object {
        fun versionCodeOf(info: PackageInfo): Long =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
    }
}
