# 任务：删除分享托管（share_hosted）

> 2026-11-15 评估。目标：去掉「对话分享到 go.dshtui.com 托管链接」这条链，保留本地 `.dshgo` 文件分享与 GitHub gist 分享。

## 为什么单独列任务

`share_hosted` 不是自包含模块，它横跨 9 个文件、2 个目录，并且和**要保留的插件市场**共用同一个域名常量。

## 涉及文件

| 位置 | 作用 | 处理 |
|---|---|---|
| `lib/share_hosted/{hosted_client,hosted_crypto,hosted_link,hosted_links_state}.dart` | 托管链接的客户端/加密/解析/状态 | 删 |
| `lib/share_hosted/hosted_config.dart` | `shareHostOrigin` 常量 | **保留**（插件市场的 `marketPluginLink` 也在用） |
| `lib/ui/share_hosted/`（hosted_link_host / hosted_link_maker / manage_links_button / hosted_links_page / hosted_links_tile） | 托管链接的 UI 与深链 | 删 |
| `lib/links/app_links.dart` | `registerHostedLinks(_router)` + `_offHosted` | 删这两处 |
| `lib/links/share_intake.dart` | `hostedLink` getter（分享进来时识别托管链接） | 删 getter + import |
| `lib/share_code/share_link.dart` | 落地页常量（用 `shareHostOrigin`） | 保留常量即可 |
| `lib/ui/replay/conversation_out.dart` | 分享面板里的「托管链接」区块与 `ManageLinksButton` 导出 | 删区块 |
| `lib/ui/settings/index/settings_pages.dart` | `SettingsPageId.sharedLinks → HostedLinksPage()` | 删该分支与 import |
| `lib/ui/settings/privacy_page.dart` | `HostedLinksSettingsTile` | 删该 tile 与 import |

## 验收

1. 分享面板仍能导出 `.dshgo` 文件；不出现「上传/管理链接」入口
2. 设置里不再有「分享链接管理」页，隐私页无对应开关
3. 插件市场详情页仍能打开（依赖 `shareHostOrigin` 常量）
4. 构建 + 真机：分享本地文件、打开插件市场

## 风险

- `conversation_out.dart` 是分享主界面，改动要小心：只删托管区块，别动 `.dshgo` 导出
- 旧托管链接（`dshgo://go.dshtui.com/c/…`）将无法在 App 内打开 → 深链会落到浏览器
- 反查：`grep -rn 'hosted' app/lib --include=*.dart`
