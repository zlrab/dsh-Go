#!/bin/bash
# 安装 box64（arm64 上跑 x86_64 AOT 编译器，比 qemu TCG 快约 6 倍）
#
# 为什么需要：Flutter 只为 x64 宿主提供 Android 的 gen_snapshot，arm64 手机必须模拟运行。
#   qemu TCG：每条指令走翻译层 → 全量 release 构建 2377s
#   box64 Dynarec：翻译一次并缓存 → 全量 release 构建 392s（产物与 qemu 逐字节一致）
set -euo pipefail
BOX64_BIN_DIR="${BOX64_BIN_DIR:-/opt/box64-bin}"
BOX64_LIB_DIR="${BOX64_LIB_DIR:-/opt/box64}"
BOX64_VER="${BOX64_VER:-0.4.3}"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

if [ -x "$BOX64_BIN_DIR/usr/bin/box64" ]; then
  log "box64 已存在：$("$BOX64_BIN_DIR/usr/bin/box64" --version 2>&1 | head -1)"
else
  log "下载 box64 arm64 二进制（Debian 包，v$BOX64_VER）"
  mkdir -p /tmp/box64-dl "$BOX64_BIN_DIR"
  DEB="box64_${BOX64_VER}-3+dfsg-1_arm64.deb"
  curl -fL --retry 3 -o "/tmp/box64-dl/$DEB" \
    "https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/b/box64/$(echo "$DEB" | sed 's/+/%2B/g')" || {
      echo "!! 下载失败。可换版本：curl -s https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/b/box64/ | grep -oE 'box64_[^\\\"]*_arm64.deb'" >&2
      exit 1
    }
  dpkg -x "/tmp/box64-dl/$DEB" "$BOX64_BIN_DIR"
  log "box64 就绪：$("$BOX64_BIN_DIR/usr/bin/box64" --version 2>&1 | head -1)"
fi

if [ -d "$BOX64_LIB_DIR/usr/lib/box64-x86_64-linux-gnu" ]; then
  log "x86_64 库包已存在"
else
  log "下载 box64 官方 x86_64 库包（33MB，给被模拟程序用）"
  mkdir -p /tmp/box64-dl "$BOX64_LIB_DIR"
  curl -fL --retry 3 -o /tmp/box64-dl/box64-bundle.tar.gz \
    "https://github.com/ptitSeb/box64/releases/download/v0.4.4/box64-bundle-x86-libs-v0.4.4.tar.gz"
  tar xzf /tmp/box64-dl/box64-bundle.tar.gz -C "$BOX64_LIB_DIR"
fi

# box64 需要一套 x86_64 glibc；Android SDK 那套（/opt/x86libs）里已有
[ -d /opt/x86libs/usr/lib/x86_64-linux-gnu ] || {
  echo "!! 缺 /opt/x86libs（x86_64 glibc）。先跑 fix/03 或 android-env/setup.sh 里的 x86libs 步骤" >&2
}

log "自检：用 box64 跑 Android AOT 编译器"
GX=/opt/flutter/bin/cache/artifacts/engine/android-arm64-release/linux-x64/gen_snapshot
if [ -x "$GX" ]; then
  BOX64_LD_LIBRARY_PATH="$BOX64_LIB_DIR/usr/lib/box64-x86_64-linux-gnu:/opt/x86libs/usr/lib/x86_64-linux-gnu:/opt/x86libs/usr/lib" \
  BOX64_LOG=0 BOX64_NOBANNER=1 \
    "$BOX64_BIN_DIR/usr/bin/box64" "$GX" --version 2>&1 | head -1
else
  echo "  （还没装 Flutter SDK，跳过）"
fi
log "完成。用 07-install-aot-wrapper.sh 接线，或直接 04-build-apk-arm64.sh（默认走 box64）"
