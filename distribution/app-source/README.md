# Yao App Source：跨机器上传 IPA

当前软件源入口为 `${APP_SOURCE_BASE_URL}/source.json`，实际地址由私有环境变量提供。
普通应用可以直接上传 IPA，不必 SSH 到家中服务器，也无需 Cloudflare/R2 凭据。
这个目录保留跨机器上传器和旧 Cloudflare 工程；Cloudflare 入口、预览及 Cron 继续停用，
`source.config.json` 的 `disabled: true` 不应移除，旧 R2 私有历史文件保留。

## 使用上传器

需要 Python 3.11+ 和管理员提供的单个共享 token；将 token 保存到私有文本文件，
不要写入仓库。将管理员提供的地址配置为 `APP_SOURCE_BASE_URL`，可在自己的私有
环境文件中设置。这里不提供真实域名或默认地址。先加载私有环境，再检查文件并上传：

```sh
set -a
. /private/path/app-source.env
set +a
python3 distribution/app-source/upload_ipa.py --ipa /path/app.ipa --plan
python3 distribution/app-source/upload_ipa.py \
  --ipa /path/app.ipa --token-file /private/path/upload-token \
  --developer 'Your name' --description '应用说明' --notes '更新说明'
```

也可使用 `--url` 指定完整 HTTPS 上传地址，或设置 `APP_SOURCE_UPLOAD_TOKEN` 环境变量代替 token 文件。`--plan` 不读 token、不发送请求。
上传器检查 HTTPS 证书，按块传输原始 IPA，发送大小和完整 SHA-256，核对响应中
相同的大小、摘要。成功后应用自动出现在 `/source.json` 和兼容入口 `/appstore`。
单包上限 2 GiB；包内名称、bundle ID、版本、构建号由服务器读取，无需手写清单。
有普通 PNG 图标时读取包内图标，否则使用默认图标。不会重新签名。

所有 token 持有人使用同一权限，可以发布普通应用及其更新；没有独立账号或每应用
所有权限制。开发者/描述可省略，已有应用沿用旧值，新应用默认开发者 Community。
每个应用清单保留最多 10 个版本；历史文件暂不删除，公开文件总预算为 8 GB。

## HTTP 协议

- 地址：`POST ${APP_SOURCE_BASE_URL}/api/upload`
- 认证：`Authorization: Bearer <token>`；token 不接受放在 URL 中。
- 类型：`Content-Type: application/octet-stream`
- 请求体：完整 IPA 原始字节，**不是 multipart**，必须发送 `Content-Length`。
- 可选摘要：`X-IPA-SHA256: <64 位十六进制摘要>`。
- 可选查询参数：`developer`、`description`、`notes`，各最多 2000 字符，UTF-8 URL 编码；编码后的查询参数合计不超过 8 KiB。

已有 curl 的机器也可以上传（token 从私有文件读取）：

```sh
read -r upload_token < /private/path/upload-token
curl --fail-with-body \
  -H "Authorization: Bearer $upload_token" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @/path/app.ipa \
  "${APP_SOURCE_BASE_URL}/api/upload?developer=Your%20name"
unset upload_token
```

成功返回 201 和 JSON 发布凭证：`sourceURL`、`bundleIdentifier`、`version`、
`buildVersion`、`downloadURL`、`size`、`sha256`、`duplicate: false`。
同 bundle/version/build、同摘要的重复上传返回 200、`duplicate: true`，不修改已有
元数据或当前版本；若摘要不同返回 409，请递增构建号。凭证中的下载地址仍为家中 HTTPS。

| 状态 | 含义与处理 |
| --- | --- |
| 400 / 411 / 415 | IPA、元数据或请求格式非法；改正后重试 |
| 401 | token 缺失或不正确 |
| 403 | SignOs 必须使用带 OTA 凭证的正式发布器 |
| 409 | 同版本不同内容，或服务器有未完成的本机发布 |
| 413 / 422 | 包超过 2 GiB，或 SHA-256 不匹配 |
| 502 / 503 | 发布校验失败，或两个上传名额已满；稍后重试 |
| 507 | 磁盘空间不足，或超过公开文件 8 GB 预算 |

发布先验证 IPA，再复制资源并通过真实 HTTPS 校验，最后原子切换清单。失败保留
旧清单、恢复准备目录；同一包可以重试。上传不验证签名可安装性，安装仍取决于 IPA
本身的签名、设备与分发条件。服务部署、token 路径、轮换、续期和验收见
[家中服务说明](../../hosting/home-source/README.md)。

## SignOs 正式发布与历史工程

SignOs 自身继续先完成本机 OTA，再把同一签名 IPA 与发布凭证交给服务器：

```sh
python3 scripts/publish_signos.py --ipa /private/path/signed.ipa --release-json /private/path/release.json --plan
python3 scripts/publish_signos.py --ipa /private/path/signed.ipa --release-json /private/path/release.json
```

原 Worker 的 `src/`、测试、Wrangler 配置及 R2 文件仅作为历史记录。
普通应用上传不执行 `wrangler deploy`、`rclone sync` 或旧云端发布流程。
