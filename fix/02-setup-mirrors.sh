#!/bin/bash
# 全链路镜像：Gradle 全局 init.gradle（改写仓库）+ Flutter Gradle 插件 + pub 缓存里的三方插件
set -euo pipefail
FLUTTER_ROOT="${FLUTTER_ROOT:-/opt/flutter}"
PUB_HOSTED="${PUB_HOSTED:-/root/.pub-cache/hosted/pub.dev}"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

log "1/4 写 ~/.gradle/init.gradle（改写而非追加，确保不再请求 dl.google.com）"
mkdir -p /root/.gradle
cat > /root/.gradle/init.gradle <<'GRV'
import org.gradle.api.artifacts.repositories.MavenArtifactRepository
def remap = { MavenArtifactRepository repo ->
    def u = repo.url.toString(); def n = null
    if (u.contains('dl.google.com') || u.contains('maven.google.com')) n = 'https://maven.aliyun.com/repository/google'
    else if (u.contains('repo.maven.apache.org') || u.contains('repo1.maven.org')) n = 'https://maven.aliyun.com/repository/central'
    else if (u.contains('plugins.gradle.org')) n = 'https://maven.aliyun.com/repository/gradle-plugin'
    if (n != null) repo.url = uri(n)
}
allprojects { p -> p.buildscript.repositories.all { r -> if (r instanceof MavenArtifactRepository) remap(r) }
                  p.repositories.all { r -> if (r instanceof MavenArtifactRepository) remap(r) } }
settingsEvaluated { s ->
    s.pluginManagement.repositories.all { r -> if (r instanceof MavenArtifactRepository) remap(r) }
    s.dependencyResolutionManagement.repositories.all { r -> if (r instanceof MavenArtifactRepository) remap(r) }
}
GRV

log "2/4 给 Flutter 自带 Gradle 插件加镜像（includeBuild 会绕过工程配置）"
S="$FLUTTER_ROOT/packages/flutter_tools/gradle/settings.gradle.kts"
if [ -f "$S" ] && ! grep -q aliyun "$S"; then
  cp "$S" "$S.bak"
  python3 - "$S" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("""    repositories {
        google()""","""    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        google()""")
open(p,'w').write(s)
print("已加镜像")
PY
else
  echo "  已处理或文件不存在"
fi

log "3/4 给 pub 缓存里写死 google() 的插件插镜像"
python3 - "$PUB_HOSTED" <<'PY'
import glob, os, shutil, sys
root=sys.argv[1]
files=glob.glob(os.path.join(root,'*/android/**/build.gradle*'), recursive=True)
n=0
for f in files:
    try: s=open(f,encoding='utf-8').read()
    except Exception: continue
    if 'google()' not in s and 'mavenCentral()' not in s: continue
    kts=f.endswith('.kts')
    mg=('maven { url = uri("https://maven.aliyun.com/repository/google") }' if kts else "maven { url 'https://maven.aliyun.com/repository/google' }")
    mc=('maven { url = uri("https://maven.aliyun.com/repository/central") }' if kts else "maven { url 'https://maven.aliyun.com/repository/central' }")
    if mg in s or mc in s: continue
    if not os.path.exists(f+'.bak'): shutil.copy2(f, f+'.bak')
    s=s.replace('google()', mg+'\n        google()').replace('mavenCentral()', mc+'\n        mavenCentral()')
    open(f,'w',encoding='utf-8').write(s); n+=1
print(f"  已处理 {n} 个插件脚本（原文件保留 .bak）")
PY

log "4/4 把镜像缓存补进 pub.dev 缓存（让 --offline 命中锁定版本，pub get 就不会改写 pubspec.lock）"
SRC=/root/.pub-cache/hosted/pub.flutter-io.cn
DST=/root/.pub-cache/hosted/pub.dev
n=0
for d in "$SRC"/*/; do
  b=$(basename "$d")
  [ -e "$DST/$b" ] || { cp -a "$d" "$DST/$b"; n=$((n+1)); }
done
hsrc=/root/.pub-cache/hosted-hashes/pub.flutter-io.cn hdst=/root/.pub-cache/hosted-hashes/pub.dev m=0
if [ -d "$hsrc" ]; then
  mkdir -p "$hdst"
  for f in "$hsrc"/*; do
    b=$(basename "$f")
    [ -e "$hdst/$b" ] || { cp -a "$f" "$hdst/$b"; m=$((m+1)); }
  done
fi
echo "  补包 $n 个、hash $m 个（已存在的不动）"

log "完成。注意：新增/升级依赖后，先联网 pub get（镜像），再重跑本脚本把缺失的包补进离线缓存。"
