# 家中软件源

唯一公开入口：`https://${APP_SOURCE_DOMAIN}:15006/source.json`，`/appstore` 返回相同清单。
软件源保持 `tech.zh0ngtian.yao-app-source` 身份，IPA 原样保存，不重新签名。
Cloudflare Worker 的 workers.dev、preview URL 和 Cron 已停用；R2 私有历史文件保留。

## 服务与目录

- 路由器 TCP `15006` → Mac mini `192.168.123.79:15006`，Mac mini 有 DHCP 静态绑定。
  Padavan 虚拟服务器名为 `signos-source`，NVRAM 持久化，NAT 规则在兜底 DMZ 前。
- Docker 容器 `signos-home-source` 使用 Nginx，`unless-stopped` 自动重启。
  依赖现有 Colima/Docker 和用户登录会话；本机须在线且不休眠。
- 只开放 GET/HEAD `/source.json`、`/appstore`、`/files/<name>.ipa|png`。
  其他路径 404，无目录索引。清单不缓存；带版本/摘要的资源长期缓存，支持
  HEAD、Range、If-Range、ETag。
- `packages/home-source/staging/` 是发布准备目录，`packages/home-source/public/`
  是实际服务目录；仅后者只读挂载到容器。`packages/home-source/manifests/`
  和 `verified-files.json` 保存旧清单及校验凭证，不公开。
- 旧 `packages/app-source/public/`、OTA 包、签名材料和发布凭证保留。
- 公网 DNS 由路由器已有腾讯云 DDNS 更新。DNS-01 自动续期只管理验证 TXT，
  不修改 `home` 的 A 记录，也不更改路由器 DDNS。

## 标准发布

正式发布在家中服务器的仓库根目录执行，默认配置
`hosting/home-source/source.config.json`。SignOs 先完成独立的本机 OTA，再将
同一正式签名包及发布凭证交给软件源发布器：

```sh
python3 scripts/publish_signos.py \
  --ipa /private/path/signed.ipa --release-json /private/path/release.json --plan
python3 scripts/publish_signos.py \
  --ipa /private/path/signed.ipa --release-json /private/path/release.json
```

默认 backend 为 home、transport 为 local，不访问 Cloudflare，也无需 R2 凭据。
通用应用继续使用 `app_source.py publish` 的 IPA、SHA-256、PNG 图标、开发者、
描述、更新说明等参数，但配置改为 `hosting/home-source/source.config.json`；准备后执行：

```sh
python3 scripts/app_source.py --config hosting/home-source/source.config.json sync
```

其他机器先复制新包、图标和凭证到家中服务器，然后在服务器运行上述命令。
不要覆盖服务器现有清单或已有版本目录。配置的相对路径按仓库根目录解释。
原 `cloudflare/app-source/source.config.json` 已标记 disabled，发布器拒绝向它发布。

### 原子切换与失败重试

发布持有本机文件锁，核对准备阶段的清单基线，拒绝旧工作副本覆盖新版本。
清单每个应用最多保留 10 个版本，当前版本始终保留。所有本地 IPA 核对大小和完整
SHA-256；新增资源先复制，再从 HTTPS 下载验证，已有可信凭证且内容未变的资源
做 HEAD 大小检查，最后原子切换清单并检查两个入口。失败保留或回滚旧清单。

历史资源暂不自动删除，发布前按公开目录总占用和新增文件检查 8 GB 预算；
达到预算时停止发布。旧清单备份、私有日志及其他目录不计入此预算。

私有 `~/.config/yao-app-source/home-source.json` 使用 `mode: primary`，配置
`sourceRoot`（staging）、`root`（public），两个 base URL 均为家中入口。
失败后无需重签名、递增版本或重发 OTA，只重试：

```sh
python3 scripts/home_source.py --plan
python3 scripts/home_source.py
# 独立全量审计
python3 scripts/home_source.py --verify-all
```

## 部署

私有 `~/.config/yao-app-source/home-source.env` 包含公开文件目录
`HOME_SOURCE_ROOT` 和独立 ACME 根目录 `HOME_SOURCE_CERTIFICATES`。

```sh
docker-compose --env-file "$HOME/.config/yao-app-source/home-source.env" \
  -f hosting/home-source/compose.yaml run --rm --no-deps source nginx -t
docker-compose --env-file "$HOME/.config/yao-app-source/home-source.env" \
  -f hosting/home-source/compose.yaml up -d
```

## 证书自动续期

使用 Let's Encrypt 的公开可信证书，无需在手机安装 CA。仅为软件源配置独立
`${APP_SOURCE_DOMAIN}` 证书；原 glkvm/Certbot 目录和其他服务的证书保持原状。

私有文件均在 `~/.config/yao-app-source/`：

- `renewal.json`：域名、ACME 账户邮箱、固定摘要的 lego 5 镜像、Docker 路径等。
- `dns-renewal.env`：腾讯云 DNS API 凭据，权限 0600，不进仓库或命令行参数。
- `acme/`：正式 ACME 账户、证书和私钥；`acme-staging/` 是隔离的测试环境。
- `acme/backups/`：更新前证书记录，保留以便恢复。
- `renewal-status.json`、`renewal-staging-status.json`、`renewal.log`：最近状态和日志。

`local.yao-app-source.renew-tls` LaunchAgent 登录时运行、之后每 12 小时检查；
失败按 launchd 策略约 1 小时后重试。剩余 30 天开始续期（ACME 服务也可通过 ARI
建议续期时间）。DNS 验证记录由 lego 自动创建并清理，不需要开放 80/443。
当前网络的本地 DNS 预检查存在缓存不一致，私有配置使用 lego 支持的 60 秒传播等待，
随后由 Let's Encrypt 实际验证 TXT；不关闭 HTTPS 校验或 CA 域名验证。
只有证书成功取得且 Nginx 配置检查通过才重载；随后真实 TLS 握手核对线上证书摘要。
如果证书已更新但上次重载失败，下次检查仍会补做重载。

```sh
# 测试环境实际签发/强制续期，不改生产证书、不重载生产服务
python3 scripts/renew_home_tls.py --staging-test
# 正式签发或续期，并按需重载
python3 scripts/renew_home_tls.py
# 安装本机系统任务
python3 scripts/install_home_renewal.py --plan
python3 scripts/install_home_renewal.py
launchctl print "gui/$(id -u)/local.yao-app-source.renew-tls"
```

首次正式签发时先用 `--issue-only`，再部署使用新证书目录的 Nginx。
TLS 配置不会改变手机 Fully Local 安装使用的私有 CA，也不改变 SignOs OTA 签名身份。

## 验证

```sh
python3 -B -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/home_source.py --verify-all
```

2026-10-11 初次家中部署：4 个应用、15 个资源（307,667,097 字节）完整 HTTPS
SHA-256 校验通过，SignOs 为 `1.0.7 (8)`。HEAD、Range、If-Range、ETag、416
和私有路径隔离均验证通过；用户确认蜂窝网络可打开清单。证据保存在
`packages/home-source/acceptance-20261011.json`。未测量蜂窝下载速度或验收重启恢复。

同日改为独立本机发布后再次全量验证，不再读取或上传 Cloudflare。
停用与证书自动续期的本次验收以实际在线检查及私有 renewal 状态记录为准。
