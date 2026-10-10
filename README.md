<div align="center">

<img title="SignOs" alt="SignOs" height="180" src="Feather/Resources/Assets.xcassets/AppIcon.appiconset/feather.png">

# SignOs

**The fastest and the best iOS signer.**

Automatic updates. Background signing. App Cloner. Zero effort.

Made By [@ihateios](https://github.com/ihateios) / [@zh0ngtian](https://github.com/zh0ngtian)

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
- Discover tab with source cards and an all-apps entry
- Search across every source with recent searches
- Library with filters and quick actions
- Updates tab in App Store style
- OneView install — Get (or Update for a detected source update), download progress with speed, signing and Open on one screen
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

After pulling a change to `.gitmodules`, run `git submodule sync --recursive`
before updating submodules. Zsign is pinned to the project-maintained fork for
the certificate-import crash fix in 1.0.4 (5). The OCSP response decoder now
allocates its output safely and returns unknown for malformed, truncated or
unsuccessful responses. Certificate imports insert into Core Data on the main
actor. The previous decoder could crash both after import and on the next launch;
the six-hour self-heal throttle only hid later attempts, rather than fixing it.

The decoder regression covers good/revoked/unknown responses, repeated decoding,
all truncated lengths, trailing bytes and server errors. On a Mac with Homebrew
OpenSSL 3, run it with memory and undefined-behavior checks:

```sh
clang++ -std=c++17 -fsanitize=address,undefined -g \
  -I Zsign/src -I /opt/homebrew/opt/openssl@3/include \
  Zsign/Tests/OCSPResponseRegression.cpp \
  -L /opt/homebrew/opt/openssl@3/lib -lcrypto -o /tmp/signos-ocsp-regression
/tmp/signos-ocsp-regression
rm /tmp/signos-ocsp-regression
```

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

### Install without a private CA

For the tested device, select **Settings → Installation → Server → Semi Local**
and enable **Only use localhost address**. SignOs serves the signed IPA over HTTP
on the phone's `127.0.0.1`; `https://api.palera.in/genPlist` supplies only the HTTPS
manifest. Signing stays on the phone, and the signed IPA is not uploaded to that
service. Safari and iOS still require installation confirmation.

Starting with 1.0.3 (build 4), **Semi Local** and **Only use localhost address**
are the defaults whenever those preferences have not been saved. Installation Type
continues to default to **Server**. Settings, manual installation and background
installation share the same fallback values in `InstallationDefaults`; explicit
existing choices (including Fully Local or a disabled localhost switch) are preserved.

On 2026-10-10, SignOs 1.0.2 (3) on iPhone 17 Pro / iOS 27.0 completed manual
MuseumMuse installation and the Get → download → automatic signing → installation
prompt flow for a 183 MB Bilibili IPA without the local CA. Both apps opened after
covering their existing installations; their preference files were byte-identical
before and after installation, checked before the first new launch. System logs
confirmed both IPA downloads used `http://127.0.0.1:<port>/…ipa`.
The 183 MB source download took about 15 seconds; local delivery and installation
took about 15 seconds after confirmation, excluding signing and confirmation delays.
The automatic flow's Safari page remained blank after success and was closed manually.
Evidence is retained locally in `packages/SignOs-1.0.2-semilocal-device-check.txt`.
This does not verify background/locked-screen installation, interruption recovery,
all app data or keychain persistence, or all IPA sizes.

Fully Local still requires its trusted CA. A missing CA caused the observed
`MissingIntermediate` / TLS `-1200` failure and a stalled Ready screen. The public
CA downloads temporarily placed on Cloudflare were removed at the user's request;
the software source and private local CA materials remain intact.

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

SignOs 客户端的标准发布流程为：递增构建号、构建并测试、提交与 push、
执行 OTA 发布器 `--plan` 并完成 OTA 发布，再将**同一正式签名 IPA**发布到
Yao App Source。使用 OTA 生成的 `latest-ios.json` 或其原样保存的发布凭证，
执行下文的 `scripts/publish_signos.py --plan` 和正式发布命令。
两个渠道均核验通过才算完成；软件源失败时保留已成功的 OTA 版本，修复后重试
软件源步骤，不重新签名或覆盖历史 OTA 目录。不要将 `packages/SignOs.ipa`
这一临时签名构建产物直接上架。

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

### Yao App Source（家中软件源）

- 唯一公开入口：`https://${APP_SOURCE_DOMAIN}:15006/source.json`；`/appstore` 为兼容入口。
- 家中 Mac mini 通过路由器 TCP 15006 提供 HTTPS 下载，使用公开受信任的证书，无需安装 CA。
- `scripts/publish_signos.py` 默认发布到本机，配置为 `hosting/home-source/source.config.json`；不再依赖 Cloudflare。仍需先完成独立的本机 OTA 发布，再使用同一正式签名 IPA 及凭证发布软件源。
- 首次运行先 `--plan`。IPA 原样保存，先校验资源，最后切换清单；版本、构建号、大小和 SHA-256 必须与 OTA 凭证一致。
- 证书由本机 launchd 每 12 小时检查，通过腾讯云 DNS-01 自动续期，成功后校验并重载 Nginx。配置、凭据和证书均在仓库外。
- 完整发布、部署、重试、续期与验收步骤见 [家中软件源说明](hosting/home-source/README.md)。
- 原 `yao-app-source.305301890.workers.dev` 入口与 Cron 已停用；原 R2 私有文件和发布凭证保留为历史备份。旧配置标记为 disabled，发布器拒绝向它发布；[Cloudflare 文档](cloudflare/app-source/README.md)仅用于历史追溯。

## Contact

Questions, feature ideas, anything else: **[@ihateios on Telegram](https://t.me/ihateios)**

## Thanks

This fork is maintained by [@zh0ngtian](https://github.com/zh0ngtian), based on
SignOs by [@ihateios](https://github.com/ihateios). It's built over the open source
[Feather](https://github.com/claration/Feather) project, so special thanks to
[claration](https://github.com/claration), [Nyasami](https://github.com/Nyasami) and
[llsc12](https://github.com/llsc12) for the foundation they built.
