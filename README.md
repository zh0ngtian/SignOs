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
- Enabled repositories jointly supply the newest version for each app; equal versions prefer the current or explicitly selected source. Manual imports and multiple repositories can share a Bundle ID.
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
- Update All reuses downloaded source versions and checks signing identity; imported or differently signed packages resume signing, and only missing versions download again
- One Applications tab with All / Available Updates / Pending filters, full release notes, cached-package reuse and a deduplicated home screen badge

### Background Signing
- Serial signing queue — every import or download signs itself automatically
- Existing apps keep their valid certificate; replacement checks the signed package’s actual identity and access groups before re-signing. Changing the default certificate does not re-sign existing apps
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
- Sources tab with source icons, app counts and last refresh times; tap a source to browse
  all its apps with Install/Update capsule buttons, search, sorting and pull-to-refresh.
  The top-right settings button opens source settings with remote subscription management
  and source removal; configuration backup, management access and local subscription sections are omitted
- Search across every source with recent searches (tab currently hidden; implementation retained)
- Applications combines Library and Updates, groups retained packages by Bundle ID, and exposes version/source/certificate history in app details
- Applications sorts current source releases by publication date, newest first, across all filters; apps without publication dates appear last
- Pull down Applications to synchronize enabled subscribed sources and check updates from the same fresh data
- Sources can be disabled locally while retaining packages; disabled archives remain visible and are excluded from signing, installation and automatic cleanup
- Single-app and batch certificate replacement reuses local packages without changing app versions
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
- Local diagnostic logs with search, severity filters, full details and UTF-8 text export from Settings
- Backup and restore for sources and preferences
- Face ID lock
- Home screen badge for pending updates
- Shortcuts app actions: Check for Updates, Install Pending Updates
- Certificates manager with revocation checking
- AltStore-compatible sources, `signos://` URL scheme
- Liquid Glass design on iOS 26, clean Apple-style interface everywhere

## 日志查看与导出

进入「设置 → 日志」查看启动、下载、导入、签名诊断和自动操作记录。列表按最新时间排序，
支持搜索内容、分类和级别，也可通过「日志级别」筛选；点击记录查看完整正文，长按选择文字或
点击「复制」。右上角导出按钮（搜索时使用「导出搜索结果」）通过系统分享菜单发送 `.txt` 文件或存储到「文件」，导出的是
当前搜索与级别筛选结果，文件按时间正序排列，并包含版本、构建号、系统版本和导出时间。

日志仅保存在设备本机，最多 1000 条或 2 MiB；单条正文最多 16 KiB，超限有截断标记。
URL 凭据、查询参数、fragment 和常见 Token / 密码字段先脱敏；证书内容和设备 UDID 不收集。
不截获第三方底层 stdout，所以此页不代表完整系统控制台。已有活动记录迁移一次，原「活动」页
保留。更多操作中的「清空日志」需要确认，清空全部日志但不清空活动页或应用文件。
损坏的日志文件保留副本；读写失败会显示提示，不把日志写入失败当成业务失败。

日志核心回归可在 macOS 运行：

```sh
xcrun swiftc -swift-version 6 -warnings-as-errors \
  Feather/Utilities/AppLogStore.swift Feather/Utilities/LogExportFile.swift \
  Tests/AppLogRegression.swift -o /tmp/signos-log-regression
/tmp/signos-log-regression
```

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

### 多任务协调与合批发布

开发任务在独立分支或 worktree 完成本地必要验证，登记确定的提交 SHA 与结果；由同一
发布作用域的协调负责人统一整合、分配版本、推进 `main` 并完成发布。合批窗口、冻结、
锁与恢复的通用策略以当前生效的 canonical 全局 `AGENTS.md` 为准；项目只补充
[发布目标、接入状态和具体改造项](docs/release-coordination.md)。

本机统一入口为 `~/.local/bin/releasectl`；协调器独立维护在
[release-coordinator](https://github.com/zh0ngtian/release-coordinator)，通过 Python / SQLite
和 owner-only Unix socket 在各 worktree 间共享状态。不同项目独立队列和锁，可并行；
SignOs 使用 `signos-production` 配置，适配器为 `scripts/signos_release_adapter.py`。
运行时不依赖开发 worktree，状态、心跳、CI 进度和共同凭证在仓库外持久保存。
启动模式以本机安装凭证为准：LaunchAgent 是登录启动，LaunchDaemon 才是登录前开机启动。

开发任务登记、维持心跳、完成验证并 push 开发分支后提交就绪；后台服务自动推进兼容批次。
本节后续构建、标签和 OTA 命令是适配器的底层步骤，不由各任务分别执行。常用命令和
恢复方式见[发布协调说明](docs/release-coordination.md)。

### GitHub Actions 构建检查

[工作流](.github/workflows/ios-build.yml) 在涉及客户端的 `main` push 和面向 `main` 的 PR
时自动运行，另保留手动构建和 `v*` 标签发布入口。自动触发路径覆盖 `Feather/`、Xcode
工程与配置、本地 Swift 包源码与清单、子模块引用与配置、`Makefile`、许可证资源配置、
Swift 回归、客户端构建、发布脚本及对应回归、模拟器回归脚本和构建工作流自身；纯服务、文档、规则和其他
非客户端改动跳过自动构建。
路径过滤不影响标签发布或手动构建。使用 `macos-26` 与 Xcode 26+，递归检出子模块，
检查 Xcode 和 iOS SDK 后，仅执行一次 `generic/platform=iOS` 的 Release 构建，
设置 `CODE_SIGNING_ALLOWED=NO` 并锁定 `Package.resolved` 的依赖版本。PR 和其他分支的手动构建以编译、链接成功为准；
`main` push 与 `main` 手动构建还会打包、校验 IPA 并保留发布产物。正式 main / 标签发布
使用同一 `signos-production-release` 并发组，关闭进行中取消并保留多批排队；PR 与其他
分支检查另组。正式构建和标签发布须通过冻结批次校验，手动入口不能借用后来 main 的提交。

日常 push / PR 和手动构建不运行 Swift / Python 回归，不启动、安装或运行模拟器。
`main` 构建使用 `--package-ipa` 模式，上传 `SignOs-ci-<commit>`，包含 IPA、构建元数据和冻结清单，
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

添加软件源统一使用公开的 AltStore 格式 URL，无须管理 Token。需要管理时，进入已添加的
软件源，点击右上角“软件源设置”齿轮，再填写管理 Token 并连接；Token 成功连接后保存在
钥匙串。管理入口先识别管理服务的 HTTPS 源地址（`/source.json`、`/appstore` 或
`/sources/<id>.json`），再通过公开 `/health` 返回的 `signos-source-aggregator` 服务标志
确认管理能力，无须发送 Token；普通静态源不显示设置齿轮。服务无法确认时暂不显示，重新
进入该源会再次检查。管理页不再提供“订阅到 SignOs”、“分享软件源地址”或二级
“软件源设置”。软件源列表卡片可长按选择“启用软件源”或“禁用软件源”，菜单根据当前本机状态切换；重新启用会自动检查更新。禁用保留本地包，不影响其他源。长按菜单也保留“移除软件源”，确认后移除，普通源也可使用。

管理能力识别可单独回归：

```sh
xcrun swiftc Feather/Backend/CloudSource/CloudSourceModels.swift \
  Tests/CloudSourceManagementRegression.swift -o /tmp/signos-management-regression
/tmp/signos-management-regression
```

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

常规交付流程为：各开发任务完成本地必要检查，提交并 push 开发分支，核对远端 SHA 后
登记就绪；协调负责人整合并完成合并后的必要检查，统一分配版本，冻结批次及最终提交，
再推进 `main`，触发该批次一次正式构建。各任务须核对自己的改动已包含在最终提交中，
等待 **冻结提交** 的 `iOS Build Check / iOS Release build` 成功，并读取该批次共同的发布凭证。
任何涉及 App 的改动都必须随所属批次发布，不按类型、规模或是否改变用户可见功能区别
处理；进入队列或加入批次不算交付完成。不涉及构建或发布的改动检查后直接提交与 push，
不额外触发客户端构建；纯服务改动按既有部署与 HTTPS 验收要求完成，不发 App。
发布默认使用 GitHub Release，由协调负责人按批次递增版本号和构建号，参与任务共用
该版本。普通提交和手动构建本身不创建 Release；客户端批次还须完成标签发布，并使用
同一产物完成 OTA 签名与固定渠道更新，交付安装链接，避免参与任务分别发包。

### GitHub Release 标准发布流程

以下步骤由协调负责人对冻结批次执行。发布标签使用 `vX.Y.Z`，例如 `v1.0.11`。
整合及必要检查通过后，统一将 `Feather.xcconfig` 的 `FEATHER_PROJECT_VERSION`
更新为 `X.Y.Z`，并递增 Xcode 工程的 `CURRENT_PROJECT_VERSION`，将版本改动纳入
批次最终提交后冻结。每个涉及 App 的批次都发布新版，版本号和构建号均须高于之前
发出的包。推进该冻结提交到 `main`，等待其 `iOS Build Check` 成功，再为该提交打标签：

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

The batch coordinator uses the skill's `release_ipa.py` with the private configuration,
the exact frozen commit's verified CI IPA, and its actual version/build number; run `--plan` before publishing. The publisher
verifies signing, stages versioned resources, checks HTTPS downloads, and then
switches the fixed `current` entry.

任何涉及 App 的改动都须随所属批次通过上文的 GitHub Actions 构建检查，并按标签发布新版到 GitHub Release。
用户已持续授权每批 App 发布同时更新 OTA：由协调负责人使用同一已验证构建产物和现有私有配置发布正式
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

2026-10-12 后续发布 1.0.20（21）：移除更新页检查按钮和软件源卡片上的同步胶囊，
保留两个页面的下拉刷新及软件源管理入口，清理按钮留白并将重试提示改为下拉操作。
完整应用模拟器构建与启动、两个页面截图验收、深色大字号软件源布局核验、
更新管理器回归及本地 iOS Release 构建通过。
GitHub Actions 构建和标签发布成功，Release 附件及校验和通过核验，同一 CI 产物完成
Ad Hoc 签名与固定 OTA 发布。固定入口、manifest、包内版本及完整 IPA 下载核验通过；
签名包为 14,871,080 字节，SHA-256 为 `b7676c2e6f89f943a4e70ee6ea8ea0c176a5428c51069a927f387570a8596dc3`。
真机覆盖安装与数据保留未在本次验证。
实测记录见 [1.0.20 发布凭证](docs/plans/evidence/ota-publication-1.0.20-20261012.json)。

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
for an incomplete check. Pulling down on the Updates tab synchronizes all subscribed sources with uncached HTTP 200
responses, publishes the source browsing cache, then compares versions from that same snapshot.
For sources with saved management credentials, this update check first starts remote synchronization and
clears GitHub release caches and waits for parsing to finish; remote failures remain visible
as an incomplete check.
Cancelled checks retain pending updates and leave the source cache and completed-check date
unchanged; they do not start automatic downloads and can be retried by pulling down again.
The Updates tab has no separate Check button. Source cards have no Sync capsule;
pull down on the Sources tab to refresh its catalog, or open a card to manage its source.
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

### 应用页合并与跨源更新（1.1.0 / 22）

资源库与更新合并为应用页，每个 Bundle ID 一张卡片，按最近成功签名包展示当前版本。
启用源共同选择较新版本，同版本优先当前或已选择来源；手动包和源包可共存。
软件源开关保留本地包，禁用立即重算候选并取消该源排队与下载任务；签名中的任务
保留结果且不继续安装，已发起安装保留既有流程与重试。删除远端订阅仅清理该订阅
对应包，正在使用的包延后清理。更换证书提供单个与批量入口，核对实际签名身份，
不改变版本计数；移除证书资料前保存可验证身份。详细规则和验收见
[应用页合并方案](docs/plans/application-tab-merge.md)。

新增纯 Swift 回归可按手动回归工作流执行：AppVersion、SigningIdentity、
MachOEntitlements、SourceAccess 和 SignedSchemaMigration；现有更新、签名队列、
下载和安装清理回归已扩展到跨源、禁用与缓存场景。

2026-10-12 发布完成 1.1.0（22）：实现提交 `bf1cc03a4a62c4a0ac429ed7b8e128934cad8d8d`
的 [iOS Build Check](https://github.com/zh0ngtian/SignOs/actions/runs/38251330899) 与
[标签发布工作流](https://github.com/zh0ngtian/SignOs/actions/runs/38252981196) 均成功，
[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.0) 三个附件完整，
元数据与 SHA256SUMS 与该提交的 CI 产物一致。同一产物完成 Ad Hoc 签名及固定 OTA 更新，
保留 SignOs 自身 Bundle ID、实际签名 App ID 和钥匙串权限兼容基线。固定安装页、JSON、
manifest（构建号 22）、HEAD 及完整下载 SHA-256 验收通过。签名包大小为
14939371 字节，SHA-256 为 `9029841f440053c5a3ec81b46b235aecdd42a97c531da1ab3f9ea7dcfbcc7872`。
本次真机不可用，本地功能和界面在模拟器验收，未证明真机覆盖安装及数据、钥匙串保留。
发布凭证见 [1.1.0 OTA 核验](docs/plans/evidence/ota-publication-1.1.0-20261012.json)，
界面验收见 [模拟器记录](docs/plans/evidence/apps-merge-ui-20261012/verification.json)。

### 发布协调本机部署与批次恢复（1.1.2 / 24）

2026-10-13：独立协调器 0.1.3 已部署为本机登录启动的 LaunchAgent；通用规则继续维护在
canonical 全局 AGENTS.md，项目配置和恢复命令见 [发布协调说明](docs/release-coordination.md)。
不同仓库、应用或服务、环境独立协调；SignOs 批次统一完成 GitHub Release 和固定 OTA。

原 1.1.1（23）冻结批次在 CI 成功后因 `gh run download` 不支持 `--clobber` 失败，
保留原批次、提交、构建与诊断。关联修复批次 `bcf7951a-fc48-41bc-aaf3-3ea101335ad8`
继承原任务，修复产物下载并分配 1.1.2（24），最终提交为
`3884f1f38e844d506d0b121bb94ee262f845984f`。
[main 构建](https://github.com/zh0ngtian/SignOs/actions/runs/38287059977) 和
[标签发布](https://github.com/zh0ngtian/SignOs/actions/runs/38288244949) 均成功；
本批只做一次合并后的本地构建及一次正式 main 构建，标签复用同一 IPA。
[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.2) 三个附件已逐字节
核对同批次 CI 产物；同一未签名 IPA 完成 Ad Hoc 签名并更新
[固定 OTA 安装页](https://192.168.123.79:8769/channels/signos/current/install.html)。
固定入口、manifest 构建号 24、包身份、完整 HTTPS 下载及 SHA-256 独立回验通过。
签名 IPA 大小 14939279 字节，SHA-256 为
`2a0177b93024a6ef7bebac161557dc55bd6be42c3a578a4a7e2a1a1626cf3694`。

原任务为 `recovered`，修复任务为 `complete`，共同读取成功子批次的凭证；原批次仍为
failed。公开字段、CI run、产物散列及耗时分布见
[共同发布凭证](docs/plans/evidence/release-batch-1.1.2-20261013.json)。
本次改动为发布基础设施及其验证输入，未执行真机覆盖安装与数据保留验收。

### 软件源安装按钮统一（1.1.3 / 25）

2026-10-13：未下载与已有签名包待安装的“安装”按钮共用灰底、主题色文字的胶囊，
颜色、内边距和至少 44pt 点击高度一致；点击仍分别执行获取包与直接安装。
浅色、深色及大字号的生产组件模拟器截图验收和 6 项安装状态回归已通过。

原始开发提交 `0edc9c3039b8b553a1816522bcc3f4c60862f20f` 经协调器整合后，
因本机 LicensePlist 和 IDevice 缓存缺失产生两次 prepare 失败；按原固定依赖校验和
恢复后，关联子批次 `e0ee500e-cc0d-4ec7-ba7d-dae6e30a35a8` 完成本地 Release
构建与发布回归，冻结提交 `a63cba491b3d2ac611f7de9cb15a7aec07d8d312`。
[main 构建](https://github.com/zh0ngtian/SignOs/actions/runs/38331953189)与
[标签发布](https://github.com/zh0ngtian/SignOs/actions/runs/38332679878)均成功，
[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.3)附件与同批次 CI
产物校验通过，同一产物完成 Ad Hoc 签名和固定 OTA 发布。

[固定 OTA 安装页](https://192.168.123.79:8769/channels/signos/current/install.html)、
manifest、版本 / 构建号、完整下载和独立验签通过；签名包 14,939,189 字节，SHA-256 为
`67f9e1157501914f3adcd48888278aa0783cb6c33a7e9f66b4e7ec1a63484e53`。
原始任务为 recovered，两次失败批次及诊断保留。真机覆盖安装与数据保留未验证。
[共同发布凭证](docs/plans/evidence/release-batch-1.1.3-20261013.json)记录参与提交、
恢复链、冻结提交、两个 workflow run 和双渠道验收结果。

### 可更新页跨版本日志与发布时间（1.1.5 / 27）

2026-10-13：可更新卡片列出当前来源版本之后、目标版本以内的全部来源日志，
按版本从新到旧排列，沿用现有分隔线；每条软件源右侧显示该版本发布时间。
缺失日期或日志有明确占位，旧格式单版本源保持可用。软件源页面发起更新时复用
匹配的已检查候选，保留跨版本日志。更新管理器回归、完整模拟器构建及浅色、深色、
大字号界面验收通过，记录见 [界面验收](docs/plans/evidence/update-history-20261013/verification.json)
和 [入口回归](docs/plans/evidence/update-history-20261013/candidate-preservation.json)。

初版 1.1.4（26）与入口修复 1.1.5（27）由协调器分别冻结并完成双渠道发布，
凭证见 [1.1.4](docs/plans/evidence/release-batch-1.1.4-20261013.json)
和 [1.1.5](docs/plans/evidence/release-batch-1.1.5-20261013.json)。最终冻结提交
`b1a460ba3b65632d62b951ab61264c76f39a7ba4` 的
[main 构建](https://github.com/zh0ngtian/SignOs/actions/runs/38371208139)、
[标签发布](https://github.com/zh0ngtian/SignOs/actions/runs/38372584110)均成功，
[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.5)附件与同提交的 CI 产物一致；
[固定 OTA 安装页](https://192.168.123.79:8769/channels/signos/current/install.html)、manifest、包版本与构建号、
完整 HTTPS IPA 下载及 SHA-256 校验通过。签名包 14945639 字节，SHA-256 为
`45b6c92b00c75ea70db146a380ae8cbe990ce5f1e30e7e0820570d246af68462`。本次功能按模拟器范围验收，未验证真机覆盖安装及数据保留。


### 软件源添加与管理入口收敛（1.1.7 / 29）

2026-10-13：添加页仅负责通过公开 URL、导入或推荐源添加；需要管理时进入已添加源的
设置填写 Token。普通静态源通过公开健康接口识别后隐藏齿轮；管理页移除“订阅到 SignOs”、
“分享软件源地址”和二级“软件源设置”。源卡片可长按移除并二次确认。管理能力识别、订阅、
源访问回归与浅色/深色/最大辅助字号的完整模拟器界面验收通过，见
[界面记录](docs/plans/evidence/source-management-entry-20261013/verification.json)。

错误 SHA 登记通过协调器 0.1.4 的显式更正恢复，原记录保持不变；1.1.6（28）的正式构建
实际成功，但查询 GitHub 状态时遇到 EOF 导致批次停止。关联修复增加只读查询的有限重试，
25 项发布回归与独立复查通过，以更高版本 1.1.7（29）交付。冻结提交
`f8db33d0e87feee4bac4bfbdbc4408d43b561137` 的
[main 构建](https://github.com/zh0ngtian/SignOs/actions/runs/38379410304)与
[标签发布](https://github.com/zh0ngtian/SignOs/actions/runs/38380555679)均成功；
[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.7)的 IPA、元数据和
SHA256SUMS 核对通过，更新日志已使用中文列出本版实际变化。

[固定 OTA 安装页](https://192.168.123.79:8769/channels/signos/current/install.html)、manifest、
包版本/构建号及完整 HTTPS IPA 独立回验通过。签名包 14,938,624 字节，SHA-256 为
`6a895c075c342c091317886876556479b270df9c2813032ab78084f452c11ee3`。
四个关联任务共用 [成功子批次凭证](docs/plans/evidence/release-batch-1.1.7-20261013.json)，
历史失败批次和产物保留。验收范围为本地回归与模拟器，未执行真机覆盖安装及数据保留验收。


### 日志查看与导出发布核验（1.1.8 / 30）

2026-10-13：新增「设置 → 日志」，支持诊断与活动记录查看、搜索、级别筛选、完整详情复制和
当前结果文本导出。日志本机限量保存，凭据脱敏，旧活动只迁移一次，清空操作保留原活动页。
日志核心严格 Swift 6 回归、真实下载管理器回归、完整模拟器构建和页面验收通过。
[正式 main 构建](https://github.com/zh0ngtian/SignOs/actions/runs/38396474062) 与
[标签发布](https://github.com/zh0ngtian/SignOs/actions/runs/38397939670) 均成功，
[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.8) 三个附件已核对并填写具体中文更新说明。
固定 OTA 页面、manifest、完整 IPA 的版本 1.1.8、构建号 30 与 SHA-256 已在线回验。
[共同批次凭证](docs/plans/evidence/release-batch-1.1.8-20261013.json) 记录冻结提交及两渠道结果。
功能验收使用 iPhone 17e / iOS 26.5 模拟器；本次没有进行真机覆盖安装或数据保留验收。


### 应用页下拉刷新取消修复（1.1.9 / 31）

修复应用页下拉检查更新时，页面检查状态变化导致刷新任务被取消、显示「更新检查已取消」并保留旧版本结果的问题。
刷新动作直接引用原有共享管理器，继续等待现有检查流程；进度显示、同步顺序和取消传播保留。
最新代码在 iOS 27 模拟器完成修复前/后对照，并以合成本地 1.1.3 记录取得真实软件源中的 1.1.8 候选；
更新管理器回归、Debug 与设备 Release 构建、发布合同检查及独立审查通过。

协调器以 1.1.9（31）完成双渠道交付：冻结提交 `7017b01af342d386e13c4556ffbfd2c6d1c856ed` 的
[main 构建](https://github.com/zh0ngtian/SignOs/actions/runs/38430616460)与
[标签发布](https://github.com/zh0ngtian/SignOs/actions/runs/38432787151)均成功，
[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.9)附件匹配同提交的 CI 产物。
[固定 OTA 安装页](https://192.168.123.79:8769/channels/signos/current/install.html)、manifest 及完整 IPA 已回验；
Ad Hoc 签名包为 14,986,999 字节，SHA-256 `c5e2c277869a8f1276d906ec1da7f39452aa19d8f401d30bbe9148db4c394a1a`。
现有软件源已同步到 1.1.9（31），使用中文更新说明，未新增签名包归档渠道。
[发布凭证](docs/plans/evidence/release-batch-1.1.9-20261014.json)记录实际验收范围；未进行真机覆盖安装和数据保留验收。


### 2026-10-14 应用刷新任务归属修复

1.1.11（构建 33）将更新检查交给管理器持有，页面重绘或切到软件源、设置后仍会完成检查。
连续下拉等待同一次检查；普通后台检查进行时的手动刷新会在结束后补做远端同步。
在 iOS 27 模拟器的 SDK 26.5 兼容控制场景中验证连续下拉与切页，三个场景均成功完成 7 个远端同步任务。
正式 Xcode 26.6 / iOS 26.5 SDK 的 main 与标签工作流成功，GitHub Release 和固定 OTA（1.1.11/33）共同交付，完整下载及签名回验通过。
软件源同包同步现会更新已编辑的日志，40 项服务回归及真实 HTTPS 中文日志回验通过；历史和已验证包散列保留。
详情与实际范围见[实施及验收记录](docs/plans/owned-update-refresh.md)和[共享发布凭证](docs/plans/evidence/release-batch-1.1.11-20261014.json)。

### 2026-10-14 应用按软件源更新时间排序

1.1.12（构建 34）将应用 Tab 改为按软件源当前版本的发布时间从新到旧排列，全部、可更新、待安装和搜索结果共用顺序。多源应用取启用且未删除订阅的当前候选中最新的发布时间；不使用本地导入、重新签名或历史旧版本日期。缺少日期的应用置后，同日期按名称和 Bundle ID 稳定排列。
模拟器完整应用构建、启动及真实更新管理器排序回归通过，覆盖已是最新版、暂停更新、多源刷新、来源关闭和删除订阅。
冻结提交 `1697e4fcc63020597e0a95662a8244f45344c3ec` 的 [main 构建](https://github.com/zh0ngtian/SignOs/actions/runs/38503192501)与[标签发布](https://github.com/zh0ngtian/SignOs/actions/runs/38503970102)均成功；[GitHub Release](https://github.com/zh0ngtian/SignOs/releases/tag/v1.1.12)附件与同提交 CI 产物一致。
[固定 OTA 安装页](https://192.168.123.79:8769/channels/signos/current/install.html)、manifest、版本与完整签名 IPA HTTPS 下载回验通过，签名包为 14,991,846 字节，SHA-256 `0d35f323fab3dd09a99ff1ea591e15c842b5a8d6d33aefa14696f298c3eef2b2`。
现有软件源同步到 1.1.12（34），本版具体中文日志和原 CI IPA 完整散列已通过实际客户端 User-Agent 的 HTTPS 回验。
[共同发布凭证](docs/plans/evidence/release-batch-1.1.12-20261014.json)保留实际验证结果；本次未进行真机覆盖安装和数据保留验收。

### 2026-10-14 软件源主动启用与禁用

1.1.13（构建 35）补齐软件源卡片长按菜单的“启用软件源”／“禁用软件源”，菜单根据当前本机状态切换。已有禁用状态保留，升级后可直接长按启用，无须删除后重加；重新启用自动检查更新，禁用保留本地包，移除确认入口仍在。辅助功能提示补充了长按操作说明。

本地模拟器和 iphoneos Release 构建、SourceAccess 与安装阶段回归、独立复核通过；iOS 27.0 模拟器验收了两向切换、状态提示和重启持久化。批次 `bebb8e35-503f-4094-a455-40275d736f19` 的冻结提交 `769df76610e881971fa3a974a3caa24e39c80db0` 已通过 main 构建与整个标签工作流，并完成 GitHub Release / OTA 同产物发布、完整下载及独立验签。固定入口、manifest 和 Release 附件再次回验一致；真机覆盖安装与数据保留未验证。详见 [1.1.13 批次发布凭证](docs/plans/evidence/release-batch-1.1.13-20261014.json) 和 [菜单验收记录](docs/plans/evidence/source-enable-menu-20261014/verification.json)。

2026-10-14 补齐 1.1.13 的具体中文更新说明：原自动发布只有英文模板与 OTA 批次说明，中文变更未同步到发布渠道。现已修改本版 GitHub Release 正文并同步现有软件源订阅，普通与兼容清单的客户端 User-Agent 回验通过；原 IPA 摘要、下载地址、应用元信息和验包信息保留，版本与标签未变。OTA 批次说明本次未修改，日志输入及发布校验机制待确认后调整。
