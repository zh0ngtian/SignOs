# Cloudflare IPA 软件源

免费 Worker + SQLite Durable Object 保存订阅、版本及任务；Cron 每小时检查一次。IPA 只从原始 URL 读取 Range 片段，用户下载直达原站。客户端最低 iOS 17。

```sh
cd distribution/source-aggregator
npm ci
npm test
cd ../..
python3 scripts/cloud_source.py deploy --plan
python3 scripts/cloud_source.py deploy
python3 scripts/cloud_source.py status
```

部署复用本机 Wrangler 登录，私有管理凭据保存到 `~/.config/signos-source-aggregator/credentials.json`（0600）。不要提交此文件。管理 Token 写入 Worker Secret。默认使用公开 GitHub API；需要增加 GitHub 限额时，应另行授权并配置专用的只读 GitHub Token，不能自动上传本机登录凭据。新服务不使用旧 `yao-app-source` Worker 或 R2。

公开入口为 `/sources/yao.json`，兼容 `/source.json`、`/appstore`；`/health` 为探针。管理接口使用 `Authorization: Bearer <管理 Token>`。新增与配置编辑需携带 `/api/catalog` 的当前 `revision`；冲突返回 409。Token 轮换后旧 Token 立即失效，CLI 的私有凭据也需更新。

| 接口 | 功能 |
| --- | --- |
| GET `/api/catalog` | 订阅、配置修订号、任务和失败原因 |
| POST `/api/discover` | 读取 GitHub IPA 附件候选 |
| POST `/api/entries` | 创建订阅并排队解析 |
| PATCH/DELETE `/api/entries/<id>` | 修改/删除订阅 |
| POST `/api/entries/<id>/confirm` | 确认首次解析结果后公开 |
| POST `/api/entries/<id>/sync`、`/api/sync` | 主动同步 |
| PATCH `/api/settings` | 软件源名称、简介 |
| GET `/api/export`、POST `/api/restore` | 配置及历史备份/恢复 |
| POST `/api/token` | 轮换 Token |
| POST `/api/entries/<id>/presentation` | 迁移开发者、简介、图标 |
| POST `/api/entries/<id>/attest` | 校验 GitHub 全包散列证明 |
| POST `/api/entries/<id>/history` | 独立解析并导入历史 IPA |

备份含完整性签名，不含 Token。在同一持久实例恢复时保留已验证版本、历史和 ID；文件被修改会拒绝恢复。全新存储实例不能验证旧签名时，仅恢复配置和 ID，重新解析后确认发布；历史版本可通过 `history` 接口重新校验导入。应用名称、Bundle ID、版本等不允许手填。

Range 支持 ZIP64、binary/XML plist、Store/Deflate、最大 ZIP 注释和中央目录补读；限制中央目录 4 MiB、plist 解压 512 KiB。忽略 Range 的响应会立即取消。CRC-32 只证明 plist 完整性；公开全包 SHA-256 必须与 GitHub Release 附件的 `digest`、大小一致。正式 SignOs 发布还需先核对 OTA 签名凭证。

任务每次 Alarm 处理一个 IPA，最多三次临时故障重试。订阅修改会使旧修订任务失效。首次失败不公开；更新失败保留旧版本。每个订阅最多保存当前版本和 20 个历史版本。暂停不会删除已发布数据。
