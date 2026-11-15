#!/bin/bash
# 给 NDK 的 x86_64 宿主工具链打「原生 arm64 + ABI 感知」包装
#
# 覆盖 NDK 27.2 与 28.2（Flutter 3.47 默认）。已在装的跳过，幂等。
#
# ⚠ 2026-11-15 修正：NDK 28.2 的 bin/ 里 clang -> clang-19、clang++ -> clang、
#   llvm-strip -> llvm-objcopy、llvm-readelf -> llvm-readobj、llvm-ar 等**都是符号链接**。
#   旧版脚本直接 `cat > 目标` 会穿透链接写坏真二进制，后果是：
#     · clang 变成 clang++ 包装 → CMake 报 "The C compiler is a C++ compiler"，:jni 编不过
#     · llvm-ar / llvm-objcopy 被写成别的工具 → NDK 链接失败
#   所以这里一律先 `rm -f` 掉符号链接，再写包装文件。
set -euo pipefail
NDK_ROOT="${NDK_ROOT:-/opt/android-sdk/ndk}"
VERSIONS="${NDK_VERSIONS:-27.2.12479018 28.2.13676358}"
QEMU="${QEMU:-/usr/local/bin/qemu-x86_64-static}"
X86LIBS="${X86LIBS:-/opt/x86libs}"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
command -v /usr/bin/clang >/dev/null || { echo "需要 apt install clang lld" >&2; exit 1; }

for V in $VERSIONS; do
  B="$NDK_ROOT/$V/toolchains/llvm/prebuilt/linux-x86_64/bin"
  [ -d "$B" ] || { echo "跳过 NDK $V（未安装）"; continue; }
  RES="$(ls -d "$B/../lib/clang/"* 2>/dev/null | sort -V | tail -1)"
  log "NDK $V → clang 资源目录 $(basename "$RES")"

  # -- clang / clang++：先删符号链接再写包装 --
  for T in clang clang++; do
    CC=/usr/bin/clang; [ "$T" = "clang++" ] && CC=/usr/bin/clang++
    rm -f "$B/$T"
    cat > "$B/$T" <<WRAP
#!/bin/bash
# 原生 arm64 clang 包装：按 --target 选 compiler-rt 库目录
# 注意：不能对整个参数串匹配，--sysroot 路径里也含 x86_64
RES="$RES"
TARGET=""
for a in "\$@"; do case "\$a" in --target=*) TARGET="\${a#--target=}" ;; esac; done
case "\$TARGET" in
  armv7*|*androideabi*) LIBDIR="\$RES/lib/linux/arm" ;;
  i686*)                LIBDIR="\$RES/lib/linux/i386" ;;
  x86_64*)              LIBDIR="\$RES/lib/linux/x86_64" ;;
  *)                    LIBDIR="\$RES/lib/linux/aarch64" ;;
esac
exec $CC -rtlib=compiler-rt --unwindlib=libunwind -resource-dir="\$RES" -L"\$LIBDIR" "\$@"
WRAP
    chmod +x "$B/$T"
  done

  # -- x86_64 的 llvm binutils → qemu（备份用 cp -p 解引用，避免把符号链接当备份）--
  for t in llvm-objcopy llvm-nm llvm-objdump llvm-readelf; do
    [ -e "$B/$t" ] || continue
    [ -e "$B/$t.real" ] || cp -p "$B/$t" "$B/$t.real"
    rm -f "$B/$t"
    cat > "$B/$t" <<QWRAP
#!/bin/bash
exec $QEMU -L $X86LIBS "$B/$t.real" "\$@"
QWRAP
    chmod +x "$B/$t"
  done

  # -- ar / ranlib / strip 用宿主原生（llvm-strip 同样是符号链接，先删）--
  for pair in "llvm-ar:/usr/bin/ar" "llvm-ranlib:/usr/bin/ranlib" "llvm-strip:/usr/bin/strip"; do
    tool="${pair%%:*}"; real="${pair##*:}"
    [ -e "$B/$tool" ] || continue
    [ -e "$B/$tool.real" ] || cp -p "$B/$tool" "$B/$tool.real"
    rm -f "$B/$tool"
    printf '#!/bin/bash\nexec %s "$@"\n' "$real" > "$B/$tool"; chmod +x "$B/$tool"
  done

  # -- make 换宿主原生 --
  PM="$NDK_ROOT/$V/prebuilt/linux-x86_64/bin/make"
  if [ -e "$PM" ]; then
    [ -e "$PM.real" ] || cp -p "$PM" "$PM.real"
    printf '#!/bin/bash\nexec /usr/bin/make "$@"\n' > "$PM"; chmod +x "$PM"
  fi

  # -- 自检：C 与 C++ 都要能编，三种 ABI 都要能链接 --
  S="$B/../sysroot"; TMP=$(mktemp -d)
  printf 'int f(void){return 1;}\n' > "$TMP/t.c"
  printf 'class A{public:int v;}; int g(){A a; a.v=1; return a.v;}\n' > "$TMP/t.cpp"
  for t in "armv7a-linux-androideabi24" "aarch64-linux-android24" "x86_64-linux-android24"; do
    if "$B/clang" --target=$t --sysroot=$S -shared -fPIC "$TMP/t.c" -o "$TMP/o.so" 2>/dev/null; then ok "C  $t"; else printf '  \033[31m✗\033[0m C  %s\n' "$t"; fi
    if "$B/clang++" --target=$t --sysroot=$S -shared -fPIC "$TMP/t.cpp" -o "$TMP/o.so" 2>/dev/null; then ok "C++ $t"; else printf '  \033[31m✗\033[0m C++ %s\n' "$t"; fi
  done
  ok "clang   $("$B/clang" --version 2>/dev/null | head -1)"
  ok "llvm-ar $("$B/llvm-ar" --version 2>/dev/null | head -1)"
  rm -rf "$TMP"
done
log "完成"
