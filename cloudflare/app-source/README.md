# Yao App Source on Cloudflare

已部署：`https://yao-app-source.305301890.workers.dev/source.json`。
`/appstore` 是同一 JSON 的兼容入口。R2 bucket 为 `yao-app-source`，保持私有；
Worker 只开放清单、`files/*.ipa` / `files/*.png` 和下列两个公开 CA 文件的 GET、HEAD。

## SignOs 本地安装证书

在 iPhone Safari 打开 [CA 安装描述文件](https://yao-app-source.305301890.workers.dev/certificates/signos-ca.mobileconfig)，
安装后到“设置 → 通用 → 关于本机 → 证书信任设置”开启 **Codex Mobile LAN CA** 完全信任。
公网下载不要求与 Mac 处于同一 Wi-Fi；此 CA 用于 SignOs 在手机上提供的本地 HTTPS 安装服务。
描述文件只含现有公开根证书，不含私钥；原 CA、签名材料和 TLS 私钥继续保存在仓库外。
原始 [DER 根证书](https://yao-app-source.305301890.workers.dev/certificates/signos-ca.cer) 同时提供下载。
两个固定入口均 `no-store`，不会由普通 App 发布覆盖。

根证书 SHA-256 指纹：`7C:75:A2:F6:A9:C9:EE:86:98:D5:ED:F9:4C:A1:40:D3:4A:22:67:32:4E:09:37:04:39:B1:1A:CC:98:AE:55:52`。
维护时复用现有 CA，不生成替代 CA；先核对描述文件只包含 `com.apple.security.root`
负载，以及根证书能验证 SignOs 的 `server.crt`。在本目录上传经过核对的公开文件：

```sh
npx wrangler r2 object put yao-app-source/certificates/signos-ca.mobileconfig \
  --file /private/path/signos-ca.mobileconfig --content-type application/x-apple-aspen-config --remote
npx wrangler r2 object put yao-app-source/certificates/signos-ca.cer \
  --file /private/path/signos-ca.cer --content-type application/pkix-cert --remote
```

部署后检查两个 HTTPS URL 的 GET、HEAD、Content-Type 和完整 SHA-256。
系统日志中的 `MissingIntermediate` / TLS `-1200` 且信任列表缺少此 CA 时，先恢复
描述文件与完全信任，再验证安装；重新签名 IPA 不会修复系统 CA 信任。

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

### SignOs 标准发布步骤

SignOs 的软件源开发者署名统一为 `Yao / ihateios / Feather contributors`，由专用发布脚本维护。

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
从凭证沿用版本、构建号、日期和更新说明，保留其他应用及版本历史；先上传并
逐个核验资源 SHA-256，再更新并核验公网 `source.json`。可通过
`--transport wrangler` 使用已登录的 Wrangler（命令配置同上）。
发布凭证必须来自成功的 OTA 发布；该命令核对其对应字节，不替代 OTA 独立验签。

只有两个渠道的在线版本、构建号、IPA 摘要一致才算发版完成。软件源失败时
修复后重试同一命令；不要为重试软件源重新签名、递增版本或删除历史 OTA 包。
单发布机串行执行，并在发布前确认本机清单是最新副本，避免覆盖别处发布的应用。

发布入口回归检查：

```sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

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
同日已创建 `yao-app-source-remote-publisher` R2 Account API 令牌，仅授权
`yao-app-source` 的对象读和写；已验证读取清单及临时对象上传、读取、删除。
本机凭据保存在仓库外 `~/.config/yao-app-source/remote-publisher.env`（权限 0600），
包含 `AWS_ACCESS_KEY_ID` 和 `AWS_SECRET_ACCESS_KEY` 的 export 声明。
在受信任发布机安全放置该文件后，可先 `source` 此文件，再执行
`sync --transport s3`，无需 Wrangler 登录。不要提交或打印密钥。
大 IPA 与 S3 multipart 上传尚未实测。
