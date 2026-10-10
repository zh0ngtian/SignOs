# 软件源发布入口已迁移

原 Cloudflare/R2 发布流程于 2026-10-11 停用。不要再向旧 Worker 或 R2 上传新版本，
也不要重新开启 workers.dev 或云端 Cron。原历史文件和凭证保留。

当前入口：`https://${APP_SOURCE_DOMAIN}:15006/source.json`。

发布必须在家中服务器的最新 SignOs 仓库中执行，配置为
`hosting/home-source/source.config.json`。其他机器先把 IPA、图标和发布凭证复制到
家中服务器，再运行发布；不要覆盖服务器现有清单和版本历史。

SignOs 必须先完成本机 OTA，之后使用同一正式签名 IPA 和对应凭证：

```sh
python3 scripts/publish_signos.py --ipa /private/path/signed.ipa --release-json /private/path/release.json --plan
python3 scripts/publish_signos.py --ipa /private/path/signed.ipa --release-json /private/path/release.json
```

通用应用、失败重试、HTTPS 校验和证书续期见
[家中软件源说明](../../hosting/home-source/README.md)。
