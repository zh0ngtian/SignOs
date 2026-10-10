# 家中软件源

入口为 `https://${APP_SOURCE_DOMAIN}:15006/source.json`，`/appstore` 返回相同清单。
使用同一 Yao App Source identifier 和原始 IPA，保持版本、构建号、SHA-256 与
Cloudflare 源一致，只把清单中的资源 URL 改为家中地址。旧 Cloudflare 入口保留。

## 部署结构

- 路由器 TCP `15006` → Mac mini `192.168.123.79:15006`。Mac mini 有 DHCP 静态绑定。
  Padavan 的虚拟服务器配置名为 `signos-source`；持久化在 NVRAM，运行时在
  NAT `vserver` 链内、兜底 DMZ 规则之前。
- Docker 容器 `signos-home-source` 使用 Nginx，重启策略为 `unless-stopped`。
  容器依赖现有 Colima/Docker；本机必须在线且不休眠。
- 只开放 GET/HEAD `/source.json`、`/appstore` 和 `/files/<name>.ipa|png`。
  其他路径返回 404，不公开目录、发布记录或签名材料。
- 清单 `Cache-Control: no-store`；资源有版本/摘要路径，长期缓存，支持
  HEAD、Range、If-Range、ETag。IPA 不重签名。
- 私有配置 `~/.config/yao-app-source/home-source.json` 指定 `sourceRoot`、
  `sourceBaseUrl`、`root`、`baseUrl`。部署环境文件为同目录 `home-source.env`，
  包含 `HOME_SOURCE_ROOT` 和 `HOME_SOURCE_CERTIFICATES`。
- 当前本机公开文件位于 `packages/home-source/public/`；校验记录与旧清单备份
  位于其父目录，不在 Nginx 允许的 URL 范围内。历史资源保留，不自动删除。

部署命令在仓库根目录运行（本机使用独立的 `docker-compose` 命令）：

```sh
docker-compose --env-file "$HOME/.config/yao-app-source/home-source.env" \
  -f hosting/home-source/compose.yaml run --rm --no-deps source nginx -t
docker-compose --env-file "$HOME/.config/yao-app-source/home-source.env" \
  -f hosting/home-source/compose.yaml up -d
python3 scripts/home_source.py --plan
python3 scripts/home_source.py
```

## 发布与恢复

`cloudflare/app-source/source.config.json` 启用 `homeMirror`。在存在上述私有配置
的发布机上，`app_source.py sync` 和 `publish_signos.py` 完成 Cloudflare 发布后，
自动同步本机源。可用 `APP_SOURCE_HOME_CONFIG` 指定另一私有配置路径。
其他发布机没有私有配置时仍只发布 Cloudflare；之后必须在家中服务器恢复最新
Cloudflare 清单及其引用文件，再运行本机同步，不能把远端发布视为家中入口已更新。

同步会拒绝未完成的 Cloudflare 发布、与公网不一致的清单、缺失/损坏的 IPA。
所有本地 IPA 都核对大小和完整 SHA-256；新增资源先复制，再通过 HTTPS 完整下载
核对摘要，未改动且已有校验凭证的文件做 HEAD 大小检查，最后原子替换清单并
核对两个入口。使用 `--verify-all` 强制全量 HTTPS 摘要校验。
任何资源验证失败都保留原入口；清单验证失败回滚原清单。Cloudflare 已成功而
本机同步失败时，直接重试 `python3 scripts/home_source.py`，无需重签名或重新发版。

```sh
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/home_source.py --verify-all
```

## HTTPS 证书

使用公开受信任的 Let's Encrypt `${APP_SOURCE_DOMAIN}` 证书，不要求用户安装 CA。
当前复用现有 glkvm 项目的 Certbot 证书目录，完整目录只读挂载以支持证书符号链接；
具体主机路径保存在私有 `home-source.env`，不复制私钥到仓库。

2026-10-11 检查时证书到期时间为 **2026-12-05 09:36 UTC（北京时间 17:36）**。
原有 Certbot 使用 manual DNS-01，**没有配置自动续期**。必须在到期前完成续期；
更新同一证书目录后检查并 reload：

```sh
docker exec signos-home-source nginx -t
docker exec signos-home-source nginx -s reload
```

公开域名证书只解决软件源下载 HTTPS，不改变手机上 Fully Local 安装使用的私有 CA，
也不改变本机 SignOs OTA 渠道、签名身份或兼容基线。

## 验收边界

公网 DNS 必须持续对应路由器 WAN 地址；当前由路由器已有腾讯云 DDNS 脚本维护。
通过公网 IP 从同一局域网请求可能经过 NAT 回环，并不等同于独立外网验收。
外网可达性及下载速度应另用手机蜂窝网络核验。

2026-10-11 部署验收：容器处于 running，内网和路由器公网 IP 的 HTTPS 返回 200，
证书校验通过；4 个应用、15 个资源（307,667,097 字节）完整 HTTPS SHA-256
校验通过。SignOs 为 `1.0.7 (8)`，与 Cloudflare 清单保持一致。HEAD、Range、
If-Range、ETag、416 及非公开路径拒绝检查通过；本机发布自动镜像入口也已验证。
本机证据保存在 `packages/home-source/acceptance-20261011.json`。
此次未独立验证蜂窝网络可达性、速度、设备安装和重启恢复。
