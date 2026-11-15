# fork 分支与上游同步

> 2026-11-15 与用户确认。上游：`github.com/ccch1mneyyy/dsh-go`；fork：`github.com/zlrab/dsh-Go`。

## 一、分支模型

| 分支 | 内容 | 规则 |
|---|---|---|
| `main` | 上游镜像 | **禁止任何本地提交**，只做快进（GitHub「Sync fork」按钮或 `git merge --ff-only`） |
| `main-phone` | 产线：`main` + 所有 `fork:` 提交 | 真正用来构建、发版的分支；工作区平时停在这里 |
| `sync/YYYYMMDD` | 每次同步的试验分支（可选） | 冲突多时先在这里解，验证通过再并入 `main-phone` |

合并方向**永远**是 `main → main-phone`。一旦 main 上出现本地提交，GitHub 的「Sync fork」就不能快进了。

## 二、同步流程

```bash
# 1) 用户在 GitHub 上：仓库页 → Sync fork → Update branch（main 快进到上游）

# 2) 本地拉 main（只允许快进）
cd /sdcard/DshWorkSpace/AndroidProjects/dsh-Go
git fetch origin
git checkout main && git merge --ff-only origin/main

# 3) 并入产线分支
git checkout main-phone && git merge main

# 4) 逐项对比：本地改动 vs 上游实现 → 给出结论与建议 → 由用户决定是否改用上游
#    （见下方「本地改动登记」表；每项都要在此表留下结论）

# 5) 验证门：debug 构建（7~8 分钟）→ adb 装机 → 用户真机测
#    → 用户确认后 release 构建 + fix/99-verify-apk.sh
```

只想要个别上游修复时用精选：`git cherry-pick -x <sha>`（用 `git log main-phone..main -- <文件>` 挑）。

## 三、本地改动登记（每次同步后更新）

| # | 改动 | 涉及文件 | 性质 | 上游是否已实现 | 结论 |
|---|---|---|---|---|---|
| 1 | `applicationId=com.lizow.dsh`、lint/资源压缩/R8/符号抽取关闭、debug 变体后缀 | `app/android/app/build.gradle.kts`、`gradle.properties` | fork 专有 | 否 | 保留 |
| 2 | 应用名资源化：`@string/app_name` = DSH Go，debug 覆盖为「DSH Go 调试」 | `AndroidManifest.xml`、`res/values/strings.xml`、`src/debug/res/values/strings.xml` | fork 专有 | 否 | 保留 |
| 3 | proot pin：`5.1.107.98 → 5.1.107.102`（HANDOVER 5.2① 的手工修补，**未更新 sha256 pin**） | `runtime/build-runtime.sh` | 临时修补 | **是**：上游 `bf22ae01`（2026-11-15）改版本号 + 3 个 sha256 pin，比我们完整 | **保留提交**（用户 2026-11-15 决定）：合并后本地版相对 main 的 diff = 0 行，无副作用；上游已完整覆盖 |
| 4 | 移除应用内更新链路（包名/签名已改，原更新链路装不上） | `app/lib/update/**`、`state/update_state.dart`、`ui/update/**`、`android/**/update/**`、l10n、测试、tooling、docs | fork 专有 | 上游仍在维护 | 待实施（见评估：净删约 13k 行，需先抽共享设施） |
| 5 | `fix/` 自举交付脚本与文档（本文件、WORKFLOW.md、SELFHOST.md、00~99 脚本） | `fix/**` | 本地交付 | — | 保留 |

> 判定口径：**上游已完整实现且覆盖更全** → 建议弃用本地版；**上游实现不同或只解决一半** → 逐项对比后由用户拍板；**fork 专有**（包名/签名/自举）→ 永久保留。

## 四、约定

- 本地改动一笔一提交，统一 `fork:` 前缀（`fork: build config`、`fork: runtime pin`、`fork: remove updater`、`fork: selfhost`），便于 cherry-pick 与逐项对比。
- `git config rerere.enabled true` 已开启：同一冲突解法第二次自动复用。
- 构建只在 `/root/build/dsh-Go` 副本做（`/sdcard` 是 FUSE，无执行位）；源码仍在 `/sdcard` 的 git 仓库里。
- 合并后必须重跑：`fix/00-check-env.sh` → debug 构建 → 真机验证；release 前 `fix/99-verify-apk.sh`。
- `.git` 约 640MB 在 /sdcard 上，避免频繁 `git gc`。

## 五、同步记录

| 日期 | 上游提交数 | 冲突 | 结果 |
|---|---|---|---|
| 2026-11-15 | 157（`719fed04 → 31f6d874`） | **0** | 版本随上游升到 **1.1.0**；`onnxruntime` 1.23.2→1.27.0（修 Snapdragon 8 Elite + Android 16 崩溃）；debug 构建 8m57s、装机首帧 3.85s、无崩溃无 ANR、资源版本自动刷新（11151608→11151751） |

### 移除更新链路时**故意保留**的文件（零冲突策略）

上游会持续改这些文件，我们不编辑它们，冲突面才最小：

| 文件 | 为什么留 |
|---|---|
| `update/update_http.dart` | workshop、community 的 HTTP 客户端 |
| `update/version.dart`（AppVersion） | market 的 `minApp` 门控、插件版本比较 |
| `update/update_config.dart` | `updateRepo`（社区/分享的 GitHub 链接）、`DownloadUrl`（workshop） |
| `update/downloader.dart` | workshop 复用 `CancelToken`/`DownloadProgress` |
| `update/installer.dart` | workshop 查 `freeBytes`；`dsh/update` 通道仍提供 `info` |
| `app/lib/l10n/parts/*update*.arb` | 上游 157 提交里 0 次改动；保留未使用文案，避免动 l10n 与指南校验 |
| `tooling/{apk_delta,release_assets}.py`、`services/share-worker/scripts/*` | 服务端发版流水线，与 App 无关；内部测试互相引用，删了只会制造冲突 |

## 六、改文案必看：l10n 是「parts → 合并 → gen」三段

改 `app/lib/l10n/parts/*_{zh,en}.arb` **不会立刻生效**，必须重跑合并：

```bash
cd app && python3 tool/l10n_merge.py     # 生成 app_{zh,en}.arb 并跑 flutter gen-l10n
```

`lib/l10n/app_*.arb` 与 `lib/l10n/gen/` 都是生成物（`l10n.yaml` 顶部写明不要手改）。
漏跑合并的典型症状：改了 parts 里的 `appSlogan`，装机后界面仍是旧文案。

## 七、git 历史规则（硬性，2026-11-15 用户明确要求）

**严禁改写 git 历史。** 仅 2026-11-15 一次用户明确授权的例外（删掉「本地安装包更新」加功能 + revert 两笔），此后不再有例外。

| 禁止 | 说明 |
|---|---|
| `git rebase`（含 `-i`、`--onto`） | 会重写提交 |
| `git commit --amend` | 会改写最后一笔（已推送的绝对禁止） |
| `git reset --hard` 丢弃提交 | 让提交从分支上消失 |
| `git filter-branch` / `filter-repo` | 批量重写 |
| push 时 `--force` / `--force-with-lease` | 覆盖远端历史 |
| `git reflog expire` + `gc --prune=now` | 让被丢弃的提交不可恢复 |

**要撤销已提交的内容，一律用追加提交：**

```bash
git revert <sha>          # 反向提交，历史线性前进
git revert --no-edit <sha>
```

工作区里的未提交改动可以随便改、随便丢（`git checkout -- <file>`），那不属于"改写历史"。
