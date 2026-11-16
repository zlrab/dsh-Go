# 项目规范（DSH Loop / dsh-Go fork）

> 2026-11-16 整理落库，来自用户口述的原会话版本。**本文件与用户当次指令冲突时，以用户当次指令为准。**
> 快速上手看 `HANDOVER.md`；fork 分支/同步细节看 `fix/FORK.md`。

## 1. 项目坐标

| 项 | 值 |
|---|---|
| 仓库 | `/root/DSH-Loop`（App 工作区「DSH-Loop」），**源码目录 = 构建目录** |
| 分支 | `main-phone` 产线；`main` 只做上游镜像（只许 fast-forward） |
| 远端 | `git@github.com:zlrab/dsh-Go.git`（SSH，走 443 端口） |
| 产物 | `/sdcard/Download/DSH-Loop/*.apk` |
| 签名密钥 | `/sdcard/DshWorkSpace/AndroidProjects/keyStores/lizow.keystore`（绝不能动） |
| App 包 | 正式 `com.lizow.dsh`；调试 `com.lizow.dsh.debug`（共存，各用各的数据） |
| 会话宿主 | 当前这个 AI 会话跑在**正式包**里（2026-11-16 实测） |

## 2. 回答风格

- 中文、短句、为手机屏写；代码块别太宽
- 先结论后数据；结论只来自真实命令输出，贴关键行和 exit code
- 失败贴原始报错，不转述、不美化、不用「应该是」
- 比较用表格；必要时上 dsh-ui 视图，一条回复最多两个

## 3. 执行纪律

- 长任务先声明再跑（做什么 + 预计多久）
- 破坏性操作先列绝对路径 + 体积，等确认；删完报释放量
- 一条路走不通：贴错误 + 给 2–3 个选项让用户拍板，不静默改路线
- 一次只改一个变量，改完立刻重跑验证

## 4. 项目硬约束

- runtime 必须 `bash runtime/build-runtime.sh arm64-v8a` 自建；**禁止从官方 APK 提取**
- 包名 `com.lizow.dsh`（debug 加 `.debug`），versionCode 递增，签名 alias `lizow`
- 覆盖安装：`adb install -r`，或用文件管理器点开 `Download/DSH-Loop/` 里的 APK（应用内安装已移除）；数据保留、App 重启
  - 装 **debug 不打断当前会话**（会话在正式包，2026-11-16 实测）；装正式包才会断 → **先问再装**
- `/sdcard` 是 FUSE（noexec / 慢 / 被相册扫描）→ 仓库和构建都不放那儿

## 5. Git 规则（硬性）

- **严禁改写历史**：不 `rebase` / `amend` / `filter-branch` / `force push`；撤销一律 `git revert`
- 方向只有 `main → main-phone`；提交前缀 `fork:`，只 `git add` 明确路径
- **未经明确要求不 commit、不 push**

## 6. 验证门（缺一步不算完）

```
改代码 → flutter analyze → debug 构建 → adb 装机 / 文件管理器安装 → 用户真机确认
      → release 构建 → fix/99-verify-apk.sh → 问用户 → 覆盖安装
```

- 改文案：`app/lib/l10n/parts/*.arb` 中英同步 → 必跑 `python3 app/tool/l10n_merge.py`
- 改图标：只改 `fix/11-make-app-icon.py`（单一来源）
- 真机相关改动必须真机验证

**现状备注（2026-11-16）**：`flutter analyze` 目前是红的——`app/test/forum`、`app/test/star` 等旧测试仍引用已删功能。
用户已明确 **不改测试用例、只在真机验证**，所以这一门暂以「构建 + 装机 + 真机确认」为准。

## 7. 明确不要做

- `content delete` 清相册（会连文件一起删）
- `pkill -f`（会杀掉自己）
- 改 Gradle transform 缓存
- 在 `/sdcard` 建仓库
- 手改生成物后忘了跑生成器（l10n、品牌图标、guide）
- 未经同意改写 git 历史 / 强推
