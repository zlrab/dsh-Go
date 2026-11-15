#!/bin/bash
# 安装 AOT 编译器包装：让 Flutter 用「arm64 可运行」的方式调用官方 x64 gen_snapshot
#
#   bash 07-install-aot-wrapper.sh          # box64（推荐，快约 6x）
#   bash 07-install-aot-wrapper.sh qemu     # qemu-user（稳，慢）
#
# 背景：Flutter 的 Android AOT 编译器官方只发 x64 版（android-arm64-release/linux-x64/gen_snapshot），
#       且 Flutter 会去 <engine>/linux-arm64/gen_snapshot 找「宿主版本」——那里官方不提供，
#       所以在这里放一个包装脚本把调用转到模拟层。
set -euo pipefail
MODE="${1:-box64}"
ENGINE=/opt/flutter/bin/cache/artifacts/engine/android-arm64-release
TARGET="$ENGINE/linux-arm64/gen_snapshot"
GX="$ENGINE/linux-x64/gen_snapshot"
BOX64=/opt/box64-bin/usr/bin/box64
QEMU=/opt/qemu-new/usr/bin/qemu-x86_64

[ -x "$GX" ] || { echo "找不到官方 gen_snapshot：$GX（先跑 01-setup-flutter-arm64.sh）" >&2; exit 1; }
mkdir -p "$ENGINE/linux-arm64"

if [ "$MODE" = "qemu" ]; then
  [ -x "$QEMU" ] || { echo "缺新版 qemu（$QEMU）。apt 的 8.2 跑真实编译会内部 SIGSEGV" >&2; exit 1; }
  cat > "$TARGET" <<WRAP
#!/bin/bash
# Android AOT 编译器（官方 x64 版）经 qemu-user 10.x 运行
exec "$QEMU" -L /opt/x86libs "$GX" "\$@"
WRAP
  echo "已安装 qemu 包装 → $TARGET"
else
  [ -x "$BOX64" ] || { echo "缺 box64（$BOX64），先跑 06-setup-box64.sh" >&2; exit 1; }
  cat > "$TARGET" <<WRAP
#!/bin/bash
# Android AOT 编译器（官方 x64 版）经 box64 Dynarec 运行。
# box64 在进程退出清理阶段偶发 "double free"，但 --elf 产物此时已完整落盘，
# 所以只要产物存在且大小正常就按成功返回，避免 Flutter 误判（实测产物与 qemu byte-identical）。
GX="$GX"
ELF=""
for a in "\$@"; do case "\$a" in --elf=*) ELF="\${a#--elf=}" ;; esac; done
export BOX64_LD_LIBRARY_PATH="/opt/box64/usr/lib/box64-x86_64-linux-gnu:/opt/x86libs/usr/lib/x86_64-linux-gnu:/opt/x86libs/usr/lib"
export BOX64_LOG=0 BOX64_NOBANNER=1 BOX64_DYNAREC=1
"$BOX64" "\$GX" "\$@"
rc=\$?
if [ -n "\$ELF" ] && [ -s "\$ELF" ] && [ "\$(stat -c%s "\$ELF")" -gt 40000000 ]; then
  [ "\$rc" -ne 0 ] && echo "[aot-wrapper] box64 退出码 \$rc，但产物 \$(stat -c%s "\$ELF") 字节，视为成功" >&2
  exit 0
fi
exit "\$rc"
WRAP
  echo "已安装 box64 包装 → $TARGET"
fi
chmod +x "$TARGET"
echo "自检：$("$TARGET" --version 2>&1 | head -1)"
