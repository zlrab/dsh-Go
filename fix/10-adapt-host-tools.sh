#!/bin/bash
# 一键适配宿主 x86_64 工具（arm64 手机 proot 上做 Android 构建的前提）
#
# 为什么需要：Android SDK / AGP / NDK 的构建工具是 x86_64 ELF，本机是 arm64，
# 只能靠 qemu-user 模拟跑；模拟又需要一套 x86_64 的 glibc。
#
# 覆盖 6 项（幂等，已就绪的跳过）：
#   1. /opt/x86libs      x86_64 glibc + coreutils（qemu -L 用）
#   2. /opt/qemu-new     Debian trixie 的 qemu 10（apt 的 8.2 跑真实编译会内部 SIGSEGV）
#   3. aapt2 override    AGP 从 Maven 下的 x86_64 aapt2，包一层 qemu 并用 gradle 属性指过去
#   4. SDK cmake 包装    :jni 插件需要 cmake 3.22.1，SDK 里那份也是 x86_64
#   5. sqlite3 离线补丁  pub 缓存里的 hook 默认去 GitHub 下 .so（被墙则构建失败）
#   6. 环境变量          /etc/profile.d/dsh-toolchain.sh（PATH / JAVA_HOME / 镜像）
#
# 用法：bash fix/10-adapt-host-tools.sh
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
X86LIBS="${X86LIBS:-/opt/x86libs}"
QEMU_DIR="${QEMU_DIR:-/opt/qemu-new}"
AAPT2_DIR="${AAPT2_DIR:-/opt/aapt2-maven}"
SDK="${ANDROID_HOME:-/opt/android-sdk}"
TUNA="https://mirrors.tuna.tsinghua.edu.cn"
DEBIAN_POOL="$TUNA/debian/pool/main/q/qemu"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '  \033[33m!\033[0m %s\n' "$*"; }
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }

# ── 1. x86_64 glibc ───────────────────────────────────────────────────────────
log "1/6 x86_64 glibc（$X86LIBS）"
if [ -x "$X86LIBS/usr/bin/ls" ]; then
  ok "已存在（$(du -sh "$X86LIBS" | cut -f1)）"
else
  dpkg --print-foreign-architectures | grep -qx amd64 || { dpkg --add-architecture amd64; note "已启用 amd64 架构"; }
  # ports.ubuntu.com 没有 amd64：给现有源加 Architectures: arm64，另加一个 amd64 源
  python3 - <<'PY' || true
import glob, os
p = '/etc/apt/sources.list.d/ubuntu.sources'
if os.path.exists(p):
    s = open(p).read()
    if 'Architectures:' not in s:
        open(p, 'w').write(s.replace('Types: deb\n', 'Types: deb\nArchitectures: arm64\n'))
PY
  if ! grep -qs 'Architectures: amd64' /etc/apt/sources.list.d/*.sources; then
    cat > /etc/apt/sources.list.d/amd64.sources <<EOF
Types: deb
Architectures: amd64
URIs: $TUNA/ubuntu/
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    note "已添加 amd64 apt 源（tuna）"
  fi
  apt-get update -qq 2>&1 | tail -2
  mkdir -p /tmp/x86debs && cd /tmp/x86debs && rm -f ./*.deb
  apt-get download libc6:amd64 libstdc++6:amd64 zlib1g:amd64 libgcc-s1:amd64 libcrypt1:amd64 \
    libselinux1:amd64 libpcre2-8-0:amd64 libattr1:amd64 libacl1:amd64 libcap2:amd64 coreutils:amd64 2>&1 | tail -2
  mkdir -p "$X86LIBS"; for d in ./*.deb; do dpkg-deb -x "$d" "$X86LIBS"; done
  # merged-usr：qemu -L 靠 /lib64/ld-linux-x86-64.so.2 找动态加载器
  ln -sfn usr/lib64 "$X86LIBS/lib64"; ln -sfn usr/lib "$X86LIBS/lib"
  ln -sfn usr/bin "$X86LIBS/bin"; ln -sfn usr/sbin "$X86LIBS/sbin"
  ok "已安装（$(du -sh "$X86LIBS" | cut -f1)）"
fi

# ── 2. qemu 10 ────────────────────────────────────────────────────────────────
log "2/6 qemu 10（$QEMU_DIR）"
if [ -x "$QEMU_DIR/usr/bin/qemu-x86_64" ] && "$QEMU_DIR/usr/bin/qemu-x86_64" --version 2>/dev/null | head -1 | grep -q 'version 10\.'; then
  ok "已存在：$("$QEMU_DIR/usr/bin/qemu-x86_64" --version | head -1)"
else
  deb=$(curl -sL "$DEBIAN_POOL/" | grep -oE 'qemu-user_1[0-9]+\.[^"]*_arm64\.deb' | sort -uV | tail -1)
  [ -n "$deb" ] || { bad "在 $DEBIAN_POOL 找不到 qemu-user arm64 deb"; exit 1; }
  note "下载 $deb"
  curl -fL --retry 3 -o /tmp/qemu-user.deb "$DEBIAN_POOL/$(echo "$deb" | sed 's/+/%2B/g')" || { bad "下载失败"; exit 1; }
  rm -rf "$QEMU_DIR" && mkdir -p "$QEMU_DIR" && dpkg-deb -x /tmp/qemu-user.deb "$QEMU_DIR"
  ok "已解包：$("$QEMU_DIR/usr/bin/qemu-x86_64" --version | head -1)"
fi
for n in qemu-x86_64 qemu-x86_64-static; do ln -sf "$QEMU_DIR/usr/bin/qemu-x86_64" "/usr/local/bin/$n"; done
ok "/usr/local/bin/qemu-x86_64{,-static} 已指向"
if "$QEMU_DIR/usr/bin/qemu-x86_64" -L "$X86LIBS" "$X86LIBS/usr/bin/ls" --version >/dev/null 2>&1; then
  ok "qemu 能跑 x86_64 程序"
else
  bad "qemu 跑不通 x86_64 程序（x86libs 不完整？）"
fi

# ── 3. aapt2 override ─────────────────────────────────────────────────────────
log "3/6 aapt2（AGP 从 Maven 下的那份，$AAPT2_DIR）"
AGP=$(grep -oE 'com\.android\.application"?\)? *version *"[0-9.]+"' "$REPO/app/android/settings.gradle.kts" 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -n "$AGP" ] || AGP=$(grep -rhoE 'com\.android\.application.*version *"[0-9.]+"' "$REPO/app/android" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$AGP" ]; then
  spec=$(ls /root/.gradle/caches/modules-2/files-2.1/com.android.tools.build/aapt2/ 2>/dev/null | grep -E "^${AGP}-[0-9]+$" | sort -V | tail -1)
  if [ -z "$spec" ]; then
    spec=$(curl -sL "https://maven.aliyun.com/repository/google/com/android/tools/build/aapt2/maven-metadata.xml" \
           | grep -oE "<version>${AGP}-[0-9]+</version>" | sed 's/<[^>]*>//g' | sort -V | tail -1)
  fi
  if [ -n "$spec" ] && [ ! -x "$AAPT2_DIR/aapt2" ]; then
    mkdir -p "$AAPT2_DIR" && cd "$AAPT2_DIR"
    curl -fsSL --retry 3 -o aapt2.jar "https://maven.aliyun.com/repository/google/com/android/tools/build/aapt2/$spec/aapt2-$spec-linux.jar" \
      && unzip -o -q aapt2.jar aapt2 && mv -f aapt2 aapt2.x86_64 && chmod +x aapt2.x86_64
    cat > "$AAPT2_DIR/aapt2" <<WRAP
#!/bin/bash
# AGP 从 Maven 下的 aapt2 是 x86_64，本机 arm64 → 经 qemu 运行
exec /usr/local/bin/qemu-x86_64-static -L $X86LIBS $AAPT2_DIR/aapt2.x86_64 "\$@"
WRAP
    chmod +x "$AAPT2_DIR/aapt2"; ok "已安装 aapt2 $spec"
  fi
  G="$HOME/.gradle/gradle.properties"; mkdir -p "$(dirname "$G")"
  grep -q 'android.aapt2FromMavenOverride' "$G" 2>/dev/null || {
    printf '\n# arm64 适配：AGP 自带的 aapt2 是 x86_64，改用 qemu 包装（不要改写 Gradle transform 缓存）\nandroid.aapt2FromMavenOverride=%s/aapt2\n' "$AAPT2_DIR" >> "$G"
    ok "已写入 $G"
  }
  [ -x "$AAPT2_DIR/aapt2" ] && ok "aapt2: $("$AAPT2_DIR/aapt2" version 2>&1 | head -1)" || bad "aapt2 不可用"
else
  note "读不到 AGP 版本，跳过 aapt2（先跑 fix/01）"
fi

# ── 4. SDK cmake 包装 ─────────────────────────────────────────────────────────
log "4/6 SDK cmake（:jni 插件需要）"
wrapped=0
for b in "$SDK"/cmake/*/bin; do
  [ -d "$b" ] || continue
  for t in cmake ninja ctest cpack; do
    f="$b/$t"; [ -f "$f" ] || continue
    head -c4 "$f" 2>/dev/null | grep -q 'ELF' || continue      # 已是包装脚本则跳过
    [ -f "$f.x86_64" ] || mv "$f" "$f.x86_64"
    printf '#!/bin/bash\n# arm64 适配：SDK 里的 %s 是 x86_64 → 经 qemu 运行\nexec /usr/local/bin/qemu-x86_64-static -L %s %s.x86_64 "$@"\n' "$t" "$X86LIBS" "$f" > "$f"
    chmod +x "$f"; wrapped=$((wrapped+1))
  done
done
if [ "$wrapped" -gt 0 ]; then ok "已包装 $wrapped 个二进制"; else ok "无需包装（已就绪或未安装 cmake）"; fi
for b in "$SDK"/cmake/*/bin/cmake; do [ -x "$b" ] && ok "cmake: $("$b" --version 2>/dev/null | head -1)"; done

# ── 5. sqlite3 离线补丁 ───────────────────────────────────────────────────────
log "5/6 sqlite3 离线补丁（pub 缓存）"
patched=0; found=0
for f in $HOME/.pub-cache/hosted/*/sqlite3-*/lib/src/hook/compile/description.dart; do
  [ -f "$f" ] || continue; found=$((found+1))
  grep -q 'SQLITE3_PREBUILT_DIR' "$f" && { ok "已打过：$f"; continue; }
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = """  ) async* {
    final client = HttpClient()"""
patch = """  ) async* {
    // dsh-Go 离线补丁：优先读 SQLITE3_PREBUILT_DIR 里的本地 .so（GitHub 不可达）
    final localDir = Platform.environment['SQLITE3_PREBUILT_DIR'];
    if (localDir != null && localDir.isNotEmpty) {
      final local = File('$localDir/$filename');
      if (local.existsSync()) {
        yield local.readAsBytesSync();
        return;
      }
    }
    final client = HttpClient()"""
assert s.count(anchor) == 1, 'anchor not found (sqlite3 版本变了？)'
open(p, 'w').write(s.replace(anchor, patch))
PY
  [ $? -eq 0 ] && { ok "已打补丁：$f"; patched=$((patched+1)); } || bad "打补丁失败：$f"
done
[ "$found" = 0 ] && note "（没找到 sqlite3 的 pub 缓存：先跑一次 flutter pub get）"
mkdir -p /opt/prebuilt

# ── 6. 环境变量 ───────────────────────────────────────────────────────────────
log "6/6 环境变量（/etc/profile.d/dsh-toolchain.sh）"
cat > /etc/profile.d/dsh-toolchain.sh <<'EOF'
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export FLUTTER_ROOT=/opt/flutter
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PATH=/opt/flutter/bin:/opt/gradle-9.3.1/bin:/opt/android-sdk/platform-tools:/usr/local/bin:$PATH
EOF
ok "已写入（登录 shell 生效；非登录 shell 请手动 export）"

# ── 汇总 ──────────────────────────────────────────────────────────────────────
log "自检汇总"
[ -x "$X86LIBS/usr/bin/ls" ] && ok "x86libs" || bad "x86libs"
"$QEMU_DIR/usr/bin/qemu-x86_64" --version >/dev/null 2>&1 && ok "qemu $("$QEMU_DIR/usr/bin/qemu-x86_64" --version | head -1 | cut -d' ' -f1-3)" || bad "qemu"
[ -x "$AAPT2_DIR/aapt2" ] && ok "aapt2 包装" || bad "aapt2 包装"
grep -q 'aapt2FromMavenOverride' "$HOME/.gradle/gradle.properties" 2>/dev/null && ok "gradle aapt2 override" || bad "gradle aapt2 override"
ls "$SDK"/cmake/*/bin/cmake >/dev/null 2>&1 && ok "SDK cmake" || note "SDK cmake 未安装（fix/01 之后或按需装）"
echo
echo "完成。下一步：bash fix/06-setup-box64.sh → bash fix/07-install-aot-wrapper.sh → runtime 构建 → fix/04"
