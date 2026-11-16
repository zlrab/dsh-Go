# 交接说明（最终版）：dsh-Go 在 arm64 手机上自举构建

> 2026-11-15 更新。已在旧环境完整跑通一次：**从零构建 runtime → buildbox64 出包 → 覆盖安装 → 运行正常**。
> **2026-11-16 迁移完成**：仓库从 `/sdcard` 拷入 App 工作区 `/root/DSH-Loop`，源码目录即构建目录；全量 debug 构建 + 真机安装验证均通过（见 `fix/FORK.md` 第八节）。**协作与验证规范见 `SPEC.md`。**
> 接手第一件事：读第 5 节照做；第 4 节是死路，别重复试；第 6 节定义"升级"的确切语义。

---

## 0. 目标

改完源码 → **手机内**构建签名 APK → **覆盖安装**自身 → 新代码生效，**数据不丢**，全程不依赖 PC/CI。

## 1. 环境事实（决定所有做法）

| 事实 | 后果 |
|---|---|
| proot Ubuntu 24.04 **aarch64**，无 root / 无 systemd / 无 Docker | 不能装服务、不能绑 <1024 端口 |
| `/sdcard` 是 FUSE：无符号链接/硬链接/flock/**执行位** | `gradlew` 在 /sdcard 跑不起来 → 仓库放 `/root`，原地构建（迁移前靠 `/root` 副本） |
| App 私有目录（`/root`、`/opt`）随卸载清空 | 源码靠 GitHub 兜底；签名密钥与 APK 产物留在 `/sdcard` |
| 内存 15GB，构建峰值 ~8GB；`/sdcard` 可用 400GB+ | 构建前确保可用内存 ≥ 4.5GB、磁盘 ≥ 6GB |
| 宿主无 KVM，x86 工具只能软件模拟 | aapt2/aidl 用 qemu 包装；AOT 编译器用 box64 |
| 手机 CPU aarch64，官方 Flutter 只发 x64 宿主的 Android AOT 编译器 | **必须模拟**，没有原生替代（见第 4 节） |

## 2. 资产地图

| 路径 | 内容 | 会丢？ |
|---|---|---|
| `/root/DSH-Loop` | **源码工程 = 构建目录**（git `main-phone`） | 会（GitHub 上有） |
| `github.com/zlrab/dsh-Go` | 远端：`main`（上游镜像）+ `main-phone`（产线） | 不会 |
| `…/AndroidProjects/keyStores/lizow.keystore` | **签名密钥**，丢了永久无法覆盖安装 | 不会 |
| `…/keyStores/keyinfo.yaml` | 密钥信息（含密码，勿外传） | 不会 |
| `/sdcard/Download/DSH-Loop/*.apk` | 构建产物（last-good 候选） | 不会 |
| `dsh-Go/fix/` | 8 个适配脚本 + `README.md`（原理）+ `SELFHOST.md`（自举设计） | 不会 |
| `dsh-Go/runtime/out/` | 自建 runtime 资产（154MB，被 gitignore，换机需重建） | 会 |

## 3. 已完成（不要重做）+ 实测数据

| 项 | 结果 |
|---|---|
| runtime 从零构建（arm64 宿主） | ✅ 153MB rootfs，ELF 审计 `wrong-arch: 0` |
| release 构建（box64） | ✅ 278.5MB APK，`com.lizow.dsh` |
| debug 构建（JIT） | ✅ 472MB APK，`com.lizow.dsh.debug`，桌面名「DSH Go 调试」 |
| 全量 release 构建 | 1083s（18 分钟，AOT 占 ~16 分钟） |
| 无改动重建 | **238s**（增量同步 + 缓存命中） |
| debug 构建 | 487s（8 分钟，含 472MB 打包） |
| 产物一致性 | box64 与 qemu 产出的 `libapp.so` **逐字节相同**（58,012,344 B） |
| 覆盖安装 + 运行 | ✅ release 与 debug 均可装机运行，双包共存互不影响 |

**关键修复 4 条**

1. qemu 8.2 跑真实编译内部 `SIGSEGV (addr=0x20)` → 换 Debian **qemu-user 10.0.13**
2. dart CLI 在 qemu 下 rc=255 是「启动器 execve dartvm」所致，**不代表 gen_snapshot 不能跑**
3. release APK 缺 `AndroidManifest.xml`/`resources.arsc` → `android.enableResourceOptimizations=false`
4. R8/lint/native 符号抽取无用且吃 3~4GB → 已在 `build.gradle.kts` 关闭

**源码工程改动（5 个文件 + fix/）**

| 文件 | 改动 |
|---|---|
| `app/android/app/build.gradle.kts` | `applicationId=com.lizow.dsh`；lint 关闭；release 关 R8/资源压缩/符号抽取；debug 加 `applicationIdSuffix=".debug"` + `versionNameSuffix="-debug"` |
| `app/android/gradle.properties` | `android.enableResourceOptimizations=false` |
| `app/android/app/src/main/AndroidManifest.xml` | `android:label` 由硬编码 `"DSH Go"` 改为 `@string/app_name` |
| `app/android/app/src/main/res/values/strings.xml` | **新建**，`app_name = DSH Go` |
| `app/android/app/src/debug/res/values/strings.xml` | **新建**，覆盖 `app_name = DSH Go 调试` |
| `fix/` | 未跟踪交付目录（脚本 + README + SELFHOST） |

## 4. 已证伪的路线（别再试）

| 想法 | 为什么不行 |
|---|---|
| 用 `linux-arm64/gen_snapshot` 出 Android 快照 | 快照目标 linux，Android VM 拒绝：`Snapshot not compatible` |
| 换 Dart arm64 SDK 的 gen_snapshot | 它**不接受** `--target-os/--target-arch`；Dart 交叉编译只支持 `linux_*`，**没有 android** |
| 找 Flutter 的 linux-arm64 SDK | 官方发布 `dart_sdk_arch` 全是 x64 |
| `QEMU_CACHE_SIZE=512M` | 变量不存在（真名 `QEMU_TB_SIZE`/`-tb-size`）；`-tb-size 512M` 也不行，要纯数字 |
| `qemu -tcg opt=all` | user-mode 无此选项 |
| 在 /sdcard 直接构建 | FUSE 无执行位 |

## 5. 从零搭建（新环境照做）

### 5.1 前置工具

```bash
for t in curl sha256sum python3 tar xz gpgv npm zstd; do command -v $t || echo "缺 $t"; done
```

### 5.2 两个必修项（不修一定失败）

**① proot pin 过期**（Termux 已下架 5.1.107.98，现存 5.1.107.102）：

```bash
sed -i 's/^PROOT_VERSION="5.1.107.98"$/PROOT_VERSION="5.1.107.102"/' runtime/build-runtime.sh
```

该行是**硬编码赋值**，用环境变量覆盖无效。脚本对未 pin 的版本会自动从 Packages 索引解析路径与 SHA256。

**② 缺 zstd**：`apt-get install -y zstd`（`rtbuild.py` 解 `.zst` 索引用，但依赖检查没列它）。

### 5.3 执行顺序

```bash
cd /root/DSH-Loop
bash fix/00-check-env.sh                 # 体检
bash fix/01-setup-flutter-arm64.sh       # Flutter + arm64 原生 Dart
bash fix/02-setup-mirrors.sh             # 国内镜像
bash fix/03-patch-ndk-abi.sh             # NDK ABI 适配（qemu 包装）
bash fix/06-setup-box64.sh               # box64
bash fix/07-install-aot-wrapper.sh       # gen_snapshot 包装（box64 模式）
bash runtime/build-runtime.sh arm64-v8a  # 自建 runtime（必须自己构建）
bash fix/04-build-apk-arm64.sh --release
bash fix/99-verify-apk.sh /sdcard/Download/DSH-Loop/app-arm64-release.apk
```

**工程本来就该在 `/root`**（ext4）：`runtime/.cache`/`.work` 在工程目录内，FUSE 上装 npm 依赖慢很多倍（`/root` 组装阶段仅 282s）。

### 5.4 耗时参考

| 阶段 | 时间 |
|---|---|
| 工具链安装（网络为主） | 40~60 分钟 |
| runtime 从零构建（含下载） | ~10 分钟 |
| release 全量构建（FULL=1 或首次） | ~18 分钟 |
| release 无改动重建（缓存命中） | **238s（4 分钟）** |
| release 改一行 Dart 后重建 | **1083s（18 分钟）** |
| **debug 构建（JIT，无 AOT）** | **487s（8 分钟）** |

> **关键认知**：Flutter 的 release AOT 是**整程序编译，没有增量模式**。
> 所以「改一行 Dart」也要重跑 AOT（约 10 分钟）+ 重打包 278MB APK。

### 5.5 迭代策略：双包并行（已实现并验证）

| | release | debug |
|---|---|---|
| 包名 | `com.lizow.dsh` | `com.lizow.dsh.debug` |
| 桌面名 | DSH Go | **DSH Go 调试** |
| versionName | 1.0.16 | 1.0.16-debug |
| 构建 | `fix/04 --release` | `fix/04 --debug` |
| 耗时 | 18 分钟（AOT） | 8 分钟（JIT，无 AOT） |
| 数据 | 独立 | **独立**（首次启动需重新解压运行时） |
| 用途 | 发布 / 自举 | 日常改代码验证 |

**互不影响**：装 debug 不会顶掉 release，卸载任一方也不动另一个。两者用同一把密钥签名。

实现方式（标准 Android 资源覆盖，不是 build.gradle 的 resValue）：

```
src/main/res/values/strings.xml   → app_name = DSH Go
src/debug/res/values/strings.xml  → app_name = DSH Go 调试   ← 覆盖
AndroidManifest: android:label="@string/app_name"
build.gradle.kts: debug { applicationIdSuffix=".debug"; versionNameSuffix="-debug" }
```

> ⚠️ debug 包 472MB：Flutter debug 引擎（`libflutter.so` 377MB + Vulkan 校验层 237MB）+ kernel blob 206MB。
> 首次安装慢，但数据目录独立保留，后续重建不必重装运行时。

## 6. 自举闭环语义（关键，别搞错）

### 6.1 是**覆盖安装**，不是卸载重装

现有实现（`app/android/.../update/ApkInstaller.kt`）：

```kotlin
val params = PackageInstaller.SessionParams(MODE_FULL_INSTALL).apply {
    setAppPackageName(context.packageName)   // 目标是自己
}
session.commit(pending.intentSender)        // 提交 → 系统替换，保留 /data/data
```

覆盖安装成立的三个前提：

| 前提 | 现状 |
|---|---|
| 同包名 | `com.lizow.dsh` ✓ |
| 同签名 | 同一把 `lizow.keystore`（`4db3353…`）✓ |
| versionCode 不降级 | 构建分钟号单调递增 ✓ |

**只有三种情况会丢数据**（都不是正常更新）：

| 情况 | 系统返回 | 后果 |
|---|---|---|
| 签名不一致 | `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 只能卸载 → 数据全丢 |
| versionCode 变小（时钟回拨） | `INSTALL_FAILED_VERSION_DOWNGRADE` | 装不上（数据还在） |
| 手动卸载 | — | 数据全丢 |

### 6.2 安装瞬间 UI 会消失，这是正常的

覆盖安装时系统**杀掉正在运行的这个进程**（它就是要被替换的应用）。流程：

```
构建成功 → 提交安装 → 系统替换 → 进程被杀（UI 消失！）
  → MY_PACKAGE_REPLACED 广播（已注册于 A11yKeeper / PrivilegedKeepJob）
  → 新代码启动，数据仍在
```

**自举第一次跑时别把"UI 消失"误判为崩溃。** 验证方式是重新看进程/日志，不是看屏幕。

### 6.3 versionCode 规则

`(year-2026)*1e8 + MMDDhhmm`（UTC+8），分钟级单调，2046 年前有效。
同一分钟连续构建得到相同 versionCode（仍可覆盖安装，但无法区分产物）。
时钟回拨是唯一真实风险 → 构建前应校验「本次 versionCode > 已安装 versionCode」。

### 6.4 失败与兜底（待决策）

| 场景 | 能否自救 |
|---|---|
| 构建失败 / 装不上 | ✅ 不安装、预检拦截 |
| **装上但启动即崩** | ❌ 单包架构下无解（构建与安装能力同死） |
| runtime 损坏 | 🟡 主包内可修 |

候选方案（尚未定）：**L0 独立安装器包**（~2MB，只做"扫描 /sdcard 的 APK + 校验签名 + 安装"，不含工具链）
+ last-good.apk + boot-ok 探针自动回滚。详见 `fix/SELFHOST.md`。

## 7. 待办与待决策

| # | 事项 | 状态 |
|---|---|---|
| 1 | L0 独立安装器包是否做 | **待用户决策** |
| 2 | 自举 M0：`fix/08-self-build.sh`（构建→校验→产出 self-update.apk） | 未开始 |
| 3 | 自举 M1：服务中台注册 `build-self`（一键触发 + 唤醒锁） | 未开始 |
| 4 | 工具链归档（`/opt`+`~/.gradle` ≈17.5G，压缩后 4~5G） | 未开始 |
| 5 | keystore 异地加密备份 | **建议优先**（单点风险） |
| 6 | 把 proot pin 修复提给上游（`runtime/build-runtime.sh`） | 未开始 |

## 8. 用户偏好与红线

- **中文、简短**（手机屏幕小）
- **先评估再动手**：用户说"开始构建"才构建，不擅自跑长任务
- **破坏性操作先问**（删除、卸载、覆盖安装）
- 结论必须用**真实命令/日志**验证，不凭印象
- keystore 与 `keyinfo.yaml` 密码**不得外传**
- 每次 Gradle 构建保留 `android.builder.sdkDownload=false`，缺 SDK 从腾讯镜像显式安装

## 9. 常用命令

```bash
# 构建 release（box64，AOT，18 分钟）
cd /root/DSH-Loop && bash fix/04-build-apk-arm64.sh --release

# 构建 debug（JIT，8 分钟，独立包名 com.lizow.dsh.debug）
bash fix/04-build-apk-arm64.sh --debug

# 强制全量重建（清 build/ 与 .dart_tool/）
FULL=1 bash fix/04-build-apk-arm64.sh --release

# 覆盖安装（数据保留）
adb connect <手机IP>:<端口>
adb install -r /sdcard/Download/DSH-Loop/app-arm64-release.apk

# 启动验证
adb shell am start -n com.lizow.dsh/io.github.ccch1mneyyy.dsh_app.MainActivity
adb logcat -d | grep -aE "CreateRootIsolate|Snapshot not compatible|Impeller"

# 校验 APK
bash fix/99-verify-apk.sh <apk>

# 自建 runtime
cd <工程> && bash runtime/build-runtime.sh arm64-v8a
```

## 10. 验收清单（2026-11-15 实测全通过）

- [x] `fix/00-check-env.sh` 全绿（含 box64 与 AOT 包装）
- [x] `runtime/build-runtime.sh arm64-v8a` 从零产出 runtime（153MB，ELF 0 错）
- [x] `fix/04 --release` 出 278.5MB APK（971s 全量）
- [x] APK 含 `AndroidManifest.xml` + `resources.arsc` + `lib/arm64-v8a/libapp.so`（55MB）
- [x] APK 内 runtime 版本 = 自建版本（`…-466f817b89d6`，proot 5.1.107.102）
- [x] 签名指纹与已装机一致（`4db3353…`）
- [x] 覆盖安装成功，数据保留
- [x] 启动无 `Snapshot not compatible`，Impeller 正常
- [x] 首次启动自动解压新 runtime，引擎连上 workspace，可对话
- [x] 全程未使用旧环境的二进制产物（只复用 keystore）
- [x] debug 包独立：`com.lizow.dsh.debug` / 桌面名「DSH Go 调试」/ `1.0.16-debug`
- [x] release 与 debug 双包共存，互不覆盖
- [x] 增量同步（rsync）保留 `build/` 与 `.dart_tool/`：无改动重建 238s

## 11. 参考资料

- `fix/README.md` —— 适配原理、9 个章节的踩坑记录、回滚方式
- `fix/SELFHOST.md` —— 自举架构设计、失败矩阵、恢复路径、里程碑
- 本文档 —— 接手者入口
- `SPEC.md` —— 协作规范、硬约束、验证门、红线（用户整理）
