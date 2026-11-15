#!/bin/bash
# 在 arm64 手机上构建 dsh-Go APK
#   bash 04-build-apk-arm64.sh            # debug
#   bash 04-build-apk-arm64.sh --release  # release（AOT 未验证，见 README）
# 关键点：/sdcard 是 FUSE（不能执行 gradlew）→ 源码留在 /sdcard，构建在 /root 副本进行
set -euo pipefail
MODE="${1:-debug}"
SRC="${SRC:-/sdcard/DshWorkSpace/AndroidProjects/dsh-Go}"
DST="${DST:-/root/build/dsh-Go}"
KS="${KS:-/sdcard/DshWorkSpace/AndroidProjects/keyStores/lizow.keystore}"
KS_PASS="${KS_PASS:-Lizow123.}"
KS_ALIAS="${KS_ALIAS:-lizow}"
export HOME=/root FLUTTER_ROOT=/opt/flutter ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
# AOT 编译器走 box64（比 qemu 快约 6 倍；产物与 qemu 逐字节一致）
export BOX64="${BOX64:-1}"
export PATH="/opt/gradle-9.3.1/bin:/usr/local/bin:$PATH"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

log "同步源码到 $DST（保留构建缓存）"
mkdir -p "$DST"
# rsync 做增量同步：只更新变化的源码，绝不碰 build/ 与 .dart_tool/，
# 否则每次都要重跑整个 AOT（约 11 分钟）和全部 Gradle 任务。
command -v rsync >/dev/null || { log "安装 rsync"; apt-get install -y rsync >/dev/null 2>&1 || true; }
if command -v rsync >/dev/null; then
  for d in app packages; do
    mkdir -p "$DST/$d"
    rsync -a --delete \
      --exclude 'build/' --exclude '.dart_tool/' --exclude '.git/' \
      --exclude 'android/.gradle/' --exclude 'android/.cxx/' --exclude 'android/app/.cxx/' \
      "$SRC/$d/" "$DST/$d/"
  done
else
  log "没有 rsync，退化为覆盖复制（仍不清缓存目录）"
  for d in app packages; do
    tar cf - -C "$SRC" --exclude="$d/build" --exclude="$d/.dart_tool" \
        --exclude="$d/.git" --exclude="$d/android/.cxx" "$d" | tar xf - -C "$DST"
  done
fi
if [ "${FULL:-0}" = "1" ]; then
  log "FULL=1：清理构建缓存（全量重建）"
  rm -rf "$DST/app/build" "$DST/app/.dart_tool" "$DST/app/android/.cxx" "$DST/app/android/app/.cxx"
fi
[ -f "$DST/app/android/gradlew.disabled" ] && mv "$DST/app/android/gradlew.disabled" "$DST/app/android/gradlew"
chmod +x "$DST/app/android/gradlew" 2>/dev/null || true

log "签名配置（构建副本用绝对路径）"
{
  echo "storeFile=$KS"
  echo "storePassword=$KS_PASS"
  echo "keyAlias=$KS_ALIAS"
  echo "keyPassword=$KS_PASS"
} > "$DST/app/android/key.properties"

log "Gradle 稳定性参数"
G="$DST/app/android/gradle.properties"
if ! grep -q sdkDownload "$G"; then
  {
    echo "systemProp.org.gradle.internal.http.connectionTimeout=20000"
    echo "systemProp.org.gradle.internal.http.socketTimeout=60000"
    echo "systemProp.org.gradle.internal.repository.max.retries=4"
    echo "android.builder.sdkDownload=false"
  } >> "$G"
fi

log "准备 sqlite3 native assets 预编译库（离线，避免 hook 访问 github 超时）"
PREBUILT_DIR="${PREBUILT_DIR:-/opt/prebuilt}"
mkdir -p "$PREBUILT_DIR"
for f in libsqlite3.arm.android.so libsqlite3.arm64.android.so libsqlite3.x64.android.so; do
  if [ ! -f "$PREBUILT_DIR/$f" ]; then
    curl -fL --retry 3 --max-time 120 -o "$PREBUILT_DIR/$f" \
      "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.9.1/$f" || \
      echo "  ! 下载失败：$f（构建可能因 native assets 而失败）"
  fi
done
export SQLITE3_PREBUILT_DIR="$PREBUILT_DIR"

log "检查 AOT 包装（box64）"
AOTW=/opt/flutter/bin/cache/artifacts/engine/android-arm64-release/linux-arm64/gen_snapshot
if [ ! -x "$AOTW" ]; then
  echo "  缺 AOT 包装，自动安装：bash $(dirname "$0")/07-install-aot-wrapper.sh"
  bash "$(dirname "$0")/07-install-aot-wrapper.sh" || exit 1
fi
[ -x /opt/box64-bin/usr/bin/box64 ] || echo "  ! box64 未安装，release 构建会退回 qemu（慢 6 倍）：bash $(dirname "$0")/06-setup-box64.sh"

log "pub get"
cd "$DST/app" && flutter pub get

if [ "$MODE" = "--release" ]; then
  TASK=assembleArm64Release
  OUT="$DST/app/build/app/outputs/flutter-apk/app-arm64-release.apk"
else
  TASK=assembleArm64Debug
  OUT="$DST/app/build/app/outputs/flutter-apk/app-arm64-debug.apk"
fi

log "构建 $TASK（release 用 flutter 驱动，参数才完整）"
cd "$DST/app"
if [ "$MODE" = "--release" ]; then
  # 只构建 arm64 目标：Flutter 默认还会给 android-arm / android-x64 跑 AOT，
  # 而这两个架构本机没有可运行的 gen_snapshot。
  # 注意：release 的 AOT 快照在这台 arm64 机器上目标 OS 不对，产物能打包但跑不起来（见 README 第 10 节）。
  flutter build apk --release --flavor arm64 --target-platform android-arm64
else
  flutter build apk --debug --flavor arm64 --target-platform android-arm64
fi

log "产物"
ls -lh "$OUT"
mkdir -p /sdcard/Download/DSH-Go
cp -f "$OUT" "/sdcard/Download/DSH-Go/$(basename "$OUT")"
echo "已复制到 /sdcard/Download/DSH-Go/$(basename "$OUT")"
echo "下一步：bash fix/99-verify-apk.sh"
