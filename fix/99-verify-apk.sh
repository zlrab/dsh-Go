#!/bin/bash
# 校验构建出来的 APK：签名、包名、架构、是否含我们期望的组件
set -euo pipefail
APK="${1:-/root/build/dsh-Go/app/build/app/outputs/flutter-apk/app-arm64-debug.apk}"
BT=/opt/android-sdk/build-tools/36.0.0
AAPT2=/opt/android-env/bin/aapt2
[ -f "$APK" ] || { echo "找不到 APK：$APK"; exit 1; }

echo "== 文件 =="; ls -lh "$APK"
echo; echo "== 签名（应为 CN=lizow，不是 CN=Android Debug）=="
"$BT/apksigner" verify --print-certs "$APK" | head -4
echo; echo "== 包信息 =="
"$AAPT2" dump badging "$APK" 2>/dev/null | grep -E "^package:|^sdkVersion|^targetSdkVersion" | head -3
echo; echo "== 架构 =="
unzip -l "$APK" | grep -oE "lib/[a-z0-9_-]+/" | sort -u
echo; echo "== 关键组成部分 =="
unzip -l "$APK" | grep -E "classes.*\.dex|libapp\.so|flutter_assets/AssetManifest" | head -5
