# 更新管理器持有刷新任务实施计划

> 执行：在当前隔离 worktree 中逐项实施，检查通过后由发布协调器交付。

**目标：** 应用页下拉检查不因页面重绘或切换页面而取消；重复请求等待已有检查，手动远端同步不被普通后台检查吞掉。

**架构：** `AutoUpdateManager` 持有 `UpdateCheckCoordinator`。协调器在 MainActor 创建并持有一个独立任务，调用页面只等待其结果。原更新检查、网络取消检查及结果发布顺序保持；普通检查进行时到达的手动同步请求等待后补做同步。

**授权：** 2026-10-14 用户同意任务归属调整，并要求同时解决切换页面取消。

## 根因证据

正式 1.1.9（31）由 Xcode 26.6 / iOS 26.5 SDK 构建，本机此前的模拟器验收使用 Xcode 27 / SDK 27。
在相同模拟器程序和数据上，仅改变 Mach-O 的链接 SDK 标记：27 检查成功，26.5 连续下拉立即取消，恢复 27 再次成功；26.5 在未接调试器时也复现。
SwiftUI 布局重绘中的 `PlatformRefreshControlProxy.configuration.didSet` 调用 `swift_task_cancel`，取消指针与 UpdateManager 失败任务一致。
另有下拉后切到软件源再返回应用的取消路径。1.1.9 只避免捕获页面值，未解决系统兼容路径及页面生命周期对实际检查任务的影响。
链接 SDK 对照证明兼容行为差异，不能替代使用 Xcode 26.6 完整重建；正式流水线仍保留原构建工具条件。

## 执行步骤

- [x] 添加 `Tests/AutoUpdateCheckRegression.swift` 和 `scripts/test_auto_update_check.py`。提取真实检查阶段与调度方法，以 continuation 控制网络阶段；覆盖取消等待者、重复请求、手动同步排队及失败后重试。
- [x] 修复前运行 `python3 scripts/test_auto_update_check.py`，编译成功，5 条行为断言失败。
- [x] 新建 `Feather/Utilities/UpdateCheckCoordinator.swift`：持有任务；相同检查加入；手动同步等待普通检查后递归请求；任务自身完成时清理持有状态。
- [x] `AutoUpdateManager.checkNow` 委托协调器，原流程移至 `_performCheckNow`；保持 `.refreshable` 直接等待管理器结果。
- [x] 运行新回归及 `python3 scripts/test_update_manager.py 21ED4863-0087-416A-BD30-259BF2512540`，确认检查序列、失败保留和取消行为。
- [x] 构建 Release 模拟器包。按 SDK 26.5 对照场景，在应用页连续下拉以及刷新过程中切换页面，核对远端同步、客户端成功记录和错误提示。
- [x] 完成 `make iphoneos`、发布适配器/产物/附件回归、工作流核对及 `git diff --check`。
- [x] 只读独立审查；提交开发分支并 push，核对远端 SHA，提交带真实验证记录的 `ready`。
- [x] 读取同一批次共同凭证，核对 main/tag workflow、GitHub Release 附件、固定 OTA 完整下载与版本/构建号，更新具体中文软件源日志及受影响文档。

诊断包、私有令牌、原始设备资料与签名材料保留在仓库外。模拟器功能验收不代表真机覆盖安装已完成。

## 本地验收（2026-10-14）

[核验记录](evidence/owned-refresh-20261014.json)保留连续下拉与切页场景的 7 个远端任务成功状态及客户端检查时间。新调度回归、原更新管理器回归、Release 模拟器/设备构建、发布合同检查及独立审查通过。发布共同凭证及回验结果见下节。

## 发布准备环境恢复

开发提交 `315ed9daadf475ee52a8c8aa562021b1dfcec25e` 已 push 并被协调器接受。
首批 `b0328d94-5ad5-4071-9eeb-dbf48559460a` 在 prepare 的本地构建阶段失败，默认 SwiftPM 缓存保留了目录及状态记录，但 35 个依赖检出缺少 `Package.swift` 等源码；此时未冻结提交、未推进 main、未发布标签。
逐包按 `Package.resolved` 核对完整缓存的 Git revision 后恢复默认缓存，旧不完整目录与诊断留在仓库外；没有改变依赖版本或客户端代码。关联恢复任务为 `signos-owned-refresh-cache-repair-20261014`，发布版本及批次仍只由协调器决定。

关联批次 `0be3ded8-2c5e-4a64-83dd-95125eeab09c` 已冻结 1.1.10（32），正式 main 构建成功，GitHub 标签及附件已发布。在附件验收时，REST 已能读取完整 Release，但 CLI 下载短暂返回 `release not found`，协调器因此失败，OTA 尚未更新。
为这条已经确认发布的只读下载添加最多三次尝试（间隔 1、2 秒）；认证、校验和等其他错误及所有发布写操作不重试。新增回归先出现两条行为失败，后验证恢复、次数上限及认证失败不重试。新关联任务 `signos-owned-refresh-release-read-repair-20261014` 保留既有标签和两个失败批次，由协调器分配后续版本并交付两个渠道。

## 最终交付（2026-10-14）

已由关联批次 `619c1407-7d0e-49b9-9634-73ac3925a45e` 交付 **1.1.11（构建 33）**。
冻结提交 `ce4c3e03225dcce48449022afcfe796cbbd298fe` 的
[main 构建](https://github.com/zh0ngtian/SignOs/actions/runs/38497609149)和
[标签发布](https://github.com/zh0ngtian/SignOs/actions/runs/38498721607)均成功。
[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.11)三个附件与该提交 CI 产物一致；
[固定 OTA](https://192.168.123.79:8769/channels/signos/current/install.html)版本、构建号、manifest、签名和完整 IPA 散列回验通过。
原开发任务与缓存修复任务为 recovered，发布读取修复任务为 complete，均关联同一共享凭证；两个失败批次和 1.1.10 标签保留。

最后的软件源回验发现：同一 GitHub IPA 的同步分支保留旧日志，导致已编辑的中文说明未进入公开源。
仅在 GitHub 同包分支更新当前 notes，保留历史和已 attested SHA；新增断言先失败，修复后 40 项服务回归、语法及独立审查通过。
服务提交 `29de68bfd97488b31832c33b9342ce561948b163` 独立部署到现有 source-aggregator Worker，部署版本
`18396f10-f442-4b99-8dc2-f163784821ab`。真实 HTTPS 软件源已确认 1.1.11（33）、具体中文日志、完整散列及历史保持。
这一服务更新未重构建客户端，客户端仍对应上述冻结提交。

[共享交付凭证](evidence/release-batch-1.1.11-20261014.json)记录客户端双渠道及服务回验。功能验收为模拟器，不代表已完成本次真机覆盖安装。
