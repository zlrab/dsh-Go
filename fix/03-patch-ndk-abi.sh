#!/bin/bash
# 给 NDK 的 x86_64 宿主工具链打「原生 arm64 + ABI 感知」包装
# 覆盖 NDK 27.2（本机已有）与 28.2（Flutter 3.47 默认）
set -euo pipefail
NDK_ROOT="${NDK_ROOT:-/opt/android-sdk/ndk}"
VERSIONS="${NDK_VERSIONS:-27.2.12479018 28.2.13676358}"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
command -v /usr/bin/clang >/dev/null || { echo "需要 apt install clang lld"; exit 1; }

for V in $VERSIONS; do
  B="$NDK_ROOT/$V/toolchains/llvm/prebuilt/linux-x86_64/bin"
  [ -d "$B" ] || { echo "跳过 NDK $V（未安装）"; continue; }
  RES="$(ls -d "$B/../lib/clang/"* 2>/dev/null | sort -V | tail -1)"
  log "NDK $V → clang 资源目录 $(basename "$RES")"

  for T in clang clang++; do
    CC=/usr/bin/clang; [ "$T" = "clang++" ] && CC=/usr/bin/clang++
    # 备份真二进制（原本是 symlink 时只记录）
    if [ ! -e "$B/$T.x86_64" ]; then
      if [ -L "$B/$T" ]; then cp -a "$B/$(basename "$(readlink -f "$B/$T")")" "$B/$T.x86_64" 2>/dev/null || true
      else cp -a "$B/$T" "$B/$T.x86_64"; fi
    fi
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

  # llvm 的 binutils（objcopy/strip/nm/readelf/objdump）也是 x86_64：
  # release 的 extractReleaseNativeSymbolTables 会直接调 llvm-objcopy，这里用 qemu 包装
  for t in llvm-objcopy llvm-strip llvm-nm llvm-readelf llvm-objdump; do
    [ -e "$B/$t" ] || continue
    [ -e "$B/$t.x86_64" ] || cp -a "$B/$t" "$B/$t.x86_64"
    cat > "$B/$t" <<QWRAP
#!/bin/bash
exec qemu-x86_64-static -L /opt/x86libs "$B/$t.x86_64" "\$@"
QWRAP
    chmod +x "$B/$t"
  done

  # ar / ranlib / strip / make 同样换成原生
  for pair in "llvm-ar:/usr/bin/ar" "llvm-ranlib:/usr/bin/ranlib" "llvm-strip:/usr/bin/strip"; do
    tool="${pair%%:*}"; real="${pair##*:}"
    [ -e "$B/$tool" ] || continue
    [ -e "$B/$tool.x86_64" ] || cp -a "$B/$tool" "$B/$tool.x86_64" 2>/dev/null || true
    printf '#!/bin/bash\nexec %s "$@"\n' "$real" > "$B/$tool"; chmod +x "$B/$tool"
  done
  PM="$NDK_ROOT/$V/prebuilt/linux-x86_64/bin/make"
  if [ -e "$PM" ]; then
    [ -e "$PM.x86_64" ] || cp -a "$PM" "$PM.x86_64"
    printf '#!/bin/bash\nexec /usr/bin/make "$@"\n' > "$PM"; chmod +x "$PM"
  fi

  # 自检：三个 ABI 都能链接
  S="$B/../sysroot"
  TMP=$(mktemp -d); printf 'int f(void){return 1;}\n' > "$TMP/t.c"
  for t in "armv7a-linux-androideabi24" "aarch64-linux-android24" "x86_64-linux-android24"; do
    if "$B/clang" --target=$t --sysroot=$S -shared -fPIC "$TMP/t.c" -o "$TMP/o.so" 2>/dev/null; then
      echo "  ✓ $t"
    else
      echo "  ✗ $t（链接失败）"
    fi
  done
  rm -rf "$TMP"
done
log "完成"
