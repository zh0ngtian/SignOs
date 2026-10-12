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
- 签名完成不代表安装完成；应用页按最新成功签名包展示“已安装”是产品约定，不能据此提前清理旧包或声称 OTA 安装已确认。服务端 OTA 无法确认安装结果时必须保留重试入口。
- 应用页合并、多源候选、软件源开关、订阅清理和证书替换契约见 [应用页合并方案](docs/plans/application-tab-merge.md)。

## 测试后的交付规则

- 通用的多任务协调、合批窗口、冻结、互斥及中断恢复规则继承当前生效的 canonical 全局 `AGENTS.md`，不在本项目复制正文。SignOs 的发布作用域、已部署入口、适配器与验收范围见 [发布协调说明](docs/release-coordination.md)。通用协调器独立维护于 https://github.com/zh0ngtian/release-coordinator，本项目不复制其核心实现。
- SignOs App 的协调作用域为本仓库、`com.signos.app` 和既有正式 GitHub Release / 固定 OTA 渠道。就绪登记附本节要求的本地验证结果与远端开发提交 SHA；App 批次交付凭证必须关联最终提交、`main` 构建 run、标签发布 run、Release 附件及 OTA 回验结果。纯服务任务按实际服务与环境另行协调。开始开发即用 `~/.local/bin/releasectl register --project signos-production` 登记并维持任务心跳；本地必要验证及开发分支 push 后，以完整 SHA 和验证记录提交 `ready`。只有协调器负责版本分配、整合、冻结、main 推进、构建、标签及 OTA；任务读取同一份 batch receipt，不能另行发包。
- 不涉及构建或发布的改动完成相应检查后直接提交、push 并核对远端提交，无须为了合批触发或等待客户端流水线。
- 流水线位于 `.github/workflows/ios-build.yml`，对客户端源码、依赖、回归和构建输入（含构建工作流自身）的 `main` push 和面向 `main` 的 PR 自动运行，另保留手动构建和 `v*` 标签发布入口。日常 CI 递归检出子模块、检查 Xcode 26+ 与 iOS SDK，只执行一次 `generic/platform=iOS` 的无签名 Release 构建；`main` push 和 `main` 手动构建同时打包、校验 IPA，生成元数据并保留产物 14 天，供后续标签发布复用。PR 和其他分支手动构建仅编译、链接。不运行回归或模拟器，只在失败时上传构建诊断。纯服务、文档、规则和其他非客户端改动跳过自动客户端构建。
- 完整 Swift / Python 与更新、下载管理器、安装清理模拟器回归移至 `.github/workflows/ios-regression.yml`，仅手动按需运行。功能须按改动范围在本地验证，CI 成功不能替代功能验收。
- 任何涉及 App 的改动都必须在验证通过后随所属批次发布新版，不按改动类型、规模或是否改变用户可见功能区别处理；范围包含客户端源码与资源、依赖、工程配置、客户端回归和构建输入。每批由协调负责人按 README 统一递增版本与构建号，参与任务共用该版本；为冻结的最终提交等待成功的 `main` 构建，再推送 `vX.Y.Z` 标签。发布默认使用 GitHub Release，标签流程不再执行 iOS 构建，只复用同一仓库、同一冻结提交的成功 `main` 构建产物，核对版本、身份、元数据与校验和后上传附件，不自动运行回归。缺失或过期的产物须先重跑该提交的 `main` 构建，再重跑标签工作流，不取其他提交或 PR 的产物。构建与产物校验成功且标签和 IPA 版本一致后，发布 IPA、构建元数据与 SHA-256。发布须等待标签对应的整个工作流成功并核对 Release 附件。已发布标签不移动。
- `.github/workflows/ios-build.yml` 的正式 main / 标签发布共用 `signos-production-release` 并发组，`cancel-in-progress: false`、`queue: max`，PR / 其他分支检查另组；CI 校验冻结清单及其引入提交，不能用后续 main 提交借用产物。后续修改该工作流仍属客户端构建输入变更，须完成对应验证与双渠道发布。
- 每次发布 App 都须同时交付 GitHub Release 和 OTA：GitHub Release 保留未分发签名的构建产物，使用同一已验证产物和现有私有配置进行 Ad Hoc 签名并更新固定 OTA 渠道，保证版本一致、构建号递增。用户已持续授权后续发布的 OTA 签名与发包，无须逐次询问；最终回复必须给出可点击的固定 OTA 安装页链接及实际版本、构建号。
- 涉及服务改动时，仍须部署对应服务，核对进程及真实 HTTPS 接口；不涉及服务改动时不必更新服务。纯文档、规则以及与客户端无关的流水线变更无须部署服务或发布 App；涉及客户端构建输入的流水线变更仍须发布新版。
- 测试、push、流水线、发布或必要部署失败时，明确报告停在哪一步，不宣称交付完成。`main` 的 `iOS Build Check` 成功表示构建与 IPA 校验通过，标签发布还须重新核对同一产物；功能与设备安装按实际本地验收范围说明。
- OTA 发布前先执行发布器的 `--plan`，保留 SignOs 自身的兼容基线和升级身份；发布后核对固定入口、manifest、包版本、构建号和完整 IPA SHA-256。GitHub Release 或 OTA 任一未完成时，不能宣称 App 发布交付完成。

## 资料与产物边界

- 签名材料、设备信息、CA 私钥及私有配置留在仓库外；`deps/`、`_build/`、`packages/` 不提交。
- Fully Local 使用具体主机名和设备信任的 TLS 证书，不能把通配符证书名直接用作 URL；Documents 内的 TLS 文件优先于包内资源。
- 收尾同步受影响文档。历史签名包、发布凭证、设备验收记录及兼容基线须保留，不能当作临时文件自动删除。
- 当前构建结果以对应提交的 GitHub Actions run 为准；OTA 发布事实从私有配置、固定渠道和在线探针重新取得。README 的带日期核验是快照，不能替代下一次验收。
