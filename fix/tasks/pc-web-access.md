# 任务：电脑端访问手机引擎（Web 访问）

> 2026-11-15 评估，待实施。目标：在电脑浏览器里操作手机上的 DSH 环境（同一引擎、同一工作区、同一会话）。

## 现状（实测）

| 项 | 事实 | 出处 |
|---|---|---|
| 引擎监听 | `dsh web --host 127.0.0.1 --port 3080 --no-open` | 进程参数 |
| 硬校验 | 非 loopback 直接拒绝：`require(... == "127.0.0.1") { "direct engine: loopback host required" }` | `runtime/DirectLaunch.kt:201` |
| 鉴权 | Web UI 需要 `?token=…`；token 每次启动新生成，由引擎 stdout 打印，App 解析后交给内嵌 WebView | `runtime/DshProcess.kt:412,415` |
| token 可见性 | **没有落盘、没有对外 API**，诊断日志里也打码；Dart 侧拿不到 | `diagnostics/redact.dart`、`state/engine_control.dart` |
| 已有能力 | 「网页模式」= App 内嵌 WebView，不对局域网提供 | `state/ui_mode_state.dart` |
| 设置项 | 没有「局域网/电脑访问」 | — |

**结论**：纯外部手段（`adb forward`、SSH 隧道）能打通网络，但都拿不到 token，所以**必须做一次 fork 改动**。

## 方案

### 方案 1：最小可用（推荐先做，1~2 小时）

改动：

1. `runtime/DirectLaunch.kt` —— 放宽 host 校验，允许 `0.0.0.0`
2. `runtime/DshProcess.kt` —— 启动模板 host 改为 `0.0.0.0`；新增一次 method channel 调用，返回 `{token, port, lanIp}`
3. `ui/settings/` —— 「引擎」小节加一行「电脑访问」：显示 `http://<手机IP>:<port>/?token=…`，可复制
4. 取本机局域网 IP：优先 `NetworkInterface` 里的私网地址（避免 127/0.0.0.0）

验收：电脑浏览器打开该链接 → 看到同一会话与工作区。

### 方案 2：体验最好（3~4 小时，方案 1 可用后再做）

- 设置开关（默认关闭），开启时才绑 `0.0.0.0`
- 二维码（PC 扫码直达）
- 可选固定 token（默认每次随机，安全）

### 方案 3：纯隧道（不暴露局域网）

- 仍需先实现方案 1 第 2 步的「token 可见」
- PC 端 `ssh -L 3080:127.0.0.1:3080 -p 2222 root@<手机IP>`，或 `adb forward tcp:3080 tcp:3080`
- 优点：加密、不暴露；缺点：PC 每次要连 adb/ssh

## 冲突成本

待改文件在近 157 个上游提交里改动数**均为 0**：

```
runtime/DirectLaunch.kt   0
runtime/DshProcess.kt     0
ui/settings/settings_screen.dart   0
```

## 风险

1. 监听 `0.0.0.0` 后，同网设备拿到 token 即可操作整个容器（等同 root 终端）→ 只在可信 Wi-Fi 用
2. token 每次启动变化，链接会变；固定 token 需额外设计
3. 端口固定 3080；若路由器把该端口映射到公网请立即关闭
4. 引擎 stdout 是 token 的唯一来源，改动时别破坏 App 解析（`TOKEN_PARAM` 正则）

## 建议

先做方案 1 验证链路，常用再补方案 2；敏感网络环境用方案 3。
