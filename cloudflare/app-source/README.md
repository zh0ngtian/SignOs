# Yao App Source on Cloudflare

已部署：`https://yao-app-source.305301890.workers.dev/source.json`。
`/appstore` 是同一 JSON 的兼容入口。R2 bucket 为 `yao-app-source`，保持私有；
Worker 只开放清单和 `files/*.ipa` / `files/*.png` 的 GET、HEAD。

## 软件源图标

源图标使用 iOS 27 App Store 图标，仓库副本为
[`assets/app-store-ios27.png`](assets/app-store-ios27.png)（512 × 512）。
素材来自 [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:App_Store_Logo_(iOS_27).webp)，
页面署名 Apple Inc.、标注 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)；
仅将原始 WebP 转为 PNG。

清单顶层 `iconURL` 和 `sourceicon` 均指向
`https://yao-app-source.305301890.workers.dev/files/84960d13a202a74b211d.png`，
PNG SHA-256 为 `84960d13a202a74b211dd5a4ef7116cbf761b15d177bdfc10de7239ef5822f01`。
应用条目各自的图标保持独立，后续 `publish` 会保留源图标。
替换源图标时，先核对本机与公网清单一致，再上传并核验新摘要命名的 PNG，
最后仅更新上述两个顶层字段并核验 `/source.json` 和 `/appstore`。
此操作无需重新部署 Worker 或发布客户端。

2026-10-11 已核验两个公网清单入口与 PNG 完整 SHA-256，并在 iPhone 17 Pro
模拟器（iOS 26.5，SignOs `1.0.2-debug (3)`）重新添加该源，确认新图标及四个应用
正常显示。1.0.5 及更早客户端的源卡片读取添加时保存的 `AltSource.iconURL`，
刷新清单不会更新这个持久化字段，已有源需移除后重新添加才能显示新源图标。
从 1.0.6 (7) 起，成功刷新清单会在主线程同步并保存源图标地址；首页和搜索中的
已有源随之更新，重启后保留。沿用添加源时的图标回退规则（源图标缺省时使用
首个应用图标）；获取失败时保留已保存的图标，无需移除或重新添加源。

2026-10-11 在 iPhone 17 Pro / iOS 26.5 模拟器验证 `1.0.6-debug (7)`：
已有测试源拉取新清单后从旧图标切换为 App Store 图标，数据库记录保持同一条；
停止测试源服务并重启客户端后，显示刷新失败但保留新图标。自动化下拉手势未能
触发，本次通过启动时共用的 `fetchSources` 路径验收；未在真机安装验证。

## 部署

前提：Cloudflare 账户已开通 R2，并完成 `wrangler login`。
在此目录 `npm install`，再执行：

```sh
npx wrangler r2 bucket create yao-app-source
npm test
npm run deploy
```

以下脚本命令均在仓库根目录运行。首次迁移已完成；原服务目录已移除，无需再执行：

```sh
python3 scripts/app_source.py --config cloudflare/app-source/source.config.json migrate \
  --from-root "$HOME/Library/Application Support/YaoAppSource/public"
```

清单和发布文件保存在 Git 忽略的 `packages/app-source/public`，不是常驻服务。
部署 Worker 后上传资源，逐个核对公网字节摘要，最后更新清单：

```sh
source "$HOME/.config/yao-app-source/remote-publisher.env"
WRANGLER_COMMAND="node cloudflare/app-source/node_modules/wrangler/bin/wrangler.js" \
python3 scripts/app_source.py --config cloudflare/app-source/source.config.json sync
```

## 后续发布

开发者字段使用 GitHub 用户名：本人的署名为 `zh0ngtian`，不再使用 `Yao`。
Codex Mobile 显示 `loock-ai / zh0ngtian`，博物女神显示 `zh0ngtian`；
第三方应用保留其原开发者署名。软件源名称仍为 Yao App Source。

仍使用 `scripts/app_source.py ... publish --ipa ... --sha256 ... --icon ...
--developer ... --description ... --notes ...` 生成清单，然后执行 `sync`。
IPA 原样保存、不重签名；摘要计算和本机复制均采用分块 IO。

超过 300 MiB 的文件使用 `sync --transport s3`；需安装 `rclone`，并将只授权目标
bucket 的 R2 S3 凭据设为 `AWS_ACCESS_KEY_ID` 和 `AWS_SECRET_ACCESS_KEY` 环境变量。
凭据不要写入仓库。S3 对大于 8 MiB 的文件使用 8 MiB 分片，每个文件最多
4 个分片并发；不同新增文件默认最多 4 个同时上传。
当前 Wrangler OAuth 登录不能替代 S3 凭据。无论 IPA 使用 S3 还是 Wrangler
上传，sync 的云端锁、容量检查及维护状态读写都必须有上述 S3 凭据。

### SignOs 标准发布步骤

SignOs 的软件源开发者署名使用 GitHub 用户名 `zh0ngtian / ihateios`，当前维护者在前，由专用发布脚本维护。App 设置页及“关于”页保留原作者在前，显示 `@ihateios / @zh0ngtian`；Feather 团队继续在“关于”页单独致谢。

每次 SignOs 客户端发版都必须完成本机 OTA 和本软件源两个渠道；软件源使用
OTA 已成功发布的同一签名 IPA，不再签名，也不使用 `packages/SignOs.ipa`
临时构建包。先完成构建、检查、提交与 push 和 OTA 发布，再执行下面两步。
以下为 `1.0.1 (2)` 示例，后续替换为本次正式 IPA 和对应 OTA 发布凭证：

```sh
python3 scripts/publish_signos.py \
  --ipa packages/SignOs-1.0.1-AdHoc.ipa \
  --release-json packages/SignOs-1.0.1-release.json --plan

source "$HOME/.config/yao-app-source/remote-publisher.env"
python3 scripts/publish_signos.py \
  --ipa packages/SignOs-1.0.1-AdHoc.ipa \
  --release-json packages/SignOs-1.0.1-release.json
```

`--release-json` 接受 OTA 生成的 `latest-ios.json` 或其原样保存副本。
`--plan` 只读核对包与凭证；不是在线权限或上传验收。正式命令默认使用 S3，
从凭证沿用版本、构建号、日期和更新说明，保留其他应用及最近 10 个版本；先上传并
校验新增或变更资源的完整 SHA-256、检查已校验历史资源，再更新并核验公网 `source.json`。可通过
`--transport wrangler` 使用已登录的 Wrangler（命令配置同上）。
发布凭证必须来自成功的 OTA 发布；该命令核对其对应字节，不替代 OTA 独立验签。

### 增量校验与并行上传

`sync` 和 `publish_signos.py` 默认使用 `--upload-workers 4`，允许 1–8；
设为 1 可串行上传文件。此参数控制文件并发，S3 单文件分片并发固定为 4。
已存在的远端对象不会重复上传。所有资源上传和必要校验完成后才切换清单，
任一上传或校验失败均保留原公网清单。

完整下载并通过 SHA-256 校验后，在发布目录保存 `.verified-files.json`。
后续只有本地文件摘要/大小、R2 对象 ETag/大小和公网 HEAD 的 ETag、大小、
Last-Modified 都与记录一致时，才跳过文件下载；每次仍核验最终公网清单。
记录按服务器、bucket 和账户隔离，不将 ETag 当作 SHA-256。
首次没有记录、记录损坏、对象发生变化或远端缺少可靠响应头时，仍完整下载校验。
记录按文件及时保存，发布中途失败后可复用已成功校验的文件。

添加 `--verify-all` 可忽略记录并强制完整下载全部引用资源，例如：

```sh
python3 scripts/app_source.py --config cloudflare/app-source/source.config.json \
  sync --transport s3 --upload-workers 4 --verify-all
```

因此旧的 183 MB 安装包在首次建立校验记录后，正常发布只需一次 HEAD，
不再每次完整下载。运行中的旧发布进程不会自动切换到新逻辑。

只有两个渠道的在线版本、构建号、IPA 摘要一致才算发版完成。软件源失败时
修复后重试同一命令；不要为重试软件源重新签名、递增版本或删除历史 OTA 包。
发布前恢复最新清单及引用资源；publish 保存本机 .publish-base.sha256，
sync 在云端锁内核对基线。若线上清单已变化，应在新工作目录恢复并重新准备，
不要通过删基线强行覆盖。失败后可保留同一目录重试。

发布入口回归检查：

```sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

## 版本保留、容量预算与自动清理

- 每个应用最多保留 **10 个版本**：当前版本必保留，其余按 `date` 取最新的 9 个。
  发布时及每日清理时都会裁剪清单；回滚后的当前版本也不会被裁掉。
- 无引用的 `files/*.ipa`、`files/*.png` 首次被标记后至少保留 **7 天**，再由云端删除。
  时钟从退出清单/首次发现无引用开始，不使用原始上传日期；重新引用或重新上传会重置。
  源图标、所有应用及保留版本的引用一起计算，共享文件不会误删。
- Worker Cron 为 `0 20 * * *`（UTC），即每天**北京时间 04:00**，不依赖本机开机。
  首次创建或修改 Cron 可能需要约 15 分钟传播。
- 发布前计算全桶现有字节、新增资源、清单增长、清单备份和 1 MiB 维护余量；
  超过 **8,000,000,000 字节（8 GB）**便停止上传。七天宽限期内的旧文件也占预算。
  10 个 300 MB 包约 3 GB/应用，多个应用或短期密集发版仍可能触及预算。
  此限制不是 R2 硬配额；其他桶、绕过脚本的写入及账户其他费用不在保护范围内。
- 修改清单前保存私有备份 `_maintenance/manifests/`；GC 状态为 `_maintenance/gc.json`，
  最近一次成功执行报告为 `_maintenance/last-run.json`。HTTP 不开放这些路径。
- 发布与清理共享原子锁 `_maintenance/lock.json`。锁忙时清理跳过，发布失败并提示重试。
  锁不自动过期，防止长时间上传期间被误删。若进程异常中断，先通过 S3 查看锁的
  `owner`、`kind`、`startedAt`，确认持有者及上传子进程已停止，再由运维删除该锁；
  不可仅因为锁存续较久就抢锁。正常成功或失败会在 finally 中释放锁。
- 所有发布机都须更新仓库并遵循 [跨机器发布 Prompt](PUBLISH_PROMPT.md)。直接使用
  S3/Wrangler 修改清单会绕过互斥和预算保护；源图标等维护也须在同一云端锁内进行，
  先上传核验资源，再更新清单，并清除新引用资源的旧 GC 标记。
- 只清理云端退役资源；本地历史签名包、OTA 包、发布凭证、兼容基线继续保留。

回归检查：`node --test cloudflare/app-source/test/*.test.mjs`（需本机 Workers 运行时可启动）
和 `python3 -m unittest discover -s Tests -p 'test_*.py'`。

2026-10-11 验证：10 项 Worker/R2 回归与 11 项 Python 回归通过；远程预览使用
生产 R2 执行 scheduled handler 成功，未删除文件，并标记 1 个未引用资源进入
七天宽限期。发布持锁期间再次触发清理，返回 busy，验证两端互斥生效。

同日完成正式部署，Worker 版本 `82739c61-3abb-4573-b665-109eef588632`，
已配置每日 Cron。合并增量校验规则后 20 项 Python 回归通过。公网清单、
`/appstore`、HEAD、206/416、304、私有路径 404 和写入 405 均通过；
8 个保留 IPA 的 HEAD 大小一致，博物女神 `1.1.2 (8)` 完整下载 SHA-256 一致。
桶占用约 278 MB，当前无版本超出保留上限；额外的历史包全量下载已停止，
发布锁正常释放，本次没有发布新 IPA。

Cron 与条件写入依据：[Cron Triggers](https://developers.cloudflare.com/workers/configuration/cron-triggers/)、
[R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)。

## 下载行为与验证

- 清单 `no-store`；内容摘要命名的 IPA、图标缓存一年。
- R2 内容直接流式返回，支持单段 Range、If-Range、HEAD 和 ETag。
- Worker 没有公网写入入口。无登录页、无浏览器验证。
- 本机运行 `node --test cloudflare/app-source/test/*.test.mjs`。
- 上线应验证清单、图标、IPA SHA-256、206/416、HEAD、304、404/405。
- SignOs 以源 URL 关联应用：旧局域网源删除后添加新地址，并通过新源下载、签名
  覆盖原应用以建立新来源。覆盖安装沿用原签名身份，不卸载目标应用。
- 大文件上线前还需真机验证网络切换后的续传、解压与签名空间。

2026-10-10 云端验收通过后，已移除本地软件源的 LaunchAgent、配置、日志和服务目录。
原始 IPA 与图标保留在 `packages/app-source/public`，迁移前清单保留为
`packages/app-source/migration-original-source.json`。
SignOs 自身 OTA 渠道及共用签名/TLS 材料不属于本服务，不应删除。

同日真机验收：在用户准备好的网络下，SignOs 成功添加新源并加载图标；
通过版本历史重新下载 Codex Mobile `0.2.140 (2140)`，Cloudflare 记录清单、
图标和 IPA 请求均为 200。下载后自动签名，签名记录的来源已变为新源 URL；
覆盖安装完成后应用正常打开，原有 `mac_pc` 连接仍可用。
此前 Wi-Fi 环境访问曾超时，此结果只证明本次可用网络下通过；未进行大 IPA
或真机跨网络续传测试。服务端 Range/If-Range 续传及完整 IPA SHA-256 已验证。
同日已创建 `yao-app-source-remote-publisher` R2 Account API 令牌，仅授权
`yao-app-source` 的对象读和写；已验证读取清单及临时对象上传、读取、删除。
本机凭据保存在仓库外 `~/.config/yao-app-source/remote-publisher.env`（权限 0600），
包含 `AWS_ACCESS_KEY_ID` 和 `AWS_SECRET_ACCESS_KEY` 的 export 声明。
在受信任发布机安全放置该文件后，可先 `source` 此文件，再执行
`sync --transport s3`，无需 Wrangler 登录。不要提交或打印密钥。
大 IPA 与 S3 multipart 上传尚未实测。
