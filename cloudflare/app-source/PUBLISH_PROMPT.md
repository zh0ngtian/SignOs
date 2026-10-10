# 跨机器 IPA 发布 Prompt

适用于另一台机器通过 R2 S3 凭据向已部署的软件源发布 IPA，无需登录 Cloudflare。
本流程不创建 Worker 或 bucket。运行环境需要 Python 3.11+、rclone 和本仓库。

## 环境变量

发布机预先注入以下变量。本文不包含任何密钥值；不要将密钥写入本文件、聊天或 Git。

| 变量 | 内容 |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | 仅授权目标 bucket 的 R2 S3 Access Key ID |
| `AWS_SECRET_ACCESS_KEY` | 对应的 R2 S3 Secret Access Key |
| `APP_SOURCE_URL` | 软件源完整 HTTPS 地址，必须以 `/source.json` 结尾，无查询参数或片段 |
| `R2_BUCKET` | 已部署 Worker 绑定的 R2 bucket 名称 |
| `CLOUDFLARE_ACCOUNT_ID` | 该 bucket 所属的 Cloudflare account ID，用于生成 S3 endpoint |
| `APP_SOURCE_WORKDIR` | 本次发布的本机工作目录绝对路径；放在 Git 忽略目录或仓库外 |

非密钥变量的配置示例（将占位内容替换为实际值）：

```sh
export APP_SOURCE_URL='https://<软件源域名>/source.json'
export R2_BUCKET='<目标存储桶名称>'
export CLOUDFLARE_ACCOUNT_ID='<Cloudflare account ID>'
export APP_SOURCE_WORKDIR='/绝对路径/本次发布工作目录'
```

当前脚本支持默认 jurisdiction 的 R2 endpoint；其他 jurisdiction 不适用此配置。
软件源地址和 bucket 必须对应同一已部署服务，修改环境变量不会改变 Worker 绑定。

## 交给 Agent 的 Prompt

复制下面整个文本块，填写发布信息。实际操作遵守目标仓库的 AGENTS.md。

````text
请把以下 IPA 发布到环境变量指定的现有软件源，持续执行到公网验收完成。

发布信息：
- IPA：<本机绝对路径>
- PNG 图标：<本机绝对路径；同一应用可复用已有图标>
- 开发者：<GitHub 用户名；本人使用 zh0ngtian，保留上游开发者署名>
- 应用描述：<描述>
- 更新说明：<本次更新说明>
- 若为 SignOs：OTA 发布凭证路径：<对应正式签名包的 release JSON>

仓库：https://github.com/zh0ngtian/SignOs.git
工作目录：使用本机现有仓库；没有则获取仓库。以下命令均在仓库根目录运行。

目标与认证完全来自环境变量：
AWS_ACCESS_KEY_ID、AWS_SECRET_ACCESS_KEY、APP_SOURCE_URL、R2_BUCKET、
CLOUDFLARE_ACCOUNT_ID、APP_SOURCE_WORKDIR。
只检查变量是否存在，不输出密钥，不读取其他浏览器或 Wrangler 登录凭据。
不执行 wrangler login，不将密钥写入配置 JSON、日志、报告或 Git。
缺少变量时只报告缺失的变量名。

一、准备和恢复最新软件源

1. 使用已包含 10 版本保留策略的最新版仓库，阅读 AGENTS.md、
   cloudflare/app-source/README.md 和 scripts/app_source.py。
   确认 Python 3.11+、rclone 可用。IPA 预计不超过 300 MB，仍统一使用 S3。
   不修改服务代码，不重建 bucket，不手工删除云端资源，不重新签名 IPA。
   sync 会将每个应用裁剪为最多 10 个版本（始终保留当前版本），未引用资源由
   云端在退出清单至少 7 天后删除。本地历史包、凭证仍须保留。
2. 标准 sync 会自动获取 R2 云端锁，与其他发布机及每日清理互斥；不要绕过
   发布器用 rclone 直接覆盖清单或删除文件。锁忙时稍后重试，不能强行删锁。
   本机 publish 会保存 .publish-base.sha256；sync 在锁内检查线上基线，
   若源已变化，保留本次输入并在新的工作目录恢复最新清单、重新执行 publish。
   不修改或删除基线文件来绕过冲突。
3. 下载 APP_SOURCE_URL 的最新清单，并通过 S3 读取目标 R2_BUCKET 的
   source.json，确认两者内容一致、sourceURL 与环境变量一致。
   S3 endpoint 为 https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com；
   rclone 使用 --s3-provider Cloudflare --s3-env-auth --s3-no-check-bucket。
   使用 Python 公网请求时设置 User-Agent: YaoAppSourcePublisher/1.0。
4. 使用 APP_SOURCE_WORKDIR 保存本次清单和资源。目录已有未发布变更时先保留，
   不直接覆盖；必要时使用新的工作目录。保留一份发布前清单作为验收基线。
   恢复最新清单到 source.json，确保它引用的全部 IPA、PNG（包括历史版本）
   均存在于 files/。已有本地 IPA 与最新清单的大小、SHA-256 一致时直接复用，
   仅下载缺失或不匹配的文件；保留同目标的 .verified-files.json 校验记录。
   只接受目标源下符合 files/[A-Za-z0-9._-]+\.(ipa|png) 的资源路径，
   拒绝路径穿越或源外下载地址。逐个核对 IPA 大小和清单中的 SHA-256。
   不能用空清单覆盖线上源；现有 sync 会检查并同步全部引用资源，不能只恢复新包。

二、生成环境变量对应的临时配置

现有发布脚本不会自动读取 APP_SOURCE_URL、R2_BUCKET 等目标变量。
在本次工作目录内生成 source.config.local.json，通过 --config 显式传入。
不要修改仓库中 cloudflare/app-source/source.config.json。
临时 JSON 不得包含 AWS_ACCESS_KEY_ID 或 AWS_SECRET_ACCESS_KEY。

生成逻辑如下（必须在完成上面的清单恢复后执行）：

```sh
python3 - <<'PY'
import json
import os
import re
from pathlib import Path
from urllib.parse import urlsplit

source_url = os.environ['APP_SOURCE_URL']
parts = urlsplit(source_url)
if (parts.scheme != 'https' or not parts.hostname or parts.username or parts.password
        or parts.query or parts.fragment or parts.path != '/source.json'):
    raise SystemExit('APP_SOURCE_URL must be https://<host>/source.json')
account = os.environ['CLOUDFLARE_ACCOUNT_ID']
bucket = os.environ['R2_BUCKET']
if not re.fullmatch(r'[a-fA-F0-9]{32}', account):
    raise SystemExit('Invalid CLOUDFLARE_ACCOUNT_ID')
if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket):
    raise SystemExit('Invalid R2_BUCKET')
root = Path(os.environ['APP_SOURCE_WORKDIR']).expanduser()
if not root.is_absolute():
    raise SystemExit('APP_SOURCE_WORKDIR must be absolute')
root = root.resolve(strict=True)
source = json.loads((root / 'source.json').read_text())
if source['sourceURL'] != source_url:
    raise SystemExit('Restored manifest does not match APP_SOURCE_URL')
config = {
    'name': source['name'],
    'identifier': source['identifier'],
    'baseUrl': source_url.removesuffix('/source.json'),
    'root': str(root),
    'bucket': bucket,
    'accountId': account,
}
(root / 'source.config.local.json').write_text(
    json.dumps(config, ensure_ascii=False, indent=2) + '\n'
)
PY
```

三、准备发布

1. 验证 IPA ZIP 完整性，从主应用 Info.plist 读取真实 bundle ID、版本和构建号，
   计算整个 IPA 的 SHA-256，保持原始字节。核对 PNG 图标和发布说明。
2. 同一版本、构建号已在线上存在且摘要不同，报告冲突，不覆盖。
   新包版本低于线上当前版本时先报告，不擅自将软件源当前版本降级。
3. 输出不含密钥的发布计划：目标源、bucket、包身份、版本、构建号、大小、摘要。
   scripts/app_source.py 没有 --plan 参数，不要向它传入不存在的选项。

四、执行发布

普通应用使用现有发布器生成本机清单：

```sh
python3 scripts/app_source.py \
  --config "$APP_SOURCE_WORKDIR/source.config.local.json" \
  publish \
  --ipa "<IPA绝对路径>" \
  --sha256 "<实际SHA-256>" \
  --icon "<PNG绝对路径>" \
  --developer "<开发者>" \
  --description "<应用描述>" \
  --notes "<更新说明>"
```

上传前再次核对线上清单仍与发布前基线一致；如变化，保留本次输入并基于最新
清单重新恢复、合并，不能直接覆盖。sync 会在云端锁内再次核对基线。
容量预算固定为 8,000,000,000 字节，计入全桶现有对象、待上传新资源和维护余量；
包括处于七天宽限期的旧文件。超预算时停止发布并报告，不擅自缩短宽限期、
减少保留版本或手工删除资源。此保护属于标准发布流程，不是 R2 账户硬配额。

```sh
python3 scripts/app_source.py \
  --config "$APP_SOURCE_WORKDIR/source.config.local.json" \
  sync --transport s3
```

若发布 SignOs 本身，遵守项目双渠道规则：先有成功的本机 OTA 发布和对应凭证，
然后使用同一正式签名 IPA。用下面两条命令替代上面的通用 publish/sync，
并在正式命令前完成同样的线上基线检查：

```sh
python3 scripts/publish_signos.py \
  --config "$APP_SOURCE_WORKDIR/source.config.local.json" \
  --ipa "<正式签名IPA>" --release-json "<OTA发布凭证>" \
  --transport s3 --plan

python3 scripts/publish_signos.py \
  --config "$APP_SOURCE_WORKDIR/source.config.local.json" \
  --ipa "<同一正式签名IPA>" --release-json "<同一OTA发布凭证>" \
  --transport s3
```

缺少成功的 SignOs OTA 发布凭证时报告缺项，不用临时构建包代替。
--plan 只核对包与凭证，不代表上传或线上验收成功。

五、验收与交付

- 沿用脚本“资源先上传并逐个校验、清单最后上传”的顺序。
- 核对公网 APP_SOURCE_URL 包含新版本，其他应用未被意外移除；每个应用最多
  10 个版本，当前版本必保留，其余按发布日期取最新的 9 个。
- 核对在线版本、构建号、下载地址、大小和 SHA-256。
  新增、变化或缺少可信记录的资源，由 sync 完整下载并核对 SHA-256。
  对已完整校验的历史资源，只有本地摘要/大小、R2 ETag/大小以及公网 HEAD 的
  ETag、大小、Last-Modified 都匹配 .verified-files.json，才允许跳过下载。
  由发布器判断是否可复用，不将 ETag 当作 SHA-256，不手工伪造校验记录。
  首次没有记录仍须完整下载；每次完整校验成功即保存记录，失败重试可复用。
  默认不传 --verify-all；仅明确需要重验所有文件时才使用它。
- SignOs 还须核对 OTA 与软件源的包版本、构建号、完整 IPA SHA-256 一致。
- 只完成本机 publish、上传 IPA 或执行 --plan 均不算发布完成。
- 保留发布前后清单、.verified-files.json 和不含密钥的验收记录；
  清理无用临时配置与诊断文件，
  不删除历史签名包、发布凭证、仍在使用的资源或设备验收记录。
- 最后报告源地址、IPA 下载地址、版本、构建号、大小、SHA-256 和实际结果。
  失败时明确失败步骤及线上清单是否已更新，不宣称完成。
````
