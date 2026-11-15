#!/bin/bash
# 给构建副本补上 App 运行时资产（rootfs + proot），否则装上去会提示
# 「App 内的运行环境包不完整」。
#
# 两种来源，优先用第二种（快，几十秒）：
#   A. 自己构建：runtime/build-runtime.sh arm64      （要下 Ubuntu base + Node + DSH 树，较慢）
#   B. 从已安装的官方包提取（推荐）：手机里装着官方 dsh-Go，直接 adb pull 出来拆资产
#
# 用法： bash 05-fetch-runtime-assets.sh [包名]
set -euo pipefail
PKG="${1:-io.github.ccch1mneyyy.dsh_app}"
DST="${DST:-/root/build/dsh-Go/runtime/out/arm64-v8a}"
TMP="${TMP:-/root/official}"
export HOME=/root

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

command -v adb >/dev/null || { echo "需要 adb"; exit 1; }
adb devices | grep -q "device$" || { echo "adb 未连接（先 adb connect <ip>:<port>）"; exit 1; }

APKPATH=$(timeout 20 adb shell pm path "$PKG" | head -1 | sed 's/^package://' | tr -d '\r')
[ -n "$APKPATH" ] || { echo "设备上没装 $PKG"; exit 1; }
log "从设备拉取 $PKG 的 base.apk"
mkdir -p "$TMP" && cd "$TMP"
timeout 600 adb pull "$APKPATH" base.apk

log "解出 runtime 资产与 proot 库"
rm -rf extract && mkdir extract
unzip -q -o base.apk -d extract "assets/runtime/*" "lib/arm64-v8a/libproot*.so" \
  "lib/arm64-v8a/libtalloc.so" "lib/arm64-v8a/libandroid-shmem.so" "lib/arm64-v8a/libtawcroot.so" 2>/dev/null || true

log "放到 $DST"
rm -rf "$DST"; mkdir -p "$DST/assets" "$DST/jniLibs/arm64-v8a"
cp -a extract/assets/runtime "$DST/assets/"
cp -a extract/lib/arm64-v8a/*.so "$DST/jniLibs/arm64-v8a/" 2>/dev/null || true
du -sh "$DST"
ls "$DST/assets/runtime" | head
log "完成。重新跑 04-build-apk-arm64.sh 即可打出可运行的 APK"
