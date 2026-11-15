#!/bin/bash
# 安装 Flutter 3.47.7（官方 x64 包）+ 换成官方 arm64 Dart + 打「源码运行」补丁
# 幂等：已完成的步骤会跳过。需要 root（写 /opt）。
set -euo pipefail
FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.7}"
DART_VERSION="${DART_VERSION:-3.13.5}"     # 必须与 Flutter 内置 Dart 一致
FLUTTER_ROOT="${FLUTTER_ROOT:-/opt/flutter}"
DL="${DL:-/opt/flutter-dl}"
FLUTTER_URL="https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
DART_URL="https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-arm64-release.zip"
# 仓库里 tooling/setup-toolchain.sh 的值
FLUTTER_SHA256="${FLUTTER_SHA256:-af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }
mkdir -p "$DL"

if [ ! -x "$FLUTTER_ROOT/bin/flutter" ]; then
  log "下载 Flutter $FLUTTER_VERSION（约 1.5GB）"
  [ -f "$DL/flutter.tar.xz" ] || curl -fL --retry 3 -o "$DL/flutter.tar.xz" "$FLUTTER_URL"
  echo "$FLUTTER_SHA256  $DL/flutter.tar.xz" | sha256sum -c -
  log "解包到 /opt"
  rm -rf "$FLUTTER_ROOT"
  tar -xJf "$DL/flutter.tar.xz" -C /opt
else
  log "Flutter 已存在，跳过下载"
fi

if [ ! -x "$FLUTTER_ROOT/bin/cache/dart-sdk.x64/bin/dart" ]; then
  log "换入官方 arm64 Dart $DART_VERSION"
  DZ="$DL/dartsdk-linux-arm64.zip"
  [ -f "$DZ" ] || curl -fL --retry 3 -o "$DZ" "$DART_URL"
  rm -rf "$DL/arm64-dart" && unzip -q -o "$DZ" -d "$DL/arm64-dart"
  mv "$FLUTTER_ROOT/bin/cache/dart-sdk" "$FLUTTER_ROOT/bin/cache/dart-sdk.x64"
  cp -a "$DL/arm64-dart/dart-sdk" "$FLUTTER_ROOT/bin/cache/dart-sdk"
  echo "$(cat "$FLUTTER_ROOT/bin/internal/engine.version")" > "$FLUTTER_ROOT/bin/cache/engine-dart-sdk.stamp"
else
  log "arm64 Dart 已就位"
fi

log "给 shared.sh 打「从源码运行」补丁"
SH="$FLUTTER_ROOT/bin/internal/shared.sh"
if ! grep -q FLUTTER_RUN_FROM_SOURCE "$SH"; then
  cp "$SH" "$SH.bak"
  python3 - "$SH" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old='      exec "$DART" --packages="$FLUTTER_TOOLS_DIR/.dart_tool/package_config.json" $FLUTTER_TOOL_ARGS "$SNAPSHOT_PATH" "$@"'
new=('      # arm64 补丁：x64 AOT 快照不兼容，proot 下重编快照会死锁 → 直接 JIT 跑源码\n'
     '      if [ "${FLUTTER_RUN_FROM_SOURCE:-1}" = "1" ]; then\n'
     '        exec "$DART" --packages="$FLUTTER_TOOLS_DIR/.dart_tool/package_config.json" $FLUTTER_TOOL_ARGS "$FLUTTER_TOOLS_DIR/bin/flutter_tools.dart" "$@"\n'
     '      fi\n'+old)
assert old in s, "找不到 exec 行（Flutter 版本变了？）"
open(p,'w').write(s.replace(old,new))
print("补丁已写入")
PY
fi

log "伪造 stamp，避免 Flutter 重编快照"
echo "$(git -C "$FLUTTER_ROOT" rev-parse HEAD):" > "$FLUTTER_ROOT/bin/cache/flutter_tools.stamp"

log "自检"
export HOME="${HOME:-/root}"
"$FLUTTER_ROOT/bin/flutter" --version 2>&1 | grep -E "^Flutter|^Tools" || true
