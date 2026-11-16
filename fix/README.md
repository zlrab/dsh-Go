# 在 arm64 Android 手机上构建 dsh-Go APK（方案 C 交付说明）

> 环境：小米 14 / Android 15 / proot Ubuntu 24.04 (aarch64)，无 root、无 Docker、无 systemd
> 结果：**`flutter build apk --debug --flavor arm64` 成功**，产出 149MB arm64 APK，用自有 keystore 签名
> 实测：Gradle 构建 11m03s（首次，含依赖下载）；产物 `/sdcard/Download/DSH-Loop/dsh-go-arm64-debug.apk`

---

## 1. 为什么官方流程在这台机器上跑不起来

| # | 卡点 | 现象 |
|---|---|---|
| 1 | Flutter 官方只发布 **linux-x64** SDK（751 个 release，`dart_sdk_arch` 全是 x64） | SDK 里的 `dart` 是 x86-64 ELF，arm64 上直接 `cannot execute` |
| 2 | 用 qemu 模拟 x64 Dart | `dart --version` 能打印，但**执行任何代码都 rc=255 静默退出**（Dart VM 的 syscall 无法模拟） |
| 3 | 换成原生 arm64 Dart 后，`flutter_tools.snapshot` 是 **x64 AOT 快照** | `Snapshot not compatible with the current VM configuration … x64 … arm64` |
| 4 | 尝试在本机重编快照（`--snapshot-kind=app-jit`） | 进程卡死在 `futex_wait`，CPU 不再增长（proot 下死锁） |
| 5 | `dl.google.com` 不可达（VPN 也没救，TLS 握手中断） | Flutter 三方插件写死 `google()`，AGP 还会自动下载 SDK 组件 → 构建**长时间挂起**而非报错 |
| 6 | `/sdcard` 是 FUSE（`noexec`、不支持 symlink/hardlink/flock） | `gradlew` 无法加执行位 → `Found candidates, but lacked sufficient permissions to execute …/gradlew` |
| 7 | NDK 的 clang 是 x86_64；简单 qemu 包装在链接 32 位 ARM 时会抓错 `libunwind.a` | `libunwind.a(...) is incompatible with armelf_linux_eabi` |

---

## 2. 五处适配（每处都是最小改动）

### 2.1 换掉 Flutter 内置的 Dart 运行时

```bash
# 版本必须与 Flutter 内置一致（本工程 3.47.7 内置 Dart 3.13.5）
curl -O https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.5/sdk/dartsdk-linux-arm64-release.zip
unzip dartsdk-linux-arm64-release.zip -d /tmp/arm64-dart
mv /opt/flutter/bin/cache/dart-sdk /opt/flutter/bin/cache/dart-sdk.x64   # 备份
cp -a /tmp/arm64-dart/dart-sdk /opt/flutter/bin/cache/dart-sdk
echo "$(cat /opt/flutter/bin/internal/engine.version)" > /opt/flutter/bin/cache/engine-dart-sdk.stamp
```

### 2.2 让 flutter 工具从源码运行（跳过 x64 快照）

`/opt/flutter/bin/internal/shared.sh` 末尾的 exec 分支前插入：

```bash
      # arm64 补丁：跳过 x64 AOT 快照，直接 JIT 跑 flutter_tools 源码
      if [ "${FLUTTER_RUN_FROM_SOURCE:-1}" = "1" ]; then
        exec "$DART" --packages="$FLUTTER_TOOLS_DIR/.dart_tool/package_config.json" \
             $FLUTTER_TOOL_ARGS "$FLUTTER_TOOLS_DIR/bin/flutter_tools.dart" "$@"
      fi
```

并把 stamp 写成「已是最新」，避免它尝试重编（会死锁）：

```bash
echo "$(git -C /opt/flutter rev-parse HEAD):" > /opt/flutter/bin/cache/flutter_tools.stamp
```

### 2.3 全仓库镜像（关键：**改写**不是追加）

`~/.gradle/init.gradle`：

```groovy
def remap = { repo ->
    def u = repo.url.toString(); def n = null
    if (u.contains('dl.google.com') || u.contains('maven.google.com')) n = 'https://maven.aliyun.com/repository/google'
    else if (u.contains('repo.maven.apache.org') || u.contains('repo1.maven.org')) n = 'https://maven.aliyun.com/repository/central'
    else if (u.contains('plugins.gradle.org')) n = 'https://maven.aliyun.com/repository/gradle-plugin'
    if (n) repo.url = uri(n)
}
allprojects { p -> p.buildscript.repositories.all(remap); p.repositories.all(remap) }
settingsEvaluated { s -> s.pluginManagement.repositories.all(remap); s.dependencyResolutionManagement.repositories.all(remap) }
```

另外两处：
- `/opt/flutter/packages/flutter_tools/gradle/settings.gradle.kts`：`repositories` 里加阿里云（Flutter 自带 Gradle 插件是 includeBuild，会绕过工程配置）
- `~/.pub-cache/hosted/pub.dev/*/android/build.gradle(.kts)`：12 个插件写死了 `google()`，在其前面插入阿里云

### 2.4 关掉 AGP 的 SDK 自动下载

```properties
# app/android/gradle.properties
android.builder.sdkDownload=false
systemProp.org.gradle.internal.http.connectionTimeout=20000
systemProp.org.gradle.internal.http.socketTimeout=60000
systemProp.org.gradle.internal.repository.max.retries=4
```

否则缺一个 platform 就会触发自动下载 → 卡在不可达的 Google 域名上，**既不报错也不退出**。

### 2.5 NDK 工具链：ABI 感知的 clang 包装

NDK 只发 `linux-x86_64` 宿主工具链，用原生 arm64 clang + NDK sysroot 替代。包装脚本必须按 `--target` 选 compiler-rt 目录（**不能对整个参数串匹配**，`--sysroot` 路径里也有 `x86_64`）：

```bash
TARGET=""
for a in "$@"; do case "$a" in --target=*) TARGET="${a#--target=}";; esac; done
case "$TARGET" in
  armv7*|*androideabi*) LIBDIR="$RES/lib/linux/arm" ;;
  i686*)                LIBDIR="$RES/lib/linux/i386" ;;
  x86_64*)              LIBDIR="$RES/lib/linux/x86_64" ;;
  *)                    LIBDIR="$RES/lib/linux/aarch64" ;;
esac
exec /usr/bin/clang -rtlib=compiler-rt --unwindlib=libunwind -resource-dir="$RES" -L"$LIBDIR" "$@"
```

---

## 3. 需要的组件（都已从国内镜像装好）

| 组件 | 版本 | 说明 |
|---|---|---|
| JDK | 17.0.21 (arm64) | apt |
| Gradle | **9.3.1** | 工程 `gradle-wrapper.properties` 指定的版本，腾讯镜像下载 |
| Android platform | 34 / **35** / **36** | 35 是插件 `:jni` 的 compileSdk，缺了会静默挂起 |
| build-tools | 34 / 35 / 36 | |
| NDK | 27.2（打补丁）/ **28.2** | Flutter 3.47 默认 `28.2.13676358` |
| Flutter SDK | 3.47.7 | 官方 x64 包 + arm64 Dart 替换 |
| 镜像 | 阿里云 Maven / 腾讯 Gradle & SDK | |

---

## 4. 怎么用

```bash
# 仓库在 /root（有执行位）；脚本仍统一用 bash 调用
cd /root/DSH-Loop

bash fix/00-check-env.sh      # 体检：缺什么一目了然
bash fix/01-setup-flutter-arm64.sh   # 装 Flutter + arm64 Dart + 打补丁（幂等）
bash fix/02-setup-mirrors.sh         # 写 init.gradle、改 Flutter 插件与 pub 缓存仓库
bash fix/03-patch-ndk-abi.sh         # 给 NDK 27.2 / 28.2 打 ABI 感知包装（已修正符号链接穿透，见下）
bash fix/06-setup-box64.sh           # box64（release 的 AOT 编译器靠它模拟 x86_64）
bash fix/07-install-aot-wrapper.sh   # 把 gen_snapshot 接到 box64
bash fix/10-adapt-host-tools.sh      # x86libs / qemu10 / aapt2 override / cmake 包装 / sqlite3 离线补丁 / 环境变量
bash runtime/build-runtime.sh arm64-v8a   # 自建运行时资产（原地跑；放 /sdcard 会慢好几倍）
bash fix/04-build-apk-arm64.sh       # 原地构建，复制 APK 到 /sdcard
bash fix/99-verify-apk.sh            # 校验签名/包名/架构
```

> **fix/10 是 2026-11-15 新增的**：把「arm64 手机上跑 x86_64 构建工具」需要的手工适配固化成幂等脚本。
> 缺了它会出现三类失败：Gradle 报 aapt2 daemon 启不来、`:jni` 报 CMake 3.22.1 找不到、
> sqlite3 native assets 去 GitHub 下载超时。细节见脚本头部注释。
>
> **fix/03 已于 2026-11-15 修正**：NDK 28.2 的 `clang`/`clang++`/`llvm-strip`/`llvm-readelf` 都是符号链接，
> 旧版脚本 `cat >` 会穿透链接写坏真二进制（症状：CMake 报「The C compiler is a C++ compiler」）。

产物：`/sdcard/Download/DSH-Loop/dsh-go-arm64-debug.apk`

---

## 5. 边界与已知限制

| 项 | 状态 |
|---|---|
| **debug APK** | ✅ 已验证可构建，且用 release 密钥签名（因为 `key.properties` 齐全） |
| **release APK（AOT）** | ✅ **已跑通**：box64 全量构建 392s，产物与 qemu 逐字节一致，装机后正常渲染。详见第 10、12 节 |
| 增量构建 | debug 重建 ~3 分钟（依赖已缓存）；release 全量 6~7 分钟（box64） |
| 装机验证 | ✅ 已做：debug 与 release 均装机并通过 `pidof`/日志/截图验证 |
| 工程位置 | 源码在 `/root/DSH-Loop`（ext4，有执行位）→ **源码目录即构建目录，原地构建**；远端在 GitHub，`/sdcard` 只放 APK 与签名密钥 |
| 签名 | `keyStores/lizow.keystore`，alias `lizow`，详见同级 `keyStores/keyinfo.yaml` |

### 回滚

所有改动都留了备份：`*.bak`（flutter 的 shared.sh / settings.gradle.kts、pub 缓存插件、NDK bin），`/opt/flutter/bin/cache/dart-sdk.x64`（原版 Dart）。删掉 `~/.gradle/init.gradle` 即可取消全局镜像。

---


---


---


---

## 6. 为什么最终选择「方案 C」

| 方案 | 结论 |
|---|---|
| A. PC 构建 | 最稳，但用户要求必须手机跑通 |
| B. GitHub Actions | 更快，但需要联网推送与云端额度 |
| **C. 手机原生 Flutter + 镜像 + 工具链替换** | ✅ **已跑通**（本文件描述的全部改动） |

---

## 7. 自定义包名（applicationId）

只改 **applicationId**，`namespace` 与 Kotlin 包名保持不动（这样 R 类、MainActivity、清单里
`${applicationId}` 占位符都无需调整）：

```kotlin
// app/android/app/build.gradle.kts
android {
    namespace = "io.github.ccch1mneyyy.dsh_app"   // 不动
    defaultConfig {
        applicationId = "com.lizow.dsh"           // 只改这里
    }
}
```

验证：`aapt2 dump badging app-arm64-debug.apk | grep ^package` → `name='com.lizow.dsh'`。

注意：
- applicationId 变了就是**另一个 App**，可与原版共存，但数据不迁移；
- `app/lib/dev/runtime_probe_main.dart` 里有个开发探针写死了旧包名的数据目录路径，
  只影响那个 dev 探针，不影响正常运行；
- 清单里的自定义 action（`…PHONE_ADB_PAIR_CODE`）用的是 namespace 字面量，保持原样即可。

## 8. 坑：sqlite3 的 native assets 会去 GitHub 下载预编译库

`flutter assemble` 阶段，`sqlite3` 包的 `hook/build.dart` 会下载
`libsqlite3.<abi>.android.so`（三个 ABI：arm / arm64 / x64）。GitHub 慢或被墙时表现为：

```
Target build_hooks failed: Error: Building native assets failed.
Original cause: SocketException: Connection timed out … address = github.com
```

解法（已固化进 `04-build-apk-arm64.sh`）：把三个 `.so` 下到 `/opt/prebuilt/`，
并给 `sqlite3` 的 hook 打一个小补丁，优先读本地目录：

```dart
// ~/.pub-cache/hosted/pub.dev/sqlite3-3.9.1/lib/src/hook/compile/description.dart
final localDir = Platform.environment['SQLITE3_PREBUILT_DIR'];
if (localDir != null && localDir.isNotEmpty) {
  final local = File('$localDir/$filename');
  if (local.existsSync()) { yield local.readAsBytesSync(); return; }
}
```

构建时导出 `SQLITE3_PREBUILT_DIR=/opt/prebuilt` 即可，完全离线。

---

## 9. 必须带上「运行时资产」，否则装上也起不来

APK 里除了代码，还要有 `assets/runtime/`（rootfs 压缩包 + manifest）和 4~5 个 proot 的 `.so`。
`app/android/app/build.gradle.kts` 从 `runtime/out/<abi>/{assets,jniLibs}` 读取；这个目录默认是空的
（由 `runtime/build-runtime.sh` 生成）。缺了它的表现就是启动页显示：

> 安装未完成 · App 内的运行环境包不完整，请重新安装 App

日志里等价于 `manifest: runtime/manifest.json` 找不到。

两条补齐途径：

| 方式 | 说明 | 耗时 |
|---|---|---|
| **B. 从已装官方包提取**（推荐） | `bash fix/05-fetch-runtime-assets.sh`，adb pull 官方 base.apk 后解出 `assets/runtime/*` 与 proot `.so` | 约 1 分钟 |
| A. 自己构建 | `runtime/build-runtime.sh arm64`（下 Ubuntu base、Node、DSH 树并打补丁） | 较慢，且依赖网络 |

注意 `jniLibs` 只放 proot 相关（`libproot.so`、`libproot-loader.so`、`libtalloc.so`、
`libandroid-shmem.so`、`libtawcroot.so`）；千万别把 `libapp.so`、`libflutter.so` 一起拷进去。
带上资产后 APK 约 300MB（debug）。

验证：装好启动 → 首屏底部会出现「运行环境 x%」，100% 后进入终端，出现 `root@localhost:~/workspace#`。

---

## 10. release（AOT）为什么差点走不通，以及怎么打通的

### 10.1 现象

release 包装上后卡在启动页，logcat 里是这句话（决定性证据）：

```
E flutter : CreateRootIsolate failed: Snapshot not compatible with the current VM configuration:
  the snapshot requires 'release ... arm64 linux  no-compressed-pointers'
  but the VM has          'product ... arm64 android compressed-pointers'
```

也就是说：AOT 快照打出来了，但它是 **linux 目标**（`linux`、`release`、无压缩指针），
而 Android 上的 Dart VM 是 `android`、`product`、压缩指针 —— 两者不兼容。

### 10.2 根因

`gen_snapshot` 是「宿主工具」，Flutter 只为 **x64 宿主**发布 Android 用的版本：

```
android-arm64-release/linux-x64/gen_snapshot     ← 官方唯一的 Android AOT 工具（x86_64）
linux-arm64/gen_snapshot                         ← 给 Linux 桌面 arm64 用的（我们误用了它）
```

- 直接跑 x64 版本：本机跑不了（qemu 下 Dart VM 一执行代码就 `rc=255`，第 1 节的实测）
- 拿 `linux-arm64/gen_snapshot` 顶替：能产出快照，但目标 OS 不对（就是 10.1 的错误）
- 自己编 arm64 版 gen_snapshot：要从 Flutter engine 源码构建，代价远超本机能力

Flutter 代码里也留着同一个 TODO（`artifacts.dart`）：
> Build Android gen_snapshot as Arm64 binary to run natively on Apple Silicon.

连 Apple Silicon 都还在用 x64 的 gen_snapshot（靠 Rosetta），所以**目前不存在任何 arm64 宿主的 Android AOT 工具**。

### 10.3 结论：解法是「模拟 x64 的官方编译器」，不是「换 arm64 编译器」

| 尝试 | 结果 |
|---|---|
| 用 `linux-arm64/gen_snapshot`（桌面 arm64 版） | ❌ 快照目标是 linux，Android VM 拒绝加载 |
| 下载 Dart arm64 SDK 的 gen_snapshot 替换 | ❌ 它不接受 `--target-os/--target-arch`；Dart 交叉编译只支持 `linux_arm/linux_arm64/linux_riscv64/linux_x64`，**没有 android** |
| 找 Flutter 的 linux-arm64 SDK | ❌ 官方发布里 `dart_sdk_arch` 全是 x64，没有 arm64 构建 |
| **模拟运行官方 x64 的 Android gen_snapshot** | ✅ **这就是正解**（qemu 或 box64，见第 12 节） |

关键区别：`gen_snapshot` 是**按目标预编译的专用二进制**（架构烧死在二进制里），
不是「一个交叉编译器通吃所有目标」。所以只能让 x64 版在 arm64 上跑起来。

### 10.4 沿途踩的三个坑（都已修）

| 坑 | 现象 | 修法 |
|---|---|---|
| qemu 8.2 内部崩溃 | `QEMU internal SIGSEGV {code=MAPERR, addr=0x20}`，rc=-11 | 换 Debian trixie 的 qemu-user **10.0.13**（`06`/`07` 脚本） |
| dart CLI 在 qemu 下 rc=255 | 误以为"qemu 跑不了所有 Dart 工具" | 其实 dart 是启动器，内部 `execve dartvm` —— qemu 不支持 guest 链式 exec；`gen_snapshot` 是单进程，不受影响 |
| APK 缺 manifest/arsc | 874 条目里没有 `AndroidManifest.xml` | `android.enableResourceOptimizations=false`（aapt2 optimize 在 qemu/box64 下不产出文件） |

---

## 11. 低成本构建配置（本地构建专用）

已写入源码工程，目的：省内存、省时间，且**顺带修好了 release 缺 manifest 的问题**。

`app/android/app/build.gradle.kts`：

```kotlin
android {
    lint {                       // 78 个 lint 任务，与产物无关
        checkReleaseBuilds = false
        abortOnError = false
        checkDependencies = false
    }
    buildTypes {
        release {
            isMinifyEnabled = false       // R8：省 3~4GB 内存 / 5 分钟
            isShrinkResources = false
            ndk { debugSymbolLevel = "none" }  // 不抽 native 符号（也绕开 qemu 的 llvm-objcopy）
        }
    }
}
```

`app/android/gradle.properties`：

```properties
android.enableResourceOptimizations=false   # 关键：aapt2 optimize 在 qemu 包装下不产出文件，
                                            # 会导致最终 APK 丢掉 AndroidManifest.xml / resources.arsc
```

效果：release 构建 **16m42s → 3m21s**，峰值内存 12.8GB → 约 8GB，且产物结构完整。
（这些配置只适合本地自用；发版必须恢复 R8 + lint。）

---

## 12. box64：把 release 构建从 40 分钟压到 6 分半

### 12.1 为什么是 box64

模拟层有两种：

| 方案 | 原理 | AOT 编译 | 全量 release 构建 |
|---|---|---|---|
| qemu TCG（`07 ... qemu`） | 每条指令实时翻译 | ~33 分钟仍未跑完 | 2377s（39m37s） |
| **box64 Dynarec（默认）** | 翻译一次并缓存成 arm64 原生码 | **686s**（且与 3 个 qemu 抢 CPU 时测的） | **392s（6m32s）** |

两者产物**逐字节相同**（`libapp.so` 58,012,344 字节，`cmp` 无差异），
装机后启动正常（无 `Snapshot not compatible`，Impeller Vulkan 渲染）。

### 12.2 用法

```bash
bash 06-setup-box64.sh          # 装 box64（Debian 包 + 官方 x86_64 库包）
bash 07-install-aot-wrapper.sh  # 接线（默认 box64；加 qemu 参数则用 qemu）
bash 04-build-apk-arm64.sh --release
```

`04` 默认 `BOX64=1`；找不到包装会自动调 `07`。想回退：`BOX64=0 bash 04-...`。

### 12.3 一个必须知道的怪癖

box64 跑 gen_snapshot 时，**退出清理阶段会 `double free or corruption` 崩掉**（rc≠0），
但此时 `--elf` 指定的产物已经完整落盘。所以包装脚本里做了这个保护：

```bash
# 产物存在且 > 40MB 就按成功返回，避免 Flutter 误判为 AOT 失败
if [ -n "$ELF" ] && [ -s "$ELF" ] && [ "$(stat -c%s "$ELF")" -gt 40000000 ]; then
  exit 0
fi
```

实测该产物与 qemu 生产的完全一致，可放心使用。

### 12.4 顺带验证掉的伪优化

网上常见的两条「提速建议」在 qemu user-mode 上都不成立（实测）：

| 建议 | 实测 |
|---|---|
| `export QEMU_CACHE_SIZE=512M` | ❌ 二进制里没有这个变量；真实的是 `QEMU_TB_SIZE` / `-tb-size` |
| `qemu-x86_64 -tcg opt=all` | ❌ `unknown option 'tcg'`；user-mode 无 `-tcg`/`-accel`，TCG 优化级别是编译期固定的 |
| `-tb-size 512M` | ❌ 单位不能带后缀，必须写纯数字 `-tb-size 512` |

（`-tb-size` 本身是合法参数，但在本机 33 分钟基准里三组始终同步、未跑完即被叫停，
没有观察到可信收益；真正的量级提升来自换 box64。）

### 11.1 原地构建与构建缓存（2026-11-16 迁移后）

仓库搬进 App 工作区（`/root/DSH-Loop`，ext4 有执行位）后，**源码目录就是构建目录**：
不再有 rsync 副本，`build/`、`.dart_tool/`、`android/.cxx/` 就地保留，改完源码直接重建。
需要强制全量时用 `FULL=1 bash fix/04-build-apk-arm64.sh --release`。
（仓库被迫放在 `/sdcard` 这类 noexec 挂载上时，`04` 仍支持副本模式：`SRC=… DST=/root/build/dsh-Go`。）

**pub 依赖走离线缓存**：`04` 用 `flutter pub get --offline` 解析，命中 `pubspec.lock` 锁定的版本——
约 40 秒，且不会把 lock 里的 `url: pub.dev` 改成镜像 host（改了就不该提交）。
新增/升级依赖时离线会失败，脚本回退镜像联网，并在跑完后 `git checkout` 还原 `pubspec.lock`；
若新包不在本地缓存，先跑一次 `bash fix/02-setup-mirrors.sh`（第 4 步把镜像缓存补进 pub.dev 缓存）。

实测（arm64 手机，box64）：

| 场景 | 耗时 |
|---|---|
| 无改动重建 | **238s** |
| 改一行 Dart 后重建 | **1083s**（其中 Gradle 969s，几乎全是 AOT） |
| 全量（FULL=1） | 971~1083s |

**为什么改一行也要 18 分钟**：Flutter 的 release AOT 用 `gen_snapshot` 做**整程序编译**，
没有按文件/按函数的增量能力；`app.dill` 变了就必须重新生成整个 `libapp.so`（55MB），
再重新打包 278MB 的 APK。Gradle 层面能缓存的是 Kotlin/Dart 以外的任务。

**实践建议**：日常改 UI / 逻辑用 debug 构建（JIT，~3 分钟）验证；
确认要发布或自举时，才付 release 的 16~18 分钟。
