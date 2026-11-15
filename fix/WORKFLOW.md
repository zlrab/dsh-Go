# dsh-Go 自举更新流程

> 2026-11-15 与用户确认。分工：**用户负责真机体验与发版决策，AI 负责构建/安装/adb 监控/日志核对**。

## 一、角色与原则

| 角色 | 职责 |
|---|---|
| 用户 | 真机体验新功能、提问题、**下发发版指令** |
| AI | 改代码后的构建、adb 安装、日志/性能监控、产出核对数据 |

原则：**不确认不发布**。debug 阶段随便装；release 覆盖安装必须先拿到用户明确同意（会杀掉当前 App 进程=本会话中断）。

## 二、标准循环

### 1) debug 阶段（新功能验证）

```bash
# 构建（约 7~8 分钟，产出 ~301MB）
cd /root/build/dsh-Go
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64 FLUTTER_ROOT=/opt/flutter \
       ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk \
       PATH=/opt/flutter/bin:/opt/gradle-9.3.1/bin:/opt/android-sdk/platform-tools:/usr/local/bin:$PATH
bash fix/04-build-apk-arm64.sh --debug

# 安装（独立包名 com.lizow.dsh.debug，不动 release，不中断会话）
adb install -r /sdcard/Download/DSH-Go/app-arm64-debug.apk
```

用户打开桌面「DSH Go 调试」体验；AI 侧监控：

```bash
adb logcat -c && adb logcat | grep -aE "Snapshot not compatible|CreateRootIsolate|FATAL|AndroidRuntime|flutter"
adb exec-out screencap -p > /sdcard/Download/DSH-Go/shot-$(date +%H%M%S).png
adb shell 'dumpsys package com.lizow.dsh.debug | grep -E "versionCode|versionName"'
adb shell 'pidof com.lizow.dsh.debug'
```

### 2) release 阶段（用户确认后才做）

```bash
# 增量约 3 分钟；全量（FULL=1）约 18 分钟（AOT 占大头）
cd /root/build/dsh-Go && bash fix/04-build-apk-arm64.sh --release
bash fix/99-verify-apk.sh /sdcard/Download/DSH-Go/app-arm64-release.apk
```

发版安装前检查三项：同包名 `com.lizow.dsh`、签名 `4db3353…`、versionCode 大于已装版本。
确认后 `adb install -r`（**必须先问用户**）。

## 三、adb 连接（无线调试）

```bash
# 设置 → 开发者选项 → 无线调试，取「IP 地址和端口」
adb pair 192.168.31.141:<配对端口> <六位配对码>   # 密钥失效时才需要
adb connect 192.168.31.141:<连接端口>
adb devices
```

注意：**关掉无线调试后连接端口会变**，每次都要重新取。若想固定，可用 `adb tcpip 5555`（会切到旧式 TCP 调试，需用户同意）。

## 四、已知约束（踩过的坑）

1. **后台冻结**：App 进后台会被 Android 冻结，整个 proot 进程树停止调度 → 服务不可用、AI 无法实时监控。
   缓解：开发者选项「暂停执行已缓存的应用」→ 已停用；DSH Go 省电策略 → 无限制；最近任务加锁。
   判断方法：后台跑心跳日志（每 2s 一行），出现断档即为冻结。
2. **release 构建依赖缓存**：`/root/build/dsh-Go` 的 `build/`、`.dart_tool/`、`~/.gradle`、`~/.pub-cache` 不要删，
   删了下次 release 从 ~3 分钟回到 ~18 分钟（AOT 无增量）。
3. **NDK 包装**：用 `/root/fix-ndk-abi-corrected.sh`；原 `fix/03` 会穿透 NDK 的符号链接，写坏 clang/llvm-ar。
4. **aapt2**：AGP 从 Maven 下的 aapt2 是 x86_64，经 `/opt/aapt2-maven/aapt2` 包装，
   由 `~/.gradle/gradle.properties` 的 `android.aapt2FromMavenOverride` 指定；**不要改写 Gradle transform 缓存**（会触发「不可变工作区被修改」）。
5. **博客/服务**：`bash /root/workspace/services/hub.sh {status|start|stop} [id]`；重启博客用 `bash /root/restart-blog.sh`
   （命令行里别直接写服务进程名，hub 的 pkill 会误杀）。

## 五、构建耗时参考（本机实测）

| 场景 | 耗时 |
|---|---|
| debug 构建 | 7m29s（301MB） |
| release 增量重建 | ~3m（227MB） |
| release 全量（含 AOT） | ~18~24m |
| runtime 从零构建 | 8m19s（153MB） |

## 六、待办（按优先级）

| # | 事项 | 状态 |
|---|---|---|
| 1 | release 包覆盖安装（227MB，versionCode 11151401） | 等用户下发发版指令 |
| 2 | 旧包 `io.github.ccch1mneyyy.dsh_app` 是否卸载 | **已定：等自举迭代稳定后再处理** |
| 3 | adb 端口固定（`adb tcpip 5555`） | 待用户决定 |
| 4 | SSH 服务（:2222）缺 authorized_keys | 待用户提供公钥 |

## 七、已确认结论（2026-11-15）

- debug 包实测正常：Impeller Vulkan、无 `Snapshot not compatible`、无崩溃、对话可用（pid 27118，1.0.16-debug）
- 后台冻结问题已解决：心跳间隔稳定 2s、最大 3s（此前断档 60s），**实时 adb 监控可用**
- 现有三个包并存：`io.github.ccch1mneyyy.dsh_app`（原版，旧）、`com.lizow.dsh`（release 1.0.16）、`com.lizow.dsh.debug`（1.0.16-debug）
