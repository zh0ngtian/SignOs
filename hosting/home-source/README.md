# 家中软件源

唯一公开入口：`${APP_SOURCE_BASE_URL}/source.json`，`/appstore` 返回相同清单。
软件源保持 `tech.zh0ngtian.yao-app-source` 身份，IPA 原样保存，不重新签名。
Cloudflare Worker 的 workers.dev、preview URL 和 Cron 已停用；R2 私有历史文件保留。

## 服务与目录

- 路由器 TCP `15006` → Mac mini `192.168.123.79:15006`，Mac mini 有 DHCP 静态绑定。
  Padavan 虚拟服务器名为 `signos-source`，NVRAM 持久化，NAT 规则在兜底 DMZ 前。
- Docker 容器 `signos-home-source` 使用 Nginx，`unless-stopped` 自动重启。
  依赖现有 Colima/Docker 和用户登录会话；本机须在线且不休眠。
- 下载开放 GET/HEAD `/source.json`、`/appstore`、`/files/<name>.ipa|png`，
  上传开放带 token 的 POST `/api/upload`。
  其他路径 404，无目录索引。清单不缓存；带版本/摘要的资源长期缓存，支持
  HEAD、Range、If-Range、ETag。
- `packages/home-source/staging/` 是发布准备目录，`packages/home-source/public/`
  是实际服务目录；仅后者只读挂载到容器。`packages/home-source/manifests/`
  和 `verified-files.json` 保存旧清单及校验凭证，不公开。
- 旧 `packages/app-source/public/`、OTA 包、签名材料和发布凭证保留。
- 公网 DNS 由路由器已有腾讯云 DDNS 更新。DNS-01 自动续期只管理验证 TXT，
  不修改 `home` 的 A 记录，也不更改路由器 DDNS。

## 私有环境配置

真实域名和入口不放在 Git。服务器私有
`~/.config/yao-app-source/home-source.env`（0600）设置 `APP_SOURCE_DOMAIN` 与
`APP_SOURCE_BASE_URL`；占位示例见 `home-source.env.example`。域名变量只填主机名，
URL 变量填写完整 HTTPS origin（含端口，不含路径）。两个值应指向同一服务。

本机 Python 工具与上传后端会加载这个私有文件，显式进程环境变量优先。
`source.config.json` 只保存 `baseUrlEnv` 变量名；缺少有效地址时直接报错。

Nginx 使用 `nginx.conf.template`，容器启动时只替换 `APP_SOURCE_DOMAIN`，
保留 `$uri` 等 Nginx 变量。修改模板或私有域名后需要重新创建 source 容器；
证书正常续期仍只需重载 Nginx。真实证书文件名由域名变量构造。

## 部署

私有 `~/.config/yao-app-source/home-source.env` 包含公开文件目录
`HOME_SOURCE_ROOT`、独立 ACME 根目录 `HOME_SOURCE_CERTIFICATES`，以及私有
`APP_SOURCE_DOMAIN`、`APP_SOURCE_BASE_URL`。环境文件及真实部署地址不提交到 Git。

```sh
# 先安装/启动上传后端，再检查和部署 Nginx
python3 scripts/install_home_upload.py
docker-compose --env-file "$HOME/.config/yao-app-source/home-source.env" \
  -f hosting/home-source/compose.yaml run --rm --no-deps source nginx -t
docker-compose --env-file "$HOME/.config/yao-app-source/home-source.env" \
  -f hosting/home-source/compose.yaml up -d --force-recreate source
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
SignOs 客户端交付流程见 [构建检查](../../README.md#github-actions-构建检查)。

## 验证

```sh
python3 -B -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/home_source.py --verify-all
```

历史验收记录保存在 `packages/home-source/` 的 `acceptance-20261011.json`、
`retirement-20261011.json` 与 `upload-acceptance-20261011.json`，私有续期状态文件
保存证书核验结果。这些记录是当日快照，不能替代下一次服务或续期验收。
