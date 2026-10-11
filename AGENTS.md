# SignOs 项目规则

## 项目与权威入口

- SignOs 是基于 Feather 的 iOS 签名、安装和更新应用；技术栈为 Swift / SwiftUI、Vapor / NIOSSL，以及 Python 分发脚本。
- 本文件是项目规则唯一正文；如需 `CLAUDE.md`，仅建立指向本文件的兼容入口。
- 构建流水线、TLS 与按需 OTA 操作以 [README.md](README.md) 为准；安装机制见 [HOW_IT_WORKS.md](HOW_IT_WORKS.md)。
- `Feather/` 为应用，`Tests/` 为回归检查，`scripts/` 为本机分发服务；`Zsign/`、`IDeviceKitten/` 是 Git 子模块，不能当普通目录提交。

## 构建与验证

- 使用 Xcode 26+，先初始化子模块，再按 README 配置私有 `TLS_DIR`，运行 `make iphoneos`；产物为 `packages/SignOs.ipa`。
- 安装状态改动运行 README 中的 `OneViewPhaseRegression`；应用代码改动还须完成对应构建与必要的运行验收。不涉及 App 安装的改动，在 iOS 模拟器中验证即可；涉及 App 安装的改动，真机可用时使用真机，找不到真机时改用 iOS 模拟器，不强制等待连接。模拟器不能证明 Ad Hoc 覆盖安装与数据保留，交付时按实际验证范围说明。
- Python 服务改动检查语法、受影响接口与 HTTPS 下载；文档改动检查路径、命令和 `git diff --check`。
- 签名完成不代表安装完成；服务端 OTA 无法确认安装结果时必须保留重试入口。

## 测试后的交付规则

- 测试和必要检查通过后，提交并 push 本次改动，核对远端提交，再等待该提交的 GitHub Actions `iOS Build Check` 成功；不能停在本地测试通过或仅触发流水线的状态。
- 流水线位于 `.github/workflows/ios-build.yml`，覆盖 `main` push、面向 `main` 的 PR 和手动触发；检查 Swift 回归、iOS Release 构建、IPA 身份与完整性，并保留构建产物及诊断日志。
- 常规客户端交付以流水线构建检查为准，无须递增构建号或自动发布 App。构建产物未经过分发签名，不能作为正式安装包；用户明确要求 OTA 发包时再递增构建号、使用私有配置签名并发布。
- 涉及服务改动时，仍须部署对应服务，核对进程及真实 HTTPS 接口；不涉及服务改动时不必更新服务。纯文档、规则与流水线变更无须部署服务或发布 App。
- 测试、push、流水线或必要部署失败时，明确报告停在哪一步，不宣称交付完成。流水线成功只证明回归与构建检查通过，设备安装按实际验收范围说明。
- 按需 OTA 发布前先执行发布器的 `--plan`，保留 SignOs 自身的兼容基线和升级身份；发布后核对固定入口、manifest、包版本、构建号和完整 IPA SHA-256。

## 资料与产物边界

- 签名材料、设备信息、CA 私钥及私有配置留在仓库外；`deps/`、`_build/`、`packages/` 不提交。
- Fully Local 使用具体主机名和设备信任的 TLS 证书，不能把通配符证书名直接用作 URL；Documents 内的 TLS 文件优先于包内资源。
- 收尾同步受影响文档。历史签名包、发布凭证、设备验收记录及兼容基线须保留，不能当作临时文件自动删除。
- 当前构建结果以对应提交的 GitHub Actions run 为准；按需 OTA 发布事实从私有配置、固定渠道和在线探针重新取得。README 的带日期核验是快照，不能替代下一次验收。
