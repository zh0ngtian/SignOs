# SignOs 发布协调

通用协调器独立维护于 [release-coordinator](https://github.com/zh0ngtian/release-coordinator)，
包含代码、部署器、[使用规则](https://github.com/zh0ngtian/release-coordinator/blob/main/USAGE.md)
及[其他项目接入 prompt](https://github.com/zh0ngtian/release-coordinator/blob/main/INTEGRATION_PROMPT.md)。
通用合批原则继承当前 canonical 全局 AGENTS.md；本项目只维护配置、适配器和验证合同。

## 本机入口与隔离

- CLI：`~/.local/bin/releasectl`；服务 label：`local.release-coordinator`。
- 私有状态：`~/Library/Application Support/ReleaseCoordinator/`；Unix socket 及 SQLite
  均只对服务用户开放，无公共监听端口。项目配置：`projects/signos-production.json`。
- 安装模式：读取上述目录的 `installation.json` 与 `launchctl print`；LaunchAgent 表示
  登录后启动，LaunchDaemon 表示登录前开机启动。不把两者混称。
- SignOs 作用域：`zh0ngtian/SignOs`、`com.signos.app`、`production`；GitHub Release 和
  现有固定 OTA 渠道共同构成这个 App 批次的完成条件。其他项目独立作用域可并行；共用
  Mac 或只读签名证书不导致串行。
- 纯服务任务按实际服务 / 环境使用独立配置与适配器；本次只接入 SignOs App 发包，
  未自动接入软件源 Worker 或其他服务的部署。当前队列可在同一发布主机上经 SSH 使用，
  不支持每机各持本地队列，也不公开远程 HTTP API。

## 默认代码交付

开发默认只完成必要验证、合入 `main`、提交并 push，核对远端提交，不进入发布队列。
开始修改前同步并记录 `origin/main` 的基线 SHA，合入前再次 fetch：期间主分支没有
新增提交时可沿用已通过的验证，不重复回归；有新增提交时先整合最新主分支，再对
整合后的代码按改动范围回归，通过后提交并推送。推送前再次前进时重新整合并回归。
完整规则以 [AGENTS.md](../AGENTS.md#测试后的交付规则) 为准。

普通代码交付不调用 `register` 或 `ready`，不自动递增版本 / 构建号、打标签、创建
Release、更新 OTA 或部署服务。现有 main 打包的精确冻结提交校验仍保留，不能为
通过流水线自动发版。只有用户明确要求发布或部署时，才启用对应流程。

## 已获授权的发布任务

明确要求发布后登记，返回 task ID；每分钟更新一次心跳，收尾验证标记 `closing`，受阻标记
`blocked`。独立分支 / worktree 完成必要验证并 push 确定提交后提交就绪；`ready`
授权该已配置发布目标的自动批次发布，不仅是备注。

```sh
~/.local/bin/releasectl register --project signos-production --task <task-id>
~/.local/bin/releasectl heartbeat --task <task-id> --state closing
~/.local/bin/releasectl ready --task <task-id> --sha <full-sha> --validation /private/path/validation.json
~/.local/bin/releasectl wait --task <task-id> --timeout 45
~/.local/bin/releasectl status --task <task-id>
```

本项目登记检查名称为 `adapter-regression`、`release-artifact-regression`、
`release-assets-regression`、`workflow-review`；涉及其他功能的开发任务还须把项目
[AGENTS.md](../AGENTS.md) 要求的对应构建、回归及运行验收写进 checks。
验证记录为 `{"checks":[{"name":"检查名称","status":"passed","evidence":"真实命令和结果"}]}`，
不能把尚未执行的检查标成通过。`--urgent` 跳过合批等待，`--separate` 要求独立批次，
两者都不跳过原有验收要求。未获发布授权的任务按默认代码交付规则完成。

## 中文日志必填与冻结

SignOs 发布任务的就绪验证 JSON 必须同时提供 releaseNotes。每个参与任务都填写本任务实际变化；合批汇总并去重，版本与构建号仍由协调器分配。示例：

```json
{"checks":[{"name":"adapter-regression","status":"passed","evidence":"实际验证结果"}],"releaseNotes":{"language":"zh-Hans","changes":["修复软件源禁用后缺少重新启用入口的问题"]}}
```

校验要求非空条目、简体中文语言标记及具体中文说明（至少四个汉字），拒绝纯英文、TODO/TBD 和“修复已知问题”等常见占位。变更内容是否准确仍由任务复核负责。所有任务缺失或不合格时，prepare 在版本分配、构建与发布前报错，不生成替代日志。

通用协调器的冻结清单只保存固定公开字段，SignOs prepare 因此生成项目专用的 .release-notes.json，记录批次、已分配版本/构建号与任务 ID、SHA、公开变更说明，由正常 freeze 一并提交。CI 校验该文件与 .release-batch.json 的批次、版本及任务身份一致，build-metadata.json 保存 releaseNotesSha256，CI 产物包含 release-notes.json。标签发布复验文件散列；适配器还核对产物日志与冻结工作树文件完全相同。

GitHub Release 与 OTA 共用同一中文变更日志渲染函数；GitHub 正文另附中文安装及校验说明，现有软件源继续从 Release 同步。发布验收检查实际 GitHub 正文与 OTA notes，IPA 校验缓存不能绕过日志检查。恢复已有 OTA 暂存包时，在激活固定渠道前检查日志，错误暂存包及证据保留，按既有修复流程处理。

修改后的本地必要验证包含 python3 -B -m unittest discover -s Tests -p 'test_release_notes.py'；prepare 也会自动运行它。完整设计与验证范围见 [中文更新日志契约](plans/chinese-release-notes.md)。

## 批次与适配器

`scripts/signos_release_adapter.py` 实现以下阶段，协调器逐阶段先 check、执行缺失动作，
再 check。版本、身份和渠道规则保留自原项目，不由通用协调器硬编码。

| 阶段 | 行为与完成证据 |
| --- | --- |
| prepare | 根据项目版本、现有 Release、OTA 和已暂存版本保留一次版本 / 构建号分配；完成合并后的回归和 `make iphoneos`，核对包身份、版本与构建输入稳定性 |
| freeze | 协调器写入去除私有信息的 `.release-batch.json`，创建最终提交并记录完整 SHA、清单散列、任务祖先关系、版本和目标；清单不嵌入自身提交的哈希 |
| build | 仅将冻结提交推进 main；核对该 SHA 的 main run，构建失败或产物过期时恢复同一个提交的构建，不重建无关 main；保存 CI run 与批次产物 |
| github | 为冻结提交发布不可移动的 `vX.Y.Z`；标签 job 复用同 SHA / 同批次 CI 产物；核对整个工作流和 Release 附件、原始 SHA256SUMS |
| ota | 对同一 CI IPA 先 `--plan`，保留签名输入来源，复用现有私有签名配置与兼容基线；发布、完整 HTTPS GET 和独立验签；已完成的签名包不重复签名 |
| verify | 核对所有渠道的已验收结果仍属于本批次；共同凭证包含最终 SHA、CI / release run、未签名与签名散列、固定入口及各阶段结果，任务才标记 complete |

CI 正式 main / 标签使用同一 `signos-production-release` 并发组，
`cancel-in-progress: false`、`queue: max`；PR 和其他分支检查另组。
`scripts/check_release_batch.py` 核对批次目标、版本、所有任务的祖先关系，以及事件 SHA
是否为引入该清单的精确提交；CI 检出完整历史。构建元数据绑定 batch ID 和清单散列，
`prepare_github_release.py` 复验该绑定。之后的文档提交不能代替冻结提交的产物来源。

## 恢复与完成

```sh
~/.local/bin/releasectl batch --id <batch-id>
~/.local/bin/releasectl resume --batch <interrupted-batch-id>
~/.local/bin/releasectl register --project signos-production --task <repair-task-id> --repairs-batch <failed-batch-id>
```

每个作用域有独立租约，10 秒心跳、60 秒过期；接管前仍先读取实际远端状态。
服务重启保持状态，并优先接管中断的子批次，不取消远端 CI。有效 owner 存在时不能接管。
`resume` 只适用于中断且未标记 failed 的批次；阶段错误会保留 failed 状态及诊断，
阻止本作用域无关任务覆盖状态，但不阻止其他项目发布。动作响应丢失时先核对一次远端
效果；已验证成功就继续，不重复执行，也不对持续失败自动循环构建或发布。

合并冲突保留 worktree。将解决结果提交到独立修复分支并 push，以完整 SHA 和必要
验证登记指向最新失败批次的修复任务。关联子批次继承原参与任务和提交，按本项目规则
分配更高版本；原 failed 记录及冻结 worktree 保持不变，不能原地改 SHA。
签名或渠道切换中断后，只能复用本批已验证的完整暂存包；不完整暂存目录及失败证据
保留，按原不可覆盖规则通过更高版本的关联修复恢复，不在同版本上重新签名覆盖。
签名资料仍使用原 `~/Library/Application Support/IOSAdHocOTA/signos/release.local.json`，
历史签名包与验收记录不删除。软件源签名包归档仍需用户另行明确授权。

receipt 位于私有状态目录 `receipts/<batch-id>.json`，全部参与任务读取同一份。
修复子批次成功后，其新任务标为 `complete`，继承任务标为 `recovered` 并通过
`recovered_by` 指向该成功子批次；状态查询与 wait 返回同一份成功凭证，父批次仍为 failed。
共享凭证副本只导出可公开字段到 `docs/plans/evidence/`；私有配置、设备信息和签名材料
不进入 Git。队列、合批、触发 CI 都不代表交付完成，任一要求的渠道失败不能完成。

### 未冻结批次的无效 SHA 登记更正（协调器 0.1.4+）

`ready` 服务入口会在独立临时 Git 仓库核对精确远端 commit，不能以本地未 push 的对象
代替。相同已接受请求可幂等重试，撤回后重新验证。若最新失败叶批次尚未冻结，并明确
记录某任务 `not our ref <SHA>`，可显式登记更正：

```sh
~/.local/bin/releasectl register --project signos-production --task <correction-task-id> \
  --repairs-batch <latest-failed-batch-id> --corrects-task <original-task-id>
```

服务再次确认原 SHA 远端不存在，更正 SHA 已推送后才接受 ready。新批次保留其他任务，
把原任务/SHA与更正任务/SHA写入 manifest 和 receipt 的 `corrections`；原任务与失败
批次历史不改写，成功后原任务 recovered 指向同一凭证。有效提交、其他失败和已冻结
批次不能使用此例外；已冻结失败仍按原关联修复规则发布更高版本。

SignOs 适配器对 `gh api` 的无参数 GET 和 `gh release list` 只读查询，在 EOF、连接重置
或连接超时时最多尝试三次，间隔 1、2 秒。持续失败仍保留诊断并停止；鉴权错误、POST
和发布操作不重放，继续按原阶段核对实际效果。此处理不移动标签，也不借用其他提交产物。

GitHub 附件验收在 REST 已确认完整 Release、且同一冻结提交的标签工作流成功后，
CLI 下载若短暂返回 `release not found`，最多尝试三次，间隔 1、2 秒。
下载成功后仍核对完整 IPA、元数据及原始 SHA256SUMS；持续不可见或认证、校验失败照常停止。

## 验收范围

协调器的并发、有限窗口、锁代次隔离、冻结后新任务、冲突保留、响应丢失恢复与服务
重启回归位于独立仓库。SignOs 适配器回归位于 `Tests/test_signos_release_adapter.py`；
既有发布产物及附件回归继续运行。明确要求发布的批次必须通过一次
正式 main 构建与 GitHub Release / OTA 全链路验收后才算发布交付完成；实际结果另存发布凭证。
用户 App 的签名完成仍不等于真机安装完成，真机覆盖与数据保留不由协调器验收替代。

## 本机部署核验（2026-10-13）

通用协调器版本 [v0.1.3](https://github.com/zh0ngtian/release-coordinator/tree/v0.1.3)，
提交 `cafa2dcf8df01a2bc5dbb90efa268b060d9e7ecb`。19 项本地回归通过，
[跨平台 CI](https://github.com/zh0ngtian/release-coordinator/actions/runs/38286727553)
的 macOS/Linux、Python 3.9/3.13 四组全部成功。
本机按用户选定的登录启动模式部署，`gui/501/local.release-coordinator` 为运行中的
LaunchAgent，`releasectl health` 返回 0.1.3。后续运行事实仍以 health、installation.json
和 launchctl 实际状态为准。

### 本机升级核验（2026-10-13）

协调器已升级至 0.1.4，源码提交
[b345d46c99549f0613f5a7f8f511871113862313](https://github.com/zh0ngtian/release-coordinator/commit/b345d46c99549f0613f5a7f8f511871113862313)。
30 项本地回归和独立复查通过；[跨平台 CI](https://github.com/zh0ngtian/release-coordinator/actions/runs/38375751806)
的 macOS/Linux、Python 3.9/3.13 四组成功。沿既有登录启动模式更新不可变运行时，
health 返回 0.1.4，LaunchAgent 运行中，socket 权限 0600。更新前保存私有 SQLite 与
状态快照；更新后原有任务及批次的 SHA、状态、冻结数据和错误逐字段核对一致。
