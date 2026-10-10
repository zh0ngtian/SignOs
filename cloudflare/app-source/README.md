# Yao App Source on Cloudflare

已部署：`https://yao-app-source.305301890.workers.dev/source.json`。
`/appstore` 是同一 JSON 的兼容入口。R2 bucket 为 `yao-app-source`，保持私有；
Worker 只开放清单和 `files/*.ipa` / `files/*.png` 的 GET、HEAD。

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
WRANGLER_COMMAND="node cloudflare/app-source/node_modules/wrangler/bin/wrangler.js" \
python3 scripts/app_source.py --config cloudflare/app-source/source.config.json sync
```

## 后续发布

仍使用 `scripts/app_source.py ... publish --ipa ... --sha256 ... --icon ...
--developer ... --description ... --notes ...` 生成清单，然后执行 `sync`。
IPA 原样保存、不重签名；摘要计算和本机复制均采用分块 IO。

超过 300 MiB 的文件使用 `sync --transport s3`；需安装 `rclone`，并将只授权目标
bucket 的 R2 S3 凭据设为 `AWS_ACCESS_KEY_ID` 和 `AWS_SECRET_ACCESS_KEY` 环境变量。
凭据不要写入仓库。此方式以 16 MiB 分片上传，64 MiB 以上自动切换 multipart。
当前 Wrangler OAuth 登录不能替代 S3 凭据。

发布是单个发布机上的串行操作；不要从多台机器并发覆盖 `source.json`。
先验证文件、后更新清单；历史文件不会被 sync 删除。清理历史 IPA 时需同步删除
清单中的对应版本，且不能删除仍被当前版本引用的文件。

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
超过 300 MiB 文件的 S3 上传路径尚未配置凭据或实测。
