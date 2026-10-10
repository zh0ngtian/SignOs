# 将普通 IPA 发布到 Yao App Source

软件源已迁移到家中服务器：`${APP_SOURCE_BASE_URL}/source.json`。
Cloudflare Worker、预览和 Cron 继续停用；旧 R2 文件和凭证保留，不恢复旧云端发布。

先从私有环境文件加载 `APP_SOURCE_BASE_URL`，不将实际地址写入仓库。
使用本目录的 `upload_ipa.py` 和管理员提供的共享 token 文件，先执行 `--plan`，
核对 IPA 路径、大小和 SHA-256，再上传原始 IPA。不要重新签名或手写覆盖源清单。

```sh
set -a
. /private/path/app-source.env
set +a
python3 distribution/app-source/upload_ipa.py --ipa /path/app.ipa --plan
python3 distribution/app-source/upload_ipa.py \
  --ipa /path/app.ipa --token-file /private/path/upload-token \
  --developer 'Your name' --description '应用说明' --notes '更新说明'
```

成功返回 201；完全相同的已发布版本返回 200。核对响应里的大小、完整 SHA-256、
版本、构建号和家中 HTTPS 下载地址；服务器已在切换清单前完成 HTTPS 资源校验。
同版本不同内容返回 409，应递增构建号。502/503 可用同一包稍后重试。
不要在输出、URL、仓库或截图中暴露 token。

如果发布的是 `com.signos.app`，共享上传接口不接受此身份。必须先完成独立的
本机 OTA，再在家中服务器运行 `scripts/publish_signos.py --plan` 和正式发布命令，
使用同一正式签名 IPA 及对应的 OTA 凭证，核对两个渠道。详情见
[家中软件源说明](../../hosting/home-source/README.md) 和 [上传协议](README.md)。
