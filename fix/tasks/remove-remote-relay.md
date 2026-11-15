# 任务：删除 DSH Remote 中继（P2P），保留 SSH 远程主机

> 2026-11-15 评估。目标：去掉依赖官方中继服务 `dsh.r2049.cn` 的「扫码/账号配对」通道，保留「连电脑或服务器上的 DSH（SSH）」这条本地可用路径。

## 为什么要拆开

`app/lib/remote/` 里混着两套东西：

| 子目录/文件 | 属于 | 依赖 | 处理 |
|---|---|---|---|
| `remote/relay/{dsh_remote_backend,network_route,relay_backend,webrtc_peer}.dart` | DSH Remote P2P | `dsh.r2049.cn`（官方中继） | 删 |
| `remote/ssh/*`（local_forward / remote_bootstrap / remote_shell / ssh_host_config / ssh_link / ssh_transport） | SSH 远程主机 | 你自己的机器 | **保留** |
| `remote/link_status.dart`、`remote/network_watch.dart`、`remote/secret_store.dart` | 两者共用 | — | 保留（先确认没有 relay 专属用法） |
| `ui/remote/pairing_page.dart`、`relay_login_sheet.dart`、`relay_credit.dart` | 中继专属 UI | — | 删 |
| `ui/remote/{host_switcher,host_status,link_progress,network_details_sheet,host_key_dialog}.dart` | SSH 主机 UI | — | 保留 |
| `state/remote_pairing_state.dart` | 中继配对 | — | 删 |
| `state/hosts_state.dart`、`state/connection_state.dart`、`state/workshop_account_state.dart` | 主机管理 / 连接 / 工坊账号 | 会引用中继 | 逐个摘除中继分支 |

## 验收

1. 「连接电脑或服务器」仍可用（SSH），能切换本地/远程主机
2. 不再出现扫码配对、Relay 账号登录、中继额度（credit）界面
3. 构建 + 真机：添加一台 SSH 主机 → 切换 → 对话

## 风险

- `hosts_state.dart` 是主机管理核心（本地 + 远程都走它），改动要最小：只摘掉 relay 分支
- `workshop_account_state.dart` 里的中继登录可能用于工坊鉴权 → 需确认工坊是否还能匿名使用（`DSH_WORKSHOP_ORIGIN`）
- 反查：`grep -rn 'relay\|Relay' app/lib --include=*.dart`
- 上游 churn：`remote` 目录近 157 提交只改了 1 个文件，删除冲突成本低
