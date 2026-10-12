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
- What's New text from the source in each Available Updates card and update notification;
  multiline notes are shown in full, with a localized fallback when no notes are provided
- Update All reuses downloaded source versions: signed packages install directly, imported packages resume signing; only missing versions download again
- Recently Updated and home screen badge for pending updates

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
- Sources tab with source icons, app counts, last refresh times and per-source sync buttons;
  tap a source to manage it or browse its apps. Remote subscription projects show app icons,
  versions and build numbers. Add/import/export and per-source automatic updates remain available
- Search across every source with recent searches (tab currently hidden; implementation retained)
- Library with filters and quick actions
- Updates tab with app updates and recent activity; tap Check or pull down to synchronize every subscribed source, then check for updates using the same fresh data
- Simplified Chinese throughout app controls, settings, status messages and notifications; source sync and update actions share Search's capsule style
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
Swift 回归、客户端构建、发布脚本及对应回归、模拟器回归脚本和构建工作流自身；纯服务、文档、规则和其他
非客户端改动跳过自动构建。
路径过滤不影响标签发布或手动构建。使用 `macos-26` 与 Xcode 26+，递归检出子模块，
检查 Xcode 和 iOS SDK 后，仅执行一次 `generic/platform=iOS` 的 Release 构建，
设置 `CODE_SIGNING_ALLOWED=NO`。PR 和其他分支的手动构建以编译、链接成功为准；
`main` push 与 `main` 手动构建还会打包、校验 IPA 并保留发布产物。

日常 push / PR 和手动构建不运行 Swift / Python 回归，不启动、安装或运行模拟器。
`main` 构建使用 `--package-ipa` 模式，上传 `SignOs-ci-<commit>`，包含 IPA 与构建元数据，
保留 14 天；其他构建不打包或上传成功产物。失败时尝试上传构建日志与 Xcode result bundle，
保留 7 天。
流水线不依赖私有 `TLS_DIR` 或分发签名材料。**CI 成功不能替代功能验收**；功能按改动范围
在本地完成回归与运行验收；`main` 构建还证明 IPA 身份与完整性校验通过。
此前一次模拟器回归耗时 8 分 16 秒，精简后省去这一段；
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
`SourceSubscriptionIdentity`、`SourceMigrationReadiness` Swift 回归，以及更新管理器、签名安装队列、
下载管理器与安装清理的 iOS 模拟器回归；需要时在 Actions 页面选择分支并点击 Run workflow，或运行：

```sh
gh workflow run ios-regression.yml --repo zh0ngtian/SignOs --ref main
```

该手动入口不替代改动所需的本地功能验收，也不包含依赖真机或私有配置的 OTA 验收。

远端软件源的“添加订阅”支持一次选择同一 GitHub Release 的多个 IPA。每个附件都有独立的
匹配规则、订阅 ID、同步状态和版本历史；解析成功后仍需逐项确认发布。同 Bundle ID 的
不同变体继续按订阅 ID 区分。自动生成的规则若会命中其他附件，则保留精确文件名，需按实际
命名方式调整后续匹配规则。批量添加失败时保留已成功的项目，重试只提交剩余选择；请求超时
后能成功刷新远端目录时，也会核对该次请求是否已经创建订阅。

手动完整回归还包含 `CloudSourceSubscriptionRegression`，覆盖独立附件规则、修订号连续写入、
部分失败重试、响应丢失和目录刷新失败。可单独运行：

```sh
xcrun swiftc Feather/Utilities/CloudSourceAssetRule.swift \
  Feather/Backend/CloudSource/CloudSourceModels.swift \
  Feather/Backend/CloudSource/CloudSourceStore.swift \
  Feather/Backend/CloudSource/CloudSourceCredentials.swift \
  Tests/CloudSourceSubscriptionRegression.swift -o /tmp/signos-subscription-regression
/tmp/signos-subscription-regression
rm /tmp/signos-subscription-regression
```

更新管理器回归还验证已下载版本复用、来源与订阅匹配、签名包优先及文件缺失回退。
签名队列回归使用生产 `AutoSignManager.swift`，以可控签名与安装替身验证已有签名包
直接安装、连续点击去重、串行安装及已导入包继续签名：

```sh
python3 scripts/test_auto_sign_manager.py <SIMULATOR_UDID>
```

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
**该提交**的 `iOS Build Check / iOS Release build` 成功，并按下节流程发布新版；任何涉及
App 的改动都必须发布，不按类型、规模或是否改变用户可见功能区别处理，发布完成才算交付。
不涉及客户端时，仅完成受影响部分的检查，无须执行、手动触发或等待客户端构建。
发布默认使用 GitHub Release，版本号和构建号由本次改动递增。普通提交和手动构建本身
不创建 Release，因此客户端交付必须继续完成标签发布；每次 App 发布同时使用该产物完成 OTA 签名与固定渠道更新，并交付安装链接。

### GitHub Release 标准发布流程

发布标签使用 `vX.Y.Z`，例如 `v1.0.11`。准备发布时，先将 `Feather.xcconfig`
中的 `FEATHER_PROJECT_VERSION` 更新为 `X.Y.Z`，并按需要更新 Xcode 工程中的
`CURRENT_PROJECT_VERSION`；每次 App 改动都发布新版本，版本号和构建号均须高于之前发出的包。提交并 push 到
`main`，等待该提交的 `iOS Build Check` 成功，再为这个已验证的提交打标签：

```sh
# 将版本与完整提交 SHA 替换为本次发布值
git tag -a v1.0.11 <verified-commit-sha> -m "SignOs 1.0.11"
git push origin v1.0.11
```

标签 push **不再执行 iOS 构建**。发布任务通过 `scripts/find_release_artifact.py` 查找
同一仓库、同一完整提交 SHA 的成功 `main` push / 手动构建，只下载其中未过期的
`SignOs-ci-<commit>` 产物；不使用其他提交、标签或 PR 构建。随后重新校验包版本、
身份、提交、大小和 SHA-256，生成校验和与发布说明。此流程不自动运行回归；发布前按改动
范围完成本地验证，需要完整回归时运行上文的手动工作流。只有构建成功、标签版本与
IPA 版本一致，且下载产物的提交、身份、大小和校验和通过检查，
`Publish GitHub Release` 才会发布以下长期下载文件：

- `SignOs.ipa`：未经过分发签名的 iOS 包，安装前需自行签名。
- `build-metadata.json`：提交、版本、构建号、最低 iOS 版本和 IPA SHA-256。
- `SHA256SUMS`：IPA 和元数据的 SHA-256；下载后运行 `shasum -a 256 -c SHA256SUMS` 验证。

`main` 构建的中间产物 `SignOs-ci-<commit>` 保留 14 天，Release 附件长期保留。
若该提交没有成功构建产物或产物已过期，标签发布会失败并提示先重跑该提交对应的
`main` 构建工作流，再重跑标签工作流；不会自动重复构建或改用其他提交的包。
标签发布在 Ubuntu 上完成，无须再次申请 macOS runner。IPA 安装前需另行签名。
跨工作流产物下载使用 `GITHUB_TOKEN` 的 `actions: read` 权限，见
[download-artifact 官方说明](https://github.com/actions/download-artifact/blob/v4/README.md#download-artifacts-from-other-workflow-runs-or-repositories)。

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

任何涉及 App 的改动都须通过上文的 GitHub Actions 构建检查，并按标签发布新版到 GitHub Release。
用户已持续授权每次 App 发布同时更新 OTA：使用同一已验证构建产物和现有私有配置发布正式
Ad Hoc 签名 IPA，保持两者版本一致、构建号递增，无须逐次询问。GitHub Release 和 OTA
均验收成功才算交付完成，最终回复须附上可点击的固定 OTA 安装页链接和实际版本、构建号。
固定安装页为 `https://192.168.123.79:8769/channels/signos/current/install.html`；
每次交付前从私有配置和在线探针核对当前地址及版本。

2026-10-11 用户曾明确要求双渠道正式发包：同一 OTA 签名包通过
`scripts/publish_signos.py` 归档到 GitHub，并加入 Cloudflare 软件源；发布前执行 `--plan`，
两端完整下载 SHA-256 必须相同。软件源管理、最新包迁移与兼容入口见
[Cloudflare 软件源](distribution/source-aggregator/README.md)。该按需操作独立于每次 App 改动必须完成的 GitHub Release 发布。

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

2026-10-11 后续已将 Cloudflare 中的 SignOs 主订阅切换到 `zh0ngtian/SignOs` 的正式 Release，
核验 1.0.11（12）未签名 IPA；原 1.0.10 签名包保留在软件源历史中。本地 OTA 渠道未切换。
除哔哩哔哩的固定 IPA URL 外，其他应用也均订阅各自的正式仓库，每小时检查更新。
订阅规则与在线验收见 [Cloudflare 软件源](distribution/source-aggregator/README.md)。

2026-10-12 按用户要求将本地 OTA 固定入口升级到 1.0.14（15），使用已通过 GitHub Actions
的正式 Release 产物进行 Ad Hoc 签名，保留 1.0.0 兼容基线及原升级身份。
已核对 HTTPS 固定入口、manifest、安装页和完整 IPA 下载；签名包为 14,839,527 字节，
SHA-256 为 `5c328d245e765930ff5ad38f46f66e51a82e0939cdbc8e9378112c11d277350e`。
GitHub Release 保留原未签名产物。真机覆盖安装与数据保留未在本次验证；
实测记录见 [OTA 发布凭证](docs/plans/evidence/ota-publication-20261012.json)。

2026-10-12 后续发布 1.0.15（16）：软件源同步及更新操作统一为搜索页的胶囊样式，
隐藏搜索标签但保留实现；补齐 523 条简体中文翻译，覆盖界面、动态提示、通知和快捷指令。
最终提交通过本地构建、中文更新管理器回归及模拟器界面验收（含深色和最大辅助字体），
GitHub Actions 构建与标签发布均成功。相同 CI 产物完成 Ad Hoc 签名及 OTA 发布，
固定入口、manifest、安装页和完整 IPA 下载核验通过。签名包为 14,855,845 字节，
SHA-256 为 `f3ed710e2c1a071a573885d12dde37abf428fb571b5c7ddadff7bfa3529cc7bd`。真机覆盖安装未在本次验证；
实测记录见 [1.0.15 发布凭证](docs/plans/evidence/ota-publication-1.0.15-20261012.json)。

2026-10-12 后续发布 1.0.16（17）：旧签名包与未签名包改为在安装结束时一起清理，
服务器安装以进度出现后消失或归零为清理信号，配对安装以成功返回为信号；
待安装或明确报错时保留文件，最新签名包始终保留供重试。手动签名的原包删除也延后，
待清理记录支持重启后重试及重新签名。安装清理模拟器回归、OneView 回归与本地构建通过，
GitHub Actions 构建及标签发布成功，同一 CI 产物完成 Ad Hoc 签名和固定 OTA 发布。
已核对 Release 附件、固定入口、manifest、版本及完整 IPA 下载；签名包为 14,861,457 字节，
SHA-256 为 `57b2262cf2d0ec0847930473fe1db18a2e98ba327eeedb4728df0422567bcfbc`。
进度消失仍不能证明新版实际安装成功；真机覆盖安装未在本次验证。
实测记录见 [1.0.16 发布凭证](docs/plans/evidence/ota-publication-1.0.16-20261012.json)。

2026-10-12 后续发布 1.0.17（18）：单个更新与 Update All 复用已下载的同一软件源订阅版本，
优先直接安装签名包，未签名包继续签名安装，仅缺少对应文件时重新下载。
安装任务按队列串行执行并去重；安装未完成时仍保留包和重试入口。
更新包匹配、生产签名安装队列与 OneView 模拟器回归及本地构建通过，
GitHub Actions 构建和标签发布成功。Release 下载校验通过，同一 CI 产物完成 Ad Hoc
签名和固定 OTA 发布；固定入口、manifest、包内版本及完整下载 SHA-256 核验通过。
签名包为 14,865,380 字节，SHA-256 为
`3607856cc350848a501bd355423d1288cc1346e74d9baeef43ac69c553084074`。
真机覆盖安装与数据保留未在本次验证；
实测记录见 [1.0.17 发布凭证](docs/plans/evidence/ota-publication-1.0.17-20261012.json)。

2026-10-12 后续发布 1.0.18（19）：可用更新中的每个 App 卡片显示软件源当前版本的完整更新说明，
保留多行内容和段落；缺失或仅空白时显示“暂无更新说明”。版本变化位于卡片底部，
辅助大字体下更新按钮移到应用信息下方。生产卡片的 375pt 布局、深色模式及最大辅助字体验收通过，
完整应用完成隔离的模拟器构建与启动，本地 iOS Release 构建通过。
GitHub Actions 构建和标签发布成功，同一 CI 产物完成 Ad Hoc 签名与固定 OTA 更新；
已核对 Release 附件、固定入口、manifest、包内版本和完整 IPA 下载。签名包为 14,869,358 字节，
SHA-256 为 `ab263bb87817b2e0b9d39710fecc4b75441b982ac719099c4fec882bbcdf47fc`。
真机覆盖安装与数据保留未在本次验证。
实测记录见 [1.0.18 发布凭证](docs/plans/evidence/ota-publication-1.0.18-20261012.json)。

2026-10-12 后续发布 1.0.19（20）：添加 GitHub 订阅支持多选同仓库的 IPA，每个附件分别配置
后续匹配规则并建立独立订阅、同步状态和版本历史。宽泛规则匹配多个附件时禁止解析；
批量添加途中失败可只重试剩余项目，订阅列表显示规则以区分同仓库的变体。
批量订阅、订阅身份和更新管理器回归通过；生产表单的多选、规则编辑、冲突提示及两个订阅的
创建完成模拟器验收，完整应用模拟器构建与启动、本地 iOS Release 构建通过。
GitHub Actions 构建和标签发布成功，Release 附件与校验和通过核验，同一产物完成 Ad Hoc
签名及固定 OTA 发布。固定入口、manifest、包内版本与完整 IPA 下载核验通过；签名包为
14,888,534 字节，SHA-256 为 `19aa8ebc277b09a71a19d1a1541616715c35d7864c1c3e0e348f97b2e0b39fb1`。
真机覆盖安装与数据保留未在本次验证。
实测记录见 [1.0.19 发布凭证](docs/plans/evidence/ota-publication-1.0.19-20261012.json)。

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

Installation cleanup regression uses the production retention policy and storage
deletion code with isolated Core Data and temporary package files. It verifies
retention before progress starts and while it is active, cleanup on disappearance
or zero after progress starts, persisted retry plans, removal of package files and
metadata, and both automatic replacement and manual imported-package deletion:

```sh
python3 scripts/test_install_cleanup_simulator.py <SIMULATOR_UDID>
```

**Replace Old Versions** now cleans up the old signed package and its imported
package together at installation end, rather than at signing completion. Paired
installation uses its successful return; server installation uses observed
progress disappearing. The latter does not verify the installed version. Failed
or pending attempts retain packages until that signal, and the new signed package
remains available for retry after cleanup. **Delete After Installation** replaces
the manual signing option's former immediate deletion behavior.

The source identity regression covers URL migrations, unrelated sources and
legacy URL-only metadata, including the official Yao source move. During update
checks, URL-only records are linked to the source's stable ID and subscription ID
while retaining their **local** version. This repair also runs for devices whose
`cloudSourceMigration.v2` flag is already set. Only the known official old/new
URLs and official repository ID are accepted without stored identity.

Updates reports source fetch, missing association and ambiguous subscription
failures as an incomplete check; it does not show or notify “All Apps Up to Date”
for an incomplete check. CHECK synchronizes all subscribed sources with uncached HTTP 200
responses, publishes the source browsing cache, then compares versions from that same snapshot.
For sources with saved management credentials, CHECK first starts remote synchronization and
clears GitHub release caches and waits for parsing to finish; remote failures remain visible
as an incomplete check.
Cancelled checks retain pending updates and leave the source cache and completed-check date
unchanged; they do not start automatic downloads and offer CHECK to retry.
Source fetch failures report their actual error (including HTTP status) without treating the source as removed.

The production update manager and Core Data metadata writer regression covers
the museum 1.1.2 → 1.1.3 case, repeated checks, subscription variants, holds/skips,
all-source synchronization before comparison without duplicate requests, request/task
cancellation, HTTP/JSON failures, removed sources and successful retry:

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
