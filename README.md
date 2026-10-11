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
- Repository URL migrations keep existing app update links when the fetched source
  retains the same nonempty repository identifier. Legacy records without an
  identifier continue to require the original URL.
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
- Sources tab with source cards, an all-apps entry, add/import/export, per-source
  update controls and removal, and remote source management
- Search across every source with recent searches
- Library with filters and quick actions
- Updates tab with app updates and recent activity; pull down to check for updates
- Automatic update and signing preferences in Settings
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

Download `SignOs.ipa` from [Releases](../../releases/latest) and sign
it with SideStore, Sideloadly, AltStore, TrollStore or SignOs itself. New commits
are build-checked by [iOS Build Check](../../actions/workflows/ios-build.yml).
CI success means the iOS Release build compiled and linked; functionality is verified
locally for each change. GitHub Release packages require separate signing before installation.
`app-repo.json` describes the upstream public 1.0.0 channel and is not updated
by this build-check workflow.

## Building

```
make iphoneos
```

That produces packages/SignOs.ipa. You need Xcode 26 or newer on macOS.
Initialize both Git submodules with `git submodule update --init --recursive` first.
Project workflow and post-test delivery requirements are in [AGENTS.md](AGENTS.md).

### GitHub Actions 构建检查

[工作流](.github/workflows/ios-build.yml) 在涉及客户端的 `main` push 和面向 `main` 的 PR
时自动运行，另保留手动构建和 `v*` 标签发布入口。自动触发路径覆盖 `Feather/`、Xcode
工程与配置、本地 Swift 包源码与清单、子模块引用与配置、`Makefile`、许可证资源配置、
Swift 回归、客户端构建和模拟器回归脚本及构建工作流自身；纯服务、文档、规则和其他
非客户端改动跳过自动构建。
路径过滤不影响标签发布或手动构建。使用 `macos-26` 与 Xcode 26+，递归检出子模块，
检查 Xcode 和 iOS SDK 后，仅执行一次 `generic/platform=iOS` 的 Release 构建，
设置 `CODE_SIGNING_ALLOWED=NO`。编译、链接成功即通过。

日常 push / PR 和手动构建不运行 Swift / Python 回归，不启动、安装或运行模拟器，
不打包或校验 IPA、不生成构建元数据，也不上传成功产物或诊断文件。
失败时尝试上传构建日志与 Xcode result bundle，保留 7 天。
流水线不依赖私有 `TLS_DIR` 或分发签名材料。**CI 成功只表示构建通过**；功能按改动范围
在本地完成回归与运行验收。此前一次模拟器回归耗时 8 分 16 秒，精简后省去这一段；
依赖下载和 Release 编译仍需时间，实际节省量以运行结果为准。

本地复现流水线构建步骤：

```sh
git submodule sync --recursive
git submodule update --init --recursive
bash scripts/check_ios_build.sh "$(mktemp -d /tmp/signos-ios-build.XXXXXX)"
```

### 手动按需完整回归

[Full iOS Regression](.github/workflows/ios-regression.yml) 只通过 `workflow_dispatch`
按需运行，与日常构建及标签发布独立。它运行 `Tests/test_*.py` 的 Python 回归、
`GitHubReleaseRegression.py` 发布工具回归、`OneViewPhase`、`SourceRepositoryIdentity`、
`SourceSubscriptionIdentity`、`SourceMigrationReadiness` Swift 回归，以及更新管理器和
下载管理器的 iOS 模拟器回归；需要时在 Actions 页面选择分支并点击 Run workflow，或运行：

```sh
gh workflow run ios-regression.yml --ref main
```

该手动入口不替代改动所需的本地功能验收，也不包含依赖真机或私有配置的 OTA 验收。

下载管理器回归使用生产 `DownloadManager.swift` 和本地限速 HTTP 服务，验证重复调用
只产生一个传输、暂停恢复复用原任务、取消行为及下载完成后的导入等待。签名、导入和
后台任务集成使用测试替身，不更改已安装的 SignOs 数据。在已启动的模拟器运行：

```sh
python3 scripts/test_download_manager_simulator.py <SIMULATOR_UDID>
```

追加 `--benchmark <HTTPS_IPA_URL>` 可顺序完整下载四次，交替测试原始入口和本次跳转
得到的地址，输出字节数、耗时、吞吐量和 URLSession 分段指标。跳转地址只用于本次
诊断，不保存签名 URL，也不作为软件源的长期地址。测试结束会移除临时 App 和文件。

常规交付流程为：完成本地必要检查、提交与 push、核对远端提交。涉及客户端时，须等待
**该提交**的 `iOS Build Check / iOS Release build` 成功；只触发工作流不算完成。
不涉及客户端时，仅完成受影响部分的检查，无须执行、手动触发或等待客户端构建。
普通提交和手动构建不创建 GitHub Release。流水线不改版本或构建号；
标签发布使用下一节的标准流程，本机 OTA 仅在明确要求发包时执行。

### GitHub Release 标准发布流程

发布标签使用 `vX.Y.Z`，例如 `v1.0.11`。准备发布时，先将 `Feather.xcconfig`
中的 `FEATHER_PROJECT_VERSION` 更新为 `X.Y.Z`，并按需要更新 Xcode 工程中的
`CURRENT_PROJECT_VERSION`；新安装包的构建号应高于之前发出的包。提交并 push 到
`main`，等待该提交的 `iOS Build Check` 成功，再为这个已验证的提交打标签：

```sh
# 将版本与完整提交 SHA 替换为本次发布值
git tag -a v1.0.11 <verified-commit-sha> -m "SignOs 1.0.11"
git push origin v1.0.11
```

标签 push 会执行一次 iOS Release 构建，并通过构建脚本的 `--package-ipa` 模式打包和
校验 IPA，生成版本、身份、提交和 SHA-256 元数据。此流程不自动运行回归；发布前按改动
范围完成本地验证，需要完整回归时运行上文的手动工作流。只有构建成功、标签版本与
IPA 版本一致，且下载产物的提交、身份、大小和校验和通过检查，
`Publish GitHub Release` 才会发布以下长期下载文件：

- `SignOs.ipa`：未经过分发签名的 iOS 包，安装前需自行签名。
- `build-metadata.json`：提交、版本、构建号、最低 iOS 版本和 IPA SHA-256。
- `SHA256SUMS`：IPA 和元数据的 SHA-256；下载后运行 `shasum -a 256 -c SHA256SUMS` 验证。

标签构建的中间产物 `SignOs-ci-<commit>` 包含 `SignOs.ipa` 与 `build-metadata.json`，
保留 14 天，供发布任务下载校验；Release 附件长期保留。标签流程同样只在失败时上传
构建诊断，IPA 安装前需另行签名。

Release 说明包含安装要求和自动生成的变更记录。发布使用仓库自带的
`GITHUB_TOKEN`，无须私有签名或 TLS 配置。等待标签对应的整个工作流成功，
再核对 Release 附件及包内版本；失败时修复后重跑对应工作流，不移动已发布标签。
此流程不更新 `app-repo.json` 或 OTA/Cloudflare 渠道。使用 `GITHUB_TOKEN`
创建的 Release 不会再触发旧 `Update Repository` 工作流，见
[GitHub 的工作流触发规则](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)。

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
the private local CA materials remain intact.

### Local Ad Hoc OTA release (on request)

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

明确要求 OTA 发包时使用私有配置发布正式签名 IPA，并保证构建号递增。
常规客户端改动使用上文的 GitHub Actions 构建检查；公开版本按标签发布到 GitHub Release。

本次用户明确要求双渠道正式发包：同一 OTA 签名包通过
`scripts/publish_signos.py` 归档到 GitHub，并加入 Cloudflare 软件源；发布前执行 `--plan`，
两端完整下载 SHA-256 必须相同。软件源管理、最新包迁移与兼容入口见
[Cloudflare 软件源](distribution/source-aggregator/README.md)。该按需操作不改变常规构建检查规则。

The fixed release metadata endpoint is
`https://192.168.123.79:8769/channels/signos/current/latest-ios.json`; its sibling
`manifest.plist` identifies the active IPA. On 2026-10-11, SignOs 1.0.10 (build 11,
minimum iOS 17) was distribution-signed and published to both local OTA and the
Cloudflare source. Both channels serve the same 16,866,467-byte IPA with SHA-256
`c62e46c9618196410041c109b05ba3e756e7c1669ca12b4a79b8155987827933`.
The fixed manifest points to the versioned IPA. The migration imported only each
app's latest package; subsequent new releases retain normal version records.
The old HTTPS source aliases redirect to the four
original default variants, and old IPA URLs remain available. See the
[publication evidence](docs/plans/evidence/dual-channel-publication-20261011.json).
This is a dated server-side snapshot. Simulator startup and source migration were
verified on iOS 26.5; physical upgrade installation and data retention were not
tested. Recheck the live endpoints after every deployment.

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

The source identity regression covers URL migrations, unrelated sources and
legacy URL-only metadata, including the official Yao source move. During update
checks, URL-only records are linked to the source's stable ID and subscription ID
while retaining their **local** version. This repair also runs for devices whose
`cloudSourceMigration.v2` flag is already set. Only the known official old/new
URLs and official repository ID are accepted without stored identity.

Updates reports source fetch, missing association and ambiguous subscription
failures as an incomplete check; it does not show or notify “All Apps Up to Date”
for an incomplete check. Checks reload source JSON and require HTTP 200.

The production update manager and Core Data metadata writer regression covers
the museum 1.1.2 → 1.1.3 case, repeated checks, subscription variants, holds/skips,
HTTP/JSON failures and successful retry:

```sh
python3 scripts/test_update_manager.py <SIMULATOR_UDID>
```

The pure repository identity regression runs with:

```sh
xcrun swiftc Feather/Utilities/SourceRepositoryIdentity.swift Tests/SourceRepositoryIdentityRegression.swift -o /tmp/signos-source-regression
/tmp/signos-source-regression
rm /tmp/signos-source-regression
```

## Contact

Questions, feature ideas, anything else: **[@ihateios on Telegram](https://t.me/ihateios)**

## Thanks

This fork is maintained by [@zh0ngtian](https://github.com/zh0ngtian), based on
SignOs by [@ihateios](https://github.com/ihateios). It's built over the open source
[Feather](https://github.com/claration/Feather) project, so special thanks to
[claration](https://github.com/claration), [Nyasami](https://github.com/Nyasami) and
[llsc12](https://github.com/llsc12) for the foundation they built.
