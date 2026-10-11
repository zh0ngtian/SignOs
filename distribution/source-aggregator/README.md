# Cloudflare IPA 软件源

免费 Worker + SQLite Durable Object 保存订阅、版本、提取的应用图标及任务；Cron 每小时检查一次。IPA 只从原始 URL 读取 Range 片段，用户下载直达原站。客户端最低 iOS 17。

```sh
cd distribution/source-aggregator
npm ci
npm test
cd ../..
python3 scripts/cloud_source.py deploy --plan
python3 scripts/cloud_source.py deploy
python3 scripts/cloud_source.py status
```

部署复用本机 Wrangler 登录，私有管理凭据保存到 `~/.config/signos-source-aggregator/credentials.json`（0600）。不要提交此文件。管理 Token 写入 Worker Secret。默认使用公开 GitHub API；需要增加 GitHub 限额时，应另行授权并配置专用的只读 GitHub Token，不能自动上传本机登录凭据。用户明确授权后，可运行 `python3 scripts/cloud_source.py configure-github` 将本机 GitHub Token 写入这个 Worker 的 Secret，解决匿名 API 限流。

新服务不使用旧 `yao-app-source` Worker 或 R2。

公开入口为 `/sources/yao.json`，兼容 `/source.json`、`/appstore`；`/health` 为探针。管理接口使用 `Authorization: Bearer <管理 Token>`。新增与配置编辑需携带 `/api/catalog` 的当前 `revision`；冲突返回 409。Token 轮换后旧 Token 立即失效，CLI 的私有凭据也需更新。

GitHub 订阅按 Release 发布时间从新到旧查找，在 tag 前缀、预发布及 IPA 文件名匹配规则内选择最新含匹配 IPA 的 Release。只有 APK、没有附件或 IPA 文件名不匹配的版本会跳过；选定版本包含多个匹配 IPA 时仍要求选择或收紧规则，不会退到更旧版本。扫描最多 10 页、每页 100 条；超出扫描或响应限额仍明确报错。

直接 IPA 地址订阅首次成功解析后，地址未变的手动同步、重试和每小时自动同步只检查文件是否可访问：优先 `HEAD`，服务器返回 405/501 时改用 `GET Range: bytes=0-0`，收到响应后立即取消正文，兼容忽略 Range 的文件服务器。不会比较 ETag 或文件大小来重新解析，现有版本、图标、SHA-256 和历史保持不变；文件失效时报告失败并保留已发布包，临时故障沿用重试机制。首次订阅或当前包地址与配置地址不同，仍完整解析元信息与图标。同一地址的内容替换不会自动更新源中的版本信息。

2026-10-11 已部署此行为，40 项服务回归通过；线上立即同步后，哔哩哔哩检查成功且原解析记录、当前包和历史完整保留，其余仓库同步也成功。真实 HTTPS 清单、IPA HEAD 与单字节 Range 下载的结果见 [验收记录](../../docs/plans/evidence/url-availability-sync-20261011.json)。

软件源使用 iOS 27 App Store 图标；公开清单中的图标 URL 带资源版本，客户端刷新源时会更新已保存的图标 URL。资源出处及更新方式见 [assets/README.md](assets/README.md)。

旧客户端使用 `/sources/yao.json?legacy=1`，只返回标记为默认的原有应用变体，避免同 Bundle ID 的签名/未签名包被混用。旧家中 HTTPS 入口在迁移验收后以 302 指向这份兼容清单，旧文件留存用于回退。

最新包迁移使用 `python3 scripts/migrate_cloud_source.py --plan` 和对应实际命令，每个应用只读 `versions[0]`，不导入原历史记录。该工具是原始归档迁移工具；当前仓库订阅已建立，重跑迁移时加 `--skip-bundle com.signos.app --skip-bundle vip.loock.codexmobile --skip-bundle tech.zh0ngtian.MuseumMuse`，避免另建归档订阅。图片和展示信息保留，元信息始终由 Range 解析产生。

2026-10-11 按用户要求，除哔哩哔哩保留固定 IPA URL 外，其余应用均订阅各自的正式 GitHub 仓库，沿用每小时 Cron：

| 应用 | 仓库 / 来源 | tag 前缀 | IPA 匹配 | 包含预发布 |
| --- | --- | --- | --- | --- |
| SignOs | `zh0ngtian/SignOs` | `v` | `SignOs.ipa` | 否 |
| Codex Mobile | `zh0ngtian/codex-mobile` | 无 | `CodexMobile-*-unsigned.ipa` | 否 |
| 博物女神 | `zh0ngtian/DailyMusuem` | `build-` | `MuseumMuse-unsigned.ipa` | 是 |
| Bangumi | `czy0729/Bangumi` | 无 | `bangumi_*.ipa` | 否 |
| 哔哩哔哩 | 原固定 IPA URL，`kind=url` | — | — | — |

SignOs 原订阅已就地从 `ipa-archive` 切换到正式仓库，当前版本为 1.0.11（12）；保留订阅 ID、旧客户端默认标记和原 1.0.10 签名包历史。正式仓库的 IPA 未经分发签名，安装前由客户端签名。其他三个仓库订阅已核对最新匹配附件，哔哩哔哩的配置、当前包和历史均保持原样。普通/兼容清单、图标 HTTPS 接口与 SignOs 全包 SHA-256 验收见 [记录](../../docs/plans/evidence/repository-subscriptions-20261011.json)。固定本地 OTA 渠道独立于正式仓库订阅。

博物女神的持续订阅已于 2026-10-11 从迁移归档切换到公开仓库
`zh0ngtian/DailyMusuem`：tag 前缀 `build-`，附件精确匹配
`MuseumMuse-unsigned.ipa`，包含预发布，保持启用。现有每小时 Cron 继续检查
该仓库的新 Release；原订阅 ID、旧版兼容标记与 1.1.2 历史包保留。
当次已核验 1.1.3（9）的公开下载、完整 SHA-256 和普通/兼容软件源入口，见
[验收记录](../../docs/plans/evidence/museum-release-tracking-20261011.json)。
`migrate_cloud_source.py` 是原始迁移工具，仍使用归档规则；重跑旧源迁移时应加
`--skip-bundle tech.zh0ngtian.MuseumMuse`，避免另外创建归档订阅。

`scripts/publish_signos.py` 是原有双渠道签名包发布工具，仍会创建或更新 `ipa-archive` 订阅，不用于当前正式仓库主订阅的更新。仅在用户另行明确要求新增签名包渠道时使用：先按项目 OTA 流程发布正式签名包，再用 `scripts/publish_signos.py --ipa <同一签名包> --release-json <OTA凭证> --plan` 预检后执行实际发布。工具公开归档到 GitHub，再核对 Cloudflare 的版本、构建号、URL、大小和全包 SHA-256；GitHub 完整 GET 也必须匹配 OTA 凭证。常规交付仍采用 GitHub 构建检查，不自动发布 App。

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

Range 支持 ZIP64、binary/XML plist、Store/Deflate、最大 ZIP 注释和中央目录补读；限制中央目录 4 MiB、plist 解压 512 KiB。忽略 Range 的响应会立即取消。CRC-32 只证明 plist 完整性；公开全包 SHA-256 必须与 GitHub Release 附件的 `digest`、大小一致。

首次解析与后续更新直接从同一 IPA 提取主应用图标，优先读取 plist 指定的独立 PNG，支持 iOS CgBI；否则读取主应用的 `Assets.car`。CAR 按逻辑主图标名称选择正常 iPhone 变体，支持 ARGB/GA8 的未压缩、gzip、LZFSE 和 KCBC 分块，解码器与构建方式见 [vendor/lzfse/README.md](vendor/lzfse/README.md)。不会把扩展、备用图标或无关大图当作应用图标。

图标转换为最长 256 像素、至多 96 KiB 的标准 PNG，保存在 Durable Object，以 `/app-icons/<PNG-SHA256>.png` 提供公开 GET/HEAD 和条件缓存。提取图标优先于旧展示配置；应用图标不会改动软件源自身的 App Store 图标。已存在 GitHub 订阅在下一次同步补齐提取结果；同一 IPA 的补齐不增加历史版本、不丢失已验证全包 SHA-256。直接 IPA 地址未变时只检查可访问性，不补解析图标。首次图标解析失败不公开，更新失败保留原版本并报告 `ICON_EXTRACTION_FAILED`；无需旧源迁移或本机提取服务。

PNG/CgBI 解压在预期扫描行长度之外保留 64 KiB 的有界缓冲余量，兼容 Workers 同步 zlib 的缓冲增长；解压后仍严格校验实际长度，拒绝多余像素数据。图标失败的 `details` 分别保留 PNG 和 CAR 原因，避免 CAR 限额覆盖最初的 PNG 错误。`npm test` 包含真实 workerd 运行时的多 IDAT、120/256 像素 PNG/CgBI 与超长输出回归。

2026-10-11 已部署并核验哔哩哔哩 3.20.1（82300200）恢复同步成功，直接提取 `icon.png`，原 IPA SHA-256 与历史保持不变；普通/兼容清单、HTTPS 图标 GET/HEAD/条件缓存及手机同步状态均通过。部署版本与当次结果见 [验收记录](../../docs/plans/evidence/bilibili-icon-fix-20261011.json)。

独立 PNG 的 ZIP 压缩输入限制为 2 MiB、解压后 4 MiB；CAR 分别为 8 MiB、16 MiB。位图最大 2048×2048。IPA 主图标超过限额或所有候选编码均不支持时会明确失败。回归覆盖独立 PNG、CgBI、CAR 逻辑图标选择、分块 LZFSE、损坏输入、首次公开、HTTPS 图标路由、更新失败保留，以及不变 IPA 的图标补齐。

任务每次 Alarm 处理一个 IPA，最多三次临时故障重试。订阅修改会使旧修订任务失效。首次失败不公开；更新失败保留旧版本。每个订阅最多保存当前版本和 20 个历史版本。暂停不会删除已发布数据。
