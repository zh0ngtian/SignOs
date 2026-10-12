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

## 开发任务

开始开发就登记，返回 task ID；每分钟更新一次心跳，收尾验证标记 `closing`，受阻标记
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
两者都不跳过原有验收要求。不涉及构建 / 发布的文档任务按原规则直接提交。

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
~/.local/bin/releasectl resume --batch <batch-id>
```

每个作用域有独立租约，10 秒心跳、60 秒过期；接管前仍先读取实际远端状态。
服务重启保持状态并恢复未完成工作，不取消远端 CI。有效 owner 存在时不能接管；
失败批次阻止本作用域新任务覆盖状态，但不阻止其他项目发布。

合并冲突保留 worktree，解决并提交冲突后 resume。已冻结 worktree 不能改内容；
若冻结提交无法安全推进 main，应按项目规则创建关联修复批次，不能原地改 SHA。
签名或渠道切换中断后，只能复用本批已验证的完整暂存包；不完整暂存目录及失败证据
保留，按原不可覆盖规则通过更高版本的关联修复恢复，不在同版本上重新签名覆盖。
签名资料仍使用原 `~/Library/Application Support/IOSAdHocOTA/signos/release.local.json`，
历史签名包与验收记录不删除。软件源签名包归档仍需用户另行明确授权。

receipt 位于私有状态目录 `receipts/<batch-id>.json`，全部参与任务读取同一份。
共享凭证副本只导出可公开字段到 `docs/plans/evidence/`；私有配置、设备信息和签名材料
不进入 Git。队列、合批、触发 CI 都不代表交付完成，任一要求的渠道失败不能完成。

## 验收范围

协调器的并发、有限窗口、锁代次隔离、冻结后新任务、冲突保留、响应丢失恢复与服务
重启回归位于独立仓库。SignOs 适配器回归位于 `Tests/test_signos_release_adapter.py`；
既有发布产物及附件回归继续运行。本次修改客户端构建输入，必须让本批次通过一次
正式 main 构建与 GitHub Release / OTA 全链路验收后才交付；实际结果另存发布凭证。
用户 App 的签名完成仍不等于真机安装完成，真机覆盖与数据保留不由协调器验收替代。
