# SignOs 项目规则

## 项目与权威入口

- SignOs 是基于 Feather 的 iOS 签名、安装和更新应用；技术栈为 Swift / SwiftUI、Vapor / NIOSSL，以及 Python 分发脚本。
- 本文件是项目规则唯一正文；如需 `CLAUDE.md`，仅建立指向本文件的兼容入口。
- 构建、TLS、OTA 与软件源运维以 [README.md](README.md) 为准；安装机制见 [HOW_IT_WORKS.md](HOW_IT_WORKS.md)。
- `Feather/` 为应用，`Tests/` 为回归检查，`scripts/` 为本机分发服务；`Zsign/`、`IDeviceKitten/` 是 Git 子模块，不能当普通目录提交。

## 构建与验证

- 使用 Xcode 26+，先初始化子模块，再按 README 配置私有 `TLS_DIR`，运行 `make iphoneos`；产物为 `packages/SignOs.ipa`。
- 安装状态改动运行 README 中的 `OneViewPhaseRegression`；应用代码改动还须完成对应构建与必要的设备验收。
- Python 服务改动检查语法、受影响接口与 HTTPS 下载；文档改动检查路径、命令和 `git diff --check`。
- 签名完成不代表安装完成；服务端 OTA 无法确认安装结果时必须保留重试入口。

## 测试后的交付规则

- 测试和必要检查通过后，提交并 push 本次改动，再按以下条件完成部署与发包；不能停在本地测试通过或仅有构建产物的状态。
- 涉及服务改动时，部署对应服务；不涉及服务改动时，不必更新服务。
- 涉及客户端代码改动时，递增构建号，将同一正式签名 IPA 发布到本机 OTA 和 Yao App Source 两个渠道；没有客户端代码改动时，不必发布 App，用户明确要求补发除外。
- 服务与客户端都改时，两项均须完成。纯文档或规则变更检查通过后提交并 push，无须部署服务或发布 App。
- push 后核对远端提交；部署后核对服务进程及真实 HTTPS 接口；发布后核对固定入口、manifest、包版本和 SHA-256。测试、push、部署或发布失败时，明确报告停在哪一步，不宣称交付完成。
- 本机 OTA 与 Yao App Source 是不同渠道。按 README 使用现有私有配置；发布前先执行发布器的 `--plan`，保留 SignOs 自身的兼容基线和升级身份。OTA 成功后必须用 `scripts/publish_signos.py` 将同一签名包及其发布凭证同步到软件源；公网清单、版本、构建号和完整 IPA SHA-256 核验通过才算客户端发布完成，不能只完成一个渠道。
- 不把 GitHub Actions 的触发配置当作成功发布凭证；当前 CI 的 TLS 配置缺口见 README。

## 资料与产物边界

- 签名材料、设备信息、CA 私钥及私有配置留在仓库外；`deps/`、`_build/`、`packages/` 不提交。
- Fully Local 使用具体主机名和设备信任的 TLS 证书，不能把通配符证书名直接用作 URL；Documents 内的 TLS 文件优先于包内资源。
- 收尾同步受影响文档。历史签名包、发布凭证、设备验收记录及兼容基线须保留，不能当作临时文件自动删除。
- 当前发布事实应从私有配置、固定渠道和在线探针重新取得；README 的带日期核验是快照，不能替代下一次发布验收。
