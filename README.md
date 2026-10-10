<div align="center">

<img title="SignOs" alt="SignOs" height="180" src="Feather/Resources/Assets.xcassets/AppIcon.appiconset/feather.png">

# SignOs

**The fastest and the best iOS signer.**

Automatic updates. Background signing. App Cloner. Zero effort.

Made By [@ihateios](https://t.me/ihateios)

[Download latest](../../releases/latest) · [Telegram](https://t.me/ihateios)

</div>

SignOs is an iOS app that signs, installs and updates other apps on your device, the same
way the App Store does it. Tap Get on any app from a repository and that's it — it
downloads in the background, signs itself, installs, and shows up on your home screen.

It's built on top of the open source [Feather](https://github.com/claration/Feather) project.
SignOs is owned and developed by me, @ihateios — huge thanks to clARATION and the Feather
contributors for their work, this wouldn't exist without them.

## Features

### Automatic Updates
- Background update checks on a schedule you pick (hourly to daily)
- Updates download, sign and install themselves with zero interaction
- Auto-fire install prompts and Tap-to-install notifications
- Fully silent installs with the paired device (tunnel) method
- Wi-Fi only downloads and night-only install window
- Skip This Version and Hold Updates per app
- Auto-update toggles per app and per source
- Live download progress in Notification Center with speed and ETA
- What's New text from the source in the update notification
- Update All, Recently Updated, and home screen badge for pending updates

### Background Signing
- Serial signing queue — every import or download signs itself automatically
- Apps keep their existing certificate so your data always survives updates
- Self-Heal: revoked certificates are detected and apps are re-signed with your
  healthiest certificate automatically
- Certificate Health dashboard with expiry rings, revocation status and Renew All
- Keep Apps Signed: automatic renewal before certificates expire
- Auto-retry when a signing job fails transiently

### Signing Tools
- App Cloner — run two accounts of the same app side by side
- Tweak Vault — save your favorite .deb and .dylib tweaks once, inject them in one tap
- PPQ protection, Liquid Glass patching, appearance changes, minimum iOS version
- Injection path and folder configuration
- ElleKit for tweak injection into extensions
- Existing dylibs and frameworks management

### The Store Experience
- Discover tab with featured apps and source cards
- Search across every source with recent searches
- Library with filters and quick actions
- Updates tab in App Store style
- OneView install — Get, download progress with speed, signing and Open on one screen
- Rich app pages with screenshots, What's New, version history and permissions
- App Store-style Settings with icon tiles

### Power Features
- Default launch tab setting
- Import and export folder support
- Storage manager with superseded copy and duplicate cleanup
- Activity timeline — every background action logged with timestamps
- Backup and restore for sources and preferences
- Face ID lock
- Home screen badge for pending updates
- Shortcuts app actions: Check for Updates, Install Pending Updates
- Certificates manager with revocation checking
- AltStore-compatible sources, `signos://` URL scheme
- Liquid Glass design on iOS 26, clean Apple-style interface everywhere

## Install

Download `SignOs.ipa` from [Releases](../../releases/latest) and sign it with SideStore,
Sideloadly, AltStore, TrollStore or SignOs itself. The GitHub workflow is configured to
build on pushes to `main` and publish releases for version tags, but currently does not
provision the private TLS files required by `make iphoneos`. A configured workflow is
not proof of a successful build or release; use the local OTA procedure below for this
checkout. `app-repo.json` still describes the upstream public 1.0.0 channel, separately
from this machine's private OTA releases.

## Building

```
make iphoneos
```

That produces packages/SignOs.ipa. You need Xcode 26 or newer on macOS.
Initialize both Git submodules with `git submodule update --init --recursive` first.
Project workflow and post-test delivery requirements are in [AGENTS.md](AGENTS.md).

Fully Local installation needs a TLS certificate trusted by the target device.
`make` reads `server.crt` (certificate), `server.pem` (leaf private key), and
`commonName.txt` (concrete hostname) from `TLS_DIR`. Its local default is
`~/Library/Application Support/IOSAdHocOTA/signos/local-install-tls`; override it
with `make iphoneos TLS_DIR="/private/path/to/tls"` on another machine. Keep the
CA private key outside the app and repository. SignOs also supports these three
files in its Documents directory, which takes precedence over bundled files.

The tested local configuration uses `signos.backloop.dev` with a leaf certificate
issued by the device-trusted local CA. Use a concrete hostname: the device rejected
a literal `127.0.0.1` manifest URL, and `*.backloop.dev` must not be used as a hostname.
The 2026-10-10 device verification of SignOs 1.0.1 is retained locally in
`packages/SignOs-1.0.1-device-check.txt`; the phone's Documents TLS overrides take
precedence over a newly installed package. The Settings **Update SSL Certificates**
button still targets the legacy `https://backloop.dev/pack.json` endpoint and is not
the provisioning path for this local CA setup.

### Local Ad Hoc OTA release

`make iphoneos` produces a device build with a temporary ad-hoc code signature;
it still needs distribution signing before OTA installation. The local release
configuration lives outside this repository at
`~/Library/Application Support/IOSAdHocOTA/signos/release.local.json` and references
the shared signing materials without copying them into the project.

`scripts/serve_ios_ota.py` serves the isolated SignOs channel using the installed
`ios-adhoc-ota` skill's allowlisted handler and the existing LAN TLS certificate.
The local launch agent is `local.ios-adhoc-ota.signos`.

Use the skill's `release_ipa.py` with the private configuration, the generated IPA,
and its actual version/build number; run `--plan` before publishing. The publisher
verifies signing, stages versioned resources, checks HTTPS downloads, and then
switches the fixed `current` entry.

The fixed release metadata endpoint is
`https://192.168.123.79:8769/channels/signos/current/latest-ios.json`; its sibling
`manifest.plist` identifies the active IPA. On 2026-10-10, both launch agents were
running, HTTPS verification with the configured CA succeeded, and the OTA manifest
pointed to SignOs 1.0.1 (build 2). This is a dated server-side snapshot, not a new
device-install acceptance result. Recheck the live endpoints after every deployment.

The installed 1.0.0 release is this project's upgrade baseline. The private
configuration now uses `compatibilityIpa` plus `compatibilityIpaSha256`, with
`firstInstall` removed. Preserve that signed IPA and do not reuse another app's
installation baseline.

OneView keeps a signed archive in the Install state until an installation is
confirmed. Server-based OTA requests cannot confirm completion and keep the
retry action available. The state regression checks can be run on macOS with:

```sh
xcrun swiftc Feather/Utilities/OneViewPhase.swift Tests/OneViewPhaseRegression.swift -o /tmp/signos-phase-regression
/tmp/signos-phase-regression
rm /tmp/signos-phase-regression
```

### Yao App Source（Cloudflare 软件源）

- 固定源地址：`https://yao-app-source.305301890.workers.dev/source.json`；`/appstore` 为同一清单的兼容入口。
- Worker `yao-app-source` 通过绑定读取私有 R2 bucket `yao-app-source`；不依赖本机开机或局域网。
- 使用 SignOs / AltStore 格式，IPA 原样保存为版本、构建号和摘要组成的独立文件；不重新签名。
- 首个应用为 Codex Mobile `0.2.140 (2140)`，来自对话 `01a12463-0613-7803-93db-066e26ed467d`。
- 发布工具：`scripts/app_source.py`；配置：`cloudflare/app-source/source.config.json`；本机发布副本：`packages/app-source/public/`。
- 先用 `publish` 生成新版本，再用 `sync` 上传资源、逐个校验公网 SHA-256，最后发布清单。超过 300 MiB 的 IPA 使用 S3 分片上传。
- 清单不缓存；IPA 流式下载，支持 HEAD、Range、If-Range 和 ETag。部署与发布命令见 [Cloudflare 软件源说明](cloudflare/app-source/README.md)。
- 2026-10-10 已停用并删除 `local.yao.app-source` LaunchAgent、旧 `YaoAppSource` 服务目录及 Python `serve` 入口，8770 端口不再监听。
- 同日真机通过新源添加、IPA 下载、签名与覆盖安装验证；Codex Mobile 正常启动，原 `mac_pc` 连接保留。此前 Wi-Fi 访问曾超时，用户调整网络后通过；大 IPA 与真机跨网络续传尚未实测。
- SignOs 自身 OTA 服务、共用 TLS 和签名材料不受本次迁移影响。软件源目前不自动跟踪上游更新。

## Contact

Questions, feature ideas, anything else: **[@ihateios on Telegram](https://t.me/ihateios)**

## Thanks

SignOs is owned and developed by me, @ihateios. It's built over the open source
[Feather](https://github.com/claration/Feather) project, so special thanks to
[claration](https://github.com/claration), [Nyasami](https://github.com/Nyasami) and
[llsc12](https://github.com/llsc12) for the foundation they built.
