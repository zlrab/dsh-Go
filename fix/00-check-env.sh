#!/bin/bash
# 体检：列出构建 dsh-Go 需要的组件，缺什么一目了然
set -uo pipefail
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

echo "== 宿主 =="
echo "  $(uname -m) · $(. /etc/os-release; echo $PRETTY_NAME)"

echo "== 工具链 =="
JAVA=/usr/lib/jvm/java-17-openjdk-arm64/bin/java
[ -x $JAVA ] && ok "JDK $(  $JAVA -version 2>&1 | head -1)" || bad "缺 JDK 17"
[ -x /opt/gradle-9.3.1/bin/gradle ] && ok "Gradle $(/opt/gradle-9.3.1/bin/gradle --version 2>/dev/null | awk '/^Gradle/{print $2}')" || bad "缺 Gradle 9.3.1 (/opt/gradle-9.3.1)"
[ -x /opt/flutter/bin/flutter ] && ok "Flutter $(/opt/flutter/bin/cache/dart-sdk/bin/dart --version 2>&1)" || bad "缺 Flutter (/opt/flutter)"
[ -f /opt/flutter/bin/internal/shared.sh ] && grep -q FLUTTER_RUN_FROM_SOURCE /opt/flutter/bin/internal/shared.sh \
   && ok "Flutter 已打 arm64 源码运行补丁" || warn "Flutter 未打补丁（跑 01-setup-flutter-arm64.sh）"

echo "== Android SDK =="
S=/opt/android-sdk
for d in platforms/android-36 platforms/android-35 build-tools/36.0.0 ndk/28.2.13676358; do
  [ -d "$S/$d" ] && ok "$d" || bad "缺 $d"
done
[ -x /opt/android-env/bin/aapt2 ] && ok "aapt2 包装（qemu）" || bad "缺 /opt/android-env/bin/aapt2"

echo "== AOT 模拟层（release 必需）=="
[ -x /opt/box64-bin/usr/bin/box64 ] && ok "box64 $(/opt/box64-bin/usr/bin/box64 --version 2>&1 | head -1 | cut -d' ' -f1-3)" || warn "缺 box64（06-setup-box64.sh）"
[ -x /opt/qemu-new/usr/bin/qemu-x86_64 ] && ok "qemu-user $(/opt/qemu-new/usr/bin/qemu-x86_64 --version 2>&1 | head -1)" || warn "缺 qemu 10（apt 的 8.2 会崩）"
AOTW=/opt/flutter/bin/cache/artifacts/engine/android-arm64-release/linux-arm64/gen_snapshot
[ -x "$AOTW" ] && ok "AOT 包装已装（/linux-arm64/gen_snapshot）" || bad "缺 AOT 包装（07-install-aot-wrapper.sh）"

echo "== 镜像 =="
[ -f /root/.gradle/init.gradle ] && grep -q aliyun /root/.gradle/init.gradle \
   && ok "Gradle 全局镜像 init.gradle" || bad "缺 ~/.gradle/init.gradle"
grep -q aliyun /opt/flutter/packages/flutter_tools/gradle/settings.gradle.kts 2>/dev/null \
   && ok "Flutter Gradle 插件已加镜像" || warn "Flutter 插件仓库未改（跑 02-setup-mirrors.sh）"

echo "== NDK 包装（ABI 感知）=="
for v in 27.2.12479018 28.2.13676358; do
  c=$S/ndk/$v/toolchains/llvm/prebuilt/linux-x86_64/bin/clang
  [ -f "$c" ] && grep -q LIBDIR "$c" && ok "NDK $v clang 包装正常" || warn "NDK $v 未打 ABI 补丁"
done

echo "== 签名 =="
KS=/sdcard/DshWorkSpace/AndroidProjects/keyStores/lizow.keystore
[ -f "$KS" ] && ok "keystore: $KS" || bad "缺 keystore"
[ -f "$(dirname "$0")/../app/android/key.properties" ] && ok "key.properties" || warn "缺 app/android/key.properties"

echo "== 网络 =="
cd /tmp && node -e '
(async()=>{for(const [n,u] of [["阿里云 Maven","https://maven.aliyun.com/repository/google/"],["腾讯 Gradle","https://mirrors.cloud.tencent.com/gradle/"],["dl.google.com","https://dl.google.com/"]]){const s=Date.now();try{const r=await fetch(u,{method:"HEAD",signal:AbortSignal.timeout(6000)});console.log("  "+(r.ok?"\x1b[32m✓\x1b[0m":"\x1b[33m!\x1b[0m"),n,(Date.now()-s)+"ms")}catch(e){console.log("  \x1b[31m✗\x1b[0m",n,"不可达")}}})()' 2>/dev/null
