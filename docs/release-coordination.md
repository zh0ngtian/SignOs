# SignOs 发布协调接入与机制核对

核对日期：2026-10-12。本文件记录项目接入信息和实现缺口，不复制通用合批规则。
通用原则维护在当前生效的 canonical 全局 `AGENTS.md`；本机为 `~/.codex/AGENTS.md`。
项目验证和交付合同见 [AGENTS.md](../AGENTS.md)，底层操作见 [README.md](../README.md)。

**当前状态：规则已定义，统一协调机制待实现。** 本次只更新规则和发布说明，不修改
CI、发布脚本、App 版本或服务，不触发构建、签名、发布或部署。下文的建议入口、状态
后端、记录字段及 CI 配置均为改造要求，不能当作已存在的命令或自动门禁。

## 项目发布作用域

| 对象 | 协调与交付边界 |
| --- | --- |
| SignOs App | 仓库 `zh0ngtian/SignOs`、Bundle ID `com.signos.app`、现有正式 GitHub Release 与 SignOs 固定 OTA 渠道；这两个渠道属于同一 App 批次的共同完成条件 |
| OTA 服务 | `scripts/serve_ios_ota.py` 对应的既有服务与部署环境；服务改动仍须核对进程和真实 HTTPS 接口，App 发包无需重启未改动服务 |
| 软件源服务 | 按实际 Worker / 服务及环境登记；见 [软件源说明](../distribution/source-aggregator/README.md)和[兼容服务说明](../hosting/home-source/README.md)，不能仅因同仓库就并入 App 发包 |

App 版本继续使用 `Feather.xcconfig` 的 `FEATHER_PROJECT_VERSION`，构建号使用
`Feather.xcodeproj/project.pbxproj` 的 `CURRENT_PROJECT_VERSION`；每批统一递增，
高于之前发出的包。版本改动须先纳入最终提交再冻结，发布标签仍为 `vX.Y.Z`。
冻结提交及其验证结果、版本、参与任务和全部发布目标必须写入同一批次记录。
若一个任务同时影响 App 和服务，须记录关联批次与部署顺序，所有要求的目标均成功才完成。

固定 OTA 安装页继续使用现有私有配置决定的地址；README 的地址和历史验收为快照。
签名配置仍在 `~/Library/Application Support/IOSAdHocOTA/signos/release.local.json`，
兼容基线、签名材料和历史产物保持仓库外。此规则不新增分发渠道；签名包的 Cloudflare
归档仍只在用户另行明确要求时执行。

## 现有能力与缺口

| 环节 | 代码证据与现状 | 支持程度 |
| --- | --- | --- |
| 任务登记、活跃任务判断、合批窗口 | 未发现统一入口、共享就绪队列或窗口计时器；聊天列表和 Git 分支不能替代队列 | 待实现 |
| 冲突整合、版本分配、冻结与 `main` 推进 | 当前由任务手动操作，未校验批次、协调锁或冻结 SHA | 待实现 |
| 同提交 CI 产物 | `scripts/check_ios_build.sh` 写入提交、版本、构建号和 SHA-256；`scripts/find_release_artifact.py` 只选同仓库同 SHA 的成功 `main` push / 手动构建，拒绝过期产物 | 已支持产物约束，未绑定批次 |
| 正式 CI 防抢占与排队 | `.github/workflows/ios-build.yml` 使用按 PR / ref 分组的 concurrency，非标签 run 的 `cancel-in-progress` 为 true，未设置 `queue`；不同标签也不共享同一发布环境的组 | 不满足新规则 |
| 标签发布 | `scripts/prepare_github_release.py` 核对 SHA、版本、身份、大小、完整散列和未分发签名状态；标签 job 复用产物，上传三份附件 | 已支持单次发布，未校验协调负责人或共享批次凭证 |
| OTA 锁与验收 | 外部既有 `ios-adhoc-ota` 发布器以私有配置目录的 `release.lock` / `fcntl.flock` 串行签名与 OTA；`ios_ota.py` 用目标目录的 `.publish.lock` 保护暂存和原子切换，并做 HTTPS 回验 | 局部本机互斥；不覆盖 `main`、CI、标签及完整批次，无心跳或多机协调 |
| 其他发布工具 | `scripts/publish_signos.py` 校验现有 OTA 凭证与包；`scripts/app_source.py`、`scripts/home_source.py` 有目录级文件锁 | 不能替代仓库 / 环境协调器；不自动加入普通 App 批次 |
| 完成与恢复 | 历史凭证保存在 `docs/plans/evidence/` 及仓库外发布目录；未建立任务到批次的共享状态机、统一恢复入口或共享完成凭证 | 历史证据可复用，完整机制待实现 |

`flock` 进程结束后可释放互斥，但不会说明任务是否已成功发包，也没有负责人、心跳、
租约或接管核验。它不能充当合批队列，更不能据此宣称多机器恢复已支持。

## 具体改造项（均未实施）

1. **统一入口和共享登记**：建议新增 `scripts/coordinate_release.py`，提供任务登记、
   就绪、状态、整合、执行和恢复入口，复用现有 Python 发布工具。登记项至少包括任务 ID、
   负责人、发布作用域、开发分支 / worktree、确定的远端 SHA、本地验证结果和待决问题；
   记录活跃、收尾验证、受阻、就绪等状态，按全局有限窗口选择兼容任务。所有 worktree
   连接同一状态后端，不能各自维护独立队列。具体后端尚未配置。
2. **协调锁与中断恢复**：增加覆盖版本分配、`main` 推进、构建、标签、签名和部署的
   仓库 / 环境协调租约，与既有 OTA 低层锁分层使用。保存 owner、心跳、租约到期时间、
   锁代次和状态修订号；原子领取与写入，阻止旧负责人继续推进。单机实现须使用同一
   仓库级共享位置；多机实现须选所有参与方可访问并支持原子互斥的后端，不能仅用各机
   `release.lock`。接管先核对远端 `main`、CI run、标签、Release 附件、OTA 当前版本与
   散列、相关服务进程和 HTTPS 接口，再决定补做剩余步骤。
3. **合并检查和冻结记录**：建立包含 task IDs、原始 SHA 到整合提交的映射、最终 SHA、
   版本 / 构建号、目标环境、必要验证、时间与负责人的不可变批次描述；解决同文件冲突，
   完成合并后的必要检查，将统一版本纳入最终提交后冻结。新任务进入下一批；初次正式
   构建只启动一次，并记录其 run ID、artifact ID、SHA 和散列。需要恢复的尝试单独登记，
   不回写或替换原冻结记录。
4. **CI 并发与入口约束**：后续调整 `.github/workflows/ios-build.yml` 的正式 `main`
   构建和标签发布，使用按 SignOs 发布作用域稳定命名的组，关闭 `cancel-in-progress`
   并设置 `queue: max`；PR 检查另组处理。所有正式路径要校验冻结批次与 SHA，手动入口
   不能绕过登记。若将完整回归用于批次的必需检查，也须避免其被无关任务取消；现有
   `ios-regression.yml` 仍是手动按需入口，本次不改变其职责。
5. **统一执行与共同凭证**：协调入口顺序调用现有构建检查、同 SHA 产物查找、标签发布、
   OTA `--plan`、签名与回验，以及必要服务部署；不让参与任务分别签名或重复部署。
   共同凭证关联 batch ID、任务映射、最终 SHA、验证结果、CI / release run、标签和附件、
   未签名与签名包散列、OTA 版本与固定入口回验、服务验收及各阶段结果。凭证仓库内
   仅保存可公开信息，私有材料与设备信息仍在仓库外。
6. **失败与恢复验收**：保留失败批次、诊断和尝试记录；测试并发登记、窗口截止、冲突整合、
   冻结后新任务、负责人中断 / 过期接管、响应丢失、单渠道失败以及多机同时接管。
   对已有成功发布按提交、版本与散列复用凭证，禁止重复签名或部署。产物缺失 / 过期仍
   重跑原提交的 `main` 构建；已发布标签不移动，已暂存不可覆盖目录的恢复仍按既有
   发布器规则使用更高版本，并保留原批次及关联的新恢复批次，不能拿无关任务覆盖失败。

GitHub 的 `queue: max` 用于保留多条待运行 workflow / job；它与
`cancel-in-progress: true` 不兼容。排队只提供 CI 串行执行，任务合批、冻结和跨 GitHub / OTA
的完整发布互斥仍由协调入口负责，不能只修改 concurrency 就宣称全套机制完成。
依据：[GitHub 官方并发文档](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)。

## 保留的验证与交付要求

- 开发阶段继续按 [项目规则](../AGENTS.md) 完成本地构建、对应回归及必要模拟器 / 真机验收；
  不因合批减少功能验证，也不为每次状态查询重复构建。
- 冻结提交继续使用既有 Xcode 26+、递归子模块和无签名 Release 构建；标签只复用同 SHA
  的成功 `main` 构建产物，附件及保留期限不变。CI 成功不能替代功能验收。
- App 批次仍同时交付 GitHub Release 和 Ad Hoc OTA，发布前执行 `--plan`，保持升级身份，
  发布后核对固定入口、manifest、版本、构建号、完整 IPA SHA-256。任一渠道失败不能完成。
- 服务任务仍执行对应部署、进程及真实 HTTPS 接口验收。纯规则、文档和其他无构建 / 发布
  改动检查后直接提交与 push，不额外构建、发 App 或部署服务。
- 协调器 / CI 的代码改造须按实际影响范围验证；属于客户端构建输入的改造仍须发布新版。
  当前文档任务没有这类改动。历史签名包、发布凭证、验收记录和兼容基线全部保留。
