# dsh-Go 自举设计（在手机内改代码 → 构建 → 覆盖自身）

> 状态：设计稿（2026-11-15）。目标不是"能在手机上构建"，而是**闭环**：
> 改完源码后，不借助任何 PC / CI，直接在手机里出签名 APK 并覆盖安装自身，数据不丢。

## 0. 成功判据

| # | 判据 | 当前 |
|---|---|---|
| A | 手机内 10 分钟内产出可安装的 release APK | ✅ 实测 6m32s（box64） |
| B | 产物与当前安装包**同包名同签名**，`versionCode` 递增 | ✅ 已有 `key.properties` + 构建分钟号 |
| C | 一键触发构建（不用手动敲命令） | ❌ 待做 |
| D | 构建成功后一键覆盖安装并重启到新版本 | 🟡 通道已有（installer / Shizuku），缺入口 |
| E | 新版本启动崩溃时，仍能恢复（不依赖 PC） | ❌ 待做（本设计的关键部分） |
| F | 工具链可在 App 数据被清空后重建 | 🟡 有归档脚本，缺策略 |

## 1. 现状盘点（都已核实，不是设想）

| 能力 | 位置 | 说明 |
|---|---|---|
| 签名配置 | `app/android/key.properties` | `storeFile → keyStores/lizow.keystore`，alias `lizow`；在源码工程里（`gitignore`），构建脚本每次按绝对路径重写 |
| 版本号 | `app/android/app/build.gradle.kts` `buildMinuteVersionCode()` | `(year-2026)*1e8 + MMDDhhmm`（UTC+8），**按分钟单调递增**，与 `tooling/build_number.py` 同编码 |
| 普通安装 | **fork 已移除** | 应用内安装链路删光，安装走系统安装器 / `adb install` |
| 安装前校验 | **fork 已移除** | 原 `ApkInspection` 随更新链路删除 |
| 签名比对实现 | **fork 已移除** | `ApkInstaller.kt` 现在只提供 `info()`（版本/ABI/剩余空间） |
| 静默安装 | **fork 已移除** | 不再提供 Shizuku 安装通道 |
| 增量更新 | `app/lib/update/delta.dart`（保留未接入） | 上游代码留着减小合并冲突，自举用不到 |
| 构建脚本 | `fix/04-build-apk-arm64.sh` | 默认 box64；`fix/06`/`07` 装模拟层与包装 |
| 构建性能 | 本机实测 | 全量 release 392s；AOT 686s（与 3 个 qemu 抢 CPU 时测） |
| 产物一致性 | 本机实测 | box64 与 qemu 产出的 `libapp.so` **逐字节相同**（58,012,344 B） |

## 2. 架构：三层 + 两阶段

```
┌─ 引导层 stage0 ──────────────────────────┐
│ /sdcard/DSH-Loop/toolchain.tar.zst         │  Flutter SDK + Android SDK/NDK + gradle 缓存
│ 恢复脚本：解包 → 校验版本 → 可用         │  目标：清空 App 数据后 10 分钟内重建
└──────────────────────────────────────────┘
┌─ 构建层 ─────────────────────────────────┐
│ 仓库 /root/DSH-Loop                      │  ← 用户改代码的地方（源码=构建目录）
│ 远端 github.com/zlrab/dsh-Go             │  ← SSH 推送备份
│ AOT: box64 跑官方 x64 gen_snapshot       │
│ 产出：app-arm64-release.apk（自有签名）  │
└──────────────────────────────────────────┘
┌─ 安装层 ─────────────────────────────────┐
│ 预检 → 普通安装（系统确认框）            │
│     └→ 或 Shizuku 静默安装               │
└──────────────────────────────────────────┘
```

### 阶段 1：单包自构建（M0–M2）
主 App 自己既是编辑器宿主也是构建器。够用，但**变砖无解**（见 §4）。

### 阶段 2：双包（M3，推荐终态）
```
com.lizow.dsh          ← 主 App，可以随便坏
com.lizow.dsh.builder  ← 引导器：同步源码 → 构建 → 安装主 App
```
- 同一 keystore 签名（key.properties 共享）
- 共享 `/sdcard` 工作区，无需互相通信
- 主 App 启动即崩时，打开 builder 重装 —— **这是自举的 stage0 本体**

## 3. 数据流（阶段 1 时序）

```
用户点「构建并更新」
  → 前台服务启动（startForeground + PARTIAL_WAKE_LOCK，防 6 分钟被杀）
  → fix/08-self-build.sh
      1. 校验工作区干净（源码目录即构建目录，无需同步）
      2. 检查 key.properties / runtime 资产 / 磁盘余量（≥ 6GB）
      3. flutter build apk --release --flavor arm64 --target-platform android-arm64
      4. 校验产物：包名 == com.lizow.dsh、签名指纹匹配、versionCode > 已安装
      5. 复制到 /sdcard/DSH-Loop/self-update.apk，保留上一版为 last-good.apk
  → App 收到路径 → ApkInspection → installer.install(path) 或 Shizuku 静默
  → 系统替换 → 冷启动新版本
```

## 4. 失败模式与兜底（本设计的核心）

| 失败 | 症状 | 检测点 | 兜底 |
|---|---|---|---|
| 构建失败 | 编译错 / OOM / 磁盘满 | 脚本退出码 + 日志 | 不安装，保留旧版本（天然安全） |
| 产物不合格 | 包名/签名/版本号不对 | `ApkInspection`（已实现） | 拒绝安装 |
| 装不上 | versionCode 未递增、签名不一致 | 系统返回 `INSTALL_FAILED_*` | 提示原因；versionCode 由分钟号保证单调 |
| **装上但启动即崩** | 黑屏/闪退 | 无自动检测 | **关键路径**，见下 |
| 工具链损坏 | 构建报找不到 SDK | 构建前自检 | 从 stage0 归档恢复 |
| 断电/杀进程 | 构建中断 | 前台服务 + 断点标记 | 重跑（构建幂等） |

### 4.1 「装上但崩溃」的三条恢复路径（按可靠性）

1. **独立 builder 包**（最强，M3）
   与主 App 同签名、独立进程。主 App 崩了也能打开它重装 last-good.apk。
2. **Shizuku + 外部触发**
   Shizuku 可完全在手机内通过「无线调试」启动（不需要 PC）。配合一个最小壳（builder 或 Termux）执行 `pm install -r`。
3. **last-good.apk 手工回装**
   每次成功构建后把旧包留一份；崩溃时用系统文件管理器点开安装。

> **不可依赖的兜底**：Android 没有"应用级自动回滚"，也不保证能进 recovery。所以
> 「先构建成功、再保留旧包、最后才安装」的顺序不能颠倒。

## 5. 关键机制细节

### 5.1 版本号
- 编码：`(year-2026)*1e8 + MMDDhhmm`（UTC+8），上限 2,100,000,000 → **2046 年前有效**
- 分钟级单调：同一分钟内连续构建会得到**相同** versionCode。Android 允许同版本覆盖安装，所以不会失败，但两次产物无法从版本号区分
- **真正的风险是时钟回拨**：若设备时间被调早，新构建的 versionCode 会小于已安装版本 → `INSTALL_FAILED_VERSION_DOWNGRADE`。自举脚本应在构建前比对「已安装 versionCode < 本次将生成的 versionCode」，不满足就中止

### 5.2 签名链
- 唯一 keystore：`/sdcard/DshWorkSpace/AndroidProjects/keyStores/lizow.keystore`
- **单点风险**：丢了就永久无法覆盖安装 → 必须有异地加密备份（待办）
- 校验：`ApkInspection.signatureMatches`（实现见 `ApkInstaller.kt:signersMatch`）

### 5.3 构建编排
- 前台服务 + `PARTIAL_WAKE_LOCK`（6.5 分钟量级，息屏会拖慢甚至被杀）
- 进度回显：解析 `flutter build` 输出阶段（resolving → AOT → packaging）
- 资源门槛：构建期内存峰值实测约 8GB（15GB 机器）；磁盘需 ≥ 6GB（`build/` 会涨到 ~2.8GB，加产物 278MB）
- 并发锁：工程根 `.build.lock`（M1 设计，未实现），防止两个构建互相踩

### 5.4 安装通道选择
| 通道 | 条件 | 体验 |
|---|---|---|
| PackageInstaller | `REQUEST_INSTALL_PACKAGES`（已有） | 系统弹确认框，点一下 |
| Shizuku 静默 | 用户已授权 Shizuku 且服务在跑 | 无弹窗，自动重启 |

策略：默认普通通道；检测到 Shizuku 可用时提示可切静默。

### 5.5 工具链持久化（stage0）
- `/opt/flutter`（2.5GB）、`/opt/android-sdk`、`/root/.gradle` 都在 **App 私有数据**里，卸载即丢
- 归档到 `/sdcard/DSH-Loop/toolchain-<ver>.tar.zst`，含版本清单
- 恢复时间目标：解包 + 校验 ≤ 10 分钟（不需要重新下载）

## 6. 里程碑

| 阶段 | 内容 | 工作量 | 交付 |
|---|---|---|---|
| M0 | `fix/08-self-build.sh`：构建 + 校验 + 产出 self-update.apk | 1h | 脚本 |
| M1 | 服务中台注册 `build-self`（一键触发 + 日志 + 唤醒锁） | 半天 | 可点按钮 |
| M2 | 预检 + last-good 保留 + 工具链归档脚本 | 半天 | 安全网 |
| M3 | 独立 builder 包（同步/构建/安装/救砖） | 1–2 天 | 真自举 |

## 7. 未决问题

1. **builder 包如何拿 keystore**？同 keystore 文件在 /sdcard，两个包都能读 → 可行，但等于明文密钥扩大暴露面。是否改为"builder 只打包不签名，签名由主 App 完成"？
2. **崩溃自动检测**：能否用「启动后 N 秒内写探针文件」+ builder 检查探针缺失来自动回滚？
3. ~~**源码同步方向**~~：已解决——仓库在 `/root/DSH-Loop`，源码目录即构建目录，无同步。
4. **AOT 缓存**：改一行 Dart 也要全量 AOT（6 分钟）。能否用 `--track-widget-creation=false` + 增量 kernel 缩短到 2–3 分钟？
5. **是否保留 delta 更新**：自举产物在本地，delta 只剩"从 last-good 到新版本"的差量意义，收益低。

## 8. 附：本机实测数据（2026-11-15）

| 项 | 值 |
|---|---|
| box64 全量 release 构建 | 392s |
| qemu 全量 release 构建 | 2377s |
| AOT 单独（box64，含 CPU 争抢） | 686s |
| 产物 `libapp.so` | 58,012,344 B（box64 与 qemu 逐字节一致） |
| APK | 278.5MB（含 153MB 运行时资产） |
| 装机后启动 | 首帧 1.45s，无 snapshot 报错 |
