# SignOs 项目规则

## 项目与权威入口

- SignOs 是基于 Feather 的 iOS 签名、安装和更新应用；技术栈为 Swift / SwiftUI、Vapor / NIOSSL，以及 Python 分发脚本。
- 本文件是项目规则唯一正文；如需 `CLAUDE.md`，仅建立指向本文件的兼容入口。
- 构建流水线、TLS 与 OTA 操作以 [README.md](README.md) 为准；安装机制见 [HOW_IT_WORKS.md](HOW_IT_WORKS.md)。
- `Feather/` 为应用，`Tests/` 为回归检查，`scripts/` 为本机分发服务；`Zsign/`、`IDeviceKitten/` 是 Git 子模块，不能当普通目录提交。

## 构建与验证

- 使用 Xcode 26+，先初始化子模块，再按 README 配置私有 `TLS_DIR`，运行 `make iphoneos`；产物为 `packages/SignOs.ipa`。
- 安装状态改动运行 README 中的 `OneViewPhaseRegression`；应用代码改动还须完成对应构建与必要的运行验收。不涉及 App 安装的改动，在 iOS 模拟器中验证即可；涉及 App 安装的改动，真机可用时使用真机，找不到真机时改用 iOS 模拟器，不强制等待连接。模拟器不能证明 Ad Hoc 覆盖安装与数据保留，交付时按实际验证范围说明。
- Python 服务改动检查语法、受影响接口与 HTTPS 下载；文档改动检查路径、命令和 `git diff --check`。
- 改动不涉及客户端时，不执行或手动触发客户端构建；仅完成受影响部分的检查。客户端改动包括应用源码与资源、客户端依赖、工程配置、客户端回归和构建输入。
- 私有 GitHub 软件源使用服务端凭据解析，用户于 2026-10-20 选择发布后公开代理下载；确认发布允许持有源地址的人匿名下载。代理仅服务已发布订阅的当前与保留历史附件，删除后失效；GitHub Token 只发往 GitHub API，临时 CDN 地址不得持久化或公开。此服务能力无需改动客户端，未明确要求部署时仅交付代码。详见 [Cloudflare 软件源](distribution/source-aggregator/README.md)。
- 签名完成不代表安装完成；应用页按最新成功签名包展示“已安装”是产品约定，不能据此提前清理旧包或声称 OTA 安装已确认。服务端 OTA 无法确认安装结果时默认保留重试入口。用户主动删除且没有任务占用时，可在二次确认放弃所选包的安装重试后删除；仅在删除成功后清理对应待安装记录，其他安装计划保留。自动清理仍必须保护待完成安装的包。
- 博物女神重签须同时对齐主 App 与 Widget 的 `MuseumAppGroupIdentifier` 和描述文件授权；保留输入已声明的共享组，未声明时按原始身份或既有私有 OTA 兼容身份处理，不任取证书中的其他组。自定义权限冲突、缺少 Widget 或签名后两目标授权不一致时停止生成安装包。此适配只作用于 `tech.zh0ngtian.MuseumMuse`，不改 Bundle ID、版本、安装身份或其他 App；详细合同与验收见 [博物女神共享组适配](docs/plans/museummuse-shared-group.md)。
- 应用页合并、多源候选、软件源开关、订阅清理和证书替换契约见 [应用页合并方案](docs/plans/application-tab-merge.md)。

## 测试后的交付规则

- 默认交付到代码仓库：完成改动范围内的必要验证，合入 `main`，按下条判断是否需要合入后回归，通过后完成提交、push 并核对远端提交。所有改动均默认不发布，包含客户端源码与资源、依赖、工程配置、客户端回归、构建输入、服务和文档；只有用户明确要求发布或部署时，才进入对应流程。
- 开始修改前同步并记录 `origin/main` 的基线 SHA；验证成功、准备合入时再次 fetch 并比较主分支。如果修改期间主分支没有新增提交，可沿用本次已通过的验证，无须合入后重复回归；如果主分支有新增提交，先整合最新主分支并解决冲突，再对整合后的代码按改动范围回归，成功后提交并推送 `main`。推送前再次核对远端；主分支又有新增提交时重新整合并回归，不强推覆盖。
- 普通代码交付不登记发布任务、不提交 `releasectl ready`，不自动递增版本或构建号、不打发布标签、不创建 GitHub Release、不更新 OTA 或部署服务。`ready` 会授权自动发布，不能用于记录普通验证成功。纯文档、规则和其他非客户端改动仍不触发或等待客户端构建。
- 流水线位于 `.github/workflows/ios-build.yml`，对客户端源码、依赖、回归和构建输入（含构建工作流自身）的 `main` push 和面向 `main` 的 PR 自动运行，另保留手动构建和 `v*` 标签发布入口。日常 CI 递归检出子模块、检查 Xcode 26+ 与 iOS SDK，只执行一次 `generic/platform=iOS` 的无签名 Release 构建；`main` push 和 `main` 手动构建同时打包、校验 IPA，生成元数据并保留产物 14 天，供后续标签发布复用。PR 和其他分支手动构建仅编译、链接。不运行回归或模拟器，只在失败时上传构建诊断。纯服务、文档、规则和其他非客户端改动跳过自动客户端构建。
- 完整 Swift / Python 与更新、下载管理器、安装清理模拟器回归移至 `.github/workflows/ios-regression.yml`，仅手动按需运行。功能须按改动范围在本地验证，CI 成功不能替代功能验收。
- 测试、合入、push 或流水线失败时，明确报告停在哪一步，不宣称代码交付完成；不能为了通过流水线自动发版。现有 `main` 打包仍校验冻结清单及其精确引入提交，默认不发布的规则本身不改变该流水线限制。

## 用户明确要求发布时

- 仅发布任务使用协调器；通用合批窗口、冻结、互斥及中断恢复规则继承当前生效的 canonical 全局 `AGENTS.md`。SignOs 的发布作用域、已部署入口、适配器与验收范围见 [发布协调说明](docs/release-coordination.md)。通用协调器独立维护于 https://github.com/zh0ngtian/release-coordinator，本项目不复制其核心实现。
- SignOs App 的发布作用域为本仓库、`com.signos.app` 和既有正式 GitHub Release / 固定 OTA 渠道。明确要求发布后，用 `~/.local/bin/releasectl register --project signos-production` 登记并维持心跳；本地必要验证及开发分支 push 后，以完整 SHA 和验证记录提交 `ready`。只有协调器负责发布批次的版本分配、整合、冻结、main 推进、构建、标签及 OTA；任务读取同一份 batch receipt，不能另行发包。App 批次凭证必须关联最终提交、`main` 构建 run、标签发布 run、Release 附件及 OTA 回验结果。失败批次的关联修复、`recovered` 状态及成功子批次凭证以发布协调说明为准。
- 每个明确要求发布的 App 批次由协调负责人按 README 统一递增版本与构建号，参与任务共用该版本；为冻结的最终提交等待成功的 `main` 构建，再推送 `vX.Y.Z` 标签。标签流程不再执行 iOS 构建，只复用同一仓库、同一冻结提交的成功 `main` 构建产物，核对版本、身份、元数据与校验和后上传附件，不自动运行回归。缺失或过期的产物须先重跑该提交的 `main` 构建，再重跑标签工作流，不取其他提交或 PR 的产物。构建与产物校验成功且标签和 IPA 版本一致后，发布 IPA、构建元数据与 SHA-256。发布须等待标签对应的整个工作流成功并核对 Release 附件。已发布标签不移动。
- `.github/workflows/ios-build.yml` 的正式 main / 标签发布共用 `signos-production-release` 并发组，`cancel-in-progress: false`、`queue: max`，PR / 其他分支检查另组；CI 校验冻结清单及其引入提交，不能用后续 main 提交借用产物。修改该工作流仍属客户端构建输入变更，须完成对应验证，是否发布遵循默认不发布规则。
- 每次发布 App 都须同时交付 GitHub Release 和 OTA：GitHub Release 保留未分发签名的构建产物，使用同一已验证产物和现有私有配置进行 Ad Hoc 签名并更新固定 OTA 渠道，保证版本一致、构建号递增。用户已持续授权后续发布的 OTA 签名与发包，无须逐次询问；最终回复必须给出可点击的固定 OTA 安装页链接及实际版本、构建号。
- 后续向软件源发布或更新版本时，更新日志必须使用中文，清楚列出该版本实际新增、改进和修复的内容；按版本填写，不得用笼统描述替代具体变更。 就绪验证 JSON 必须提供 releaseNotes（zh-Hans 与具体 changes 条目）；所有参与任务缺失或不合格时，适配器在版本分配及构建前阻止发布。冻结日志随同一提交与 CI 散列绑定，GitHub / OTA 实际日志也必须匹配；详见 [中文日志契约](docs/plans/chinese-release-notes.md)。
- 用户明确要求部署服务时，部署对应服务并核对进程及真实 HTTPS 接口；纯服务部署不触发 App 发布。不涉及服务改动时不必更新服务。
- 测试、push、流水线、发布或必要部署失败时，明确报告停在哪一步，不宣称交付完成。`main` 的 `iOS Build Check` 成功表示构建与 IPA 校验通过，标签发布还须重新核对同一产物；功能与设备安装按实际本地验收范围说明。
- OTA 发布前先执行发布器的 `--plan`，保留 SignOs 自身的兼容基线和升级身份；发布后核对固定入口、manifest、包版本、构建号和完整 IPA SHA-256。GitHub Release 或 OTA 任一未完成时，不能宣称 App 发布交付完成。

## 资料与产物边界

- 签名材料、设备信息、CA 私钥及私有配置留在仓库外；`deps/`、`_build/`、`packages/` 不提交。
- Fully Local 使用具体主机名和设备信任的 TLS 证书，不能把通配符证书名直接用作 URL；Documents 内的 TLS 文件优先于包内资源。
- 收尾同步受影响文档。历史签名包、发布凭证、设备验收记录及兼容基线须保留，不能当作临时文件自动删除。
- 当前构建结果以对应提交的 GitHub Actions run 为准；OTA 发布事实从私有配置、固定渠道和在线探针重新取得。README 的带日期核验是快照，不能替代下一次验收。
