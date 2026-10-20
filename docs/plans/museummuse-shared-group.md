# 博物女神重签共享组合同

博物女神 `1.1.4 (10)` 的 GitHub IPA 没有 `MuseumAppGroupIdentifier`，运行时因此读取原始 `group.tech.zh0ngtian.MuseumMuse`。用户通过 SignOs 重签后，实际签名授权为证书中的另一组标识，原始组不在其中。主 App 与 Widget 无法共用刷新结果，桌面持续显示“点击刷新获取展品”。刷新按钮打开 App 是当前博物女神的正常刷新入口，并非这个缺陷。

## 适配范围与规则

- 仅适配原 Bundle ID `tech.zh0ngtian.MuseumMuse`，要求主 App 与至少一个 WidgetKit 扩展均有效；不改 Bundle ID、版本、签名 App ID、Team、钥匙串或既有签名权限。其他 App 继续原有重签流程。
- `MuseumMuseAppGroupSigning` 在 Zsign 执行前检查所有 Widget 的运行共享组，并读取本机上一份成功签名包中的运行组。输入和既有包已声明的组必须一致且获授权；即使新描述文件同时授权原始组，也保留已使用的兼容组，避免更新后切换数据命名空间。不把不获授权的既有配置悄悄替换为另一组。
- GitHub 输入未声明运行共享组时，原始描述文件使用 `group.tech.zh0ngtian.MuseumMuse`；现有私有兼容渠道使用已确定的 `group.363da22903f0409e.5`。该组对应 MuseumMuse 已有偏好前缀和文件命名空间，不从证书中的多组里任取一项。两种身份均未获授权时停止签名。
- 自定义权限文件必须包含已选定且获授权的共享组；缺失或冲突时提前报错，不覆盖用户权限文件。
- 确认全部目标和授权后，在工作副本中为主 App 与各 Widget 写入同一个 `MuseumAppGroupIdentifier`，然后调用原 Zsign 签名引擎。
- 签名返回成功后，读取各目标实际 Mach-O 权限，核对运行共享组、授权共享组和 Bundle ID；任一不一致时不移入成功签名目录、不创建成功记录，不进入安装流程。
- 保留原输入、旧签名包和已安装应用数据；本项不修改博物女神客户端或替换其 GitHub Release。

## 验证

`MuseumMuseSigningRegression` 覆盖实际 unsigned 输入形态、多组描述文件、原始组与既有组保留、两目标同步、描述文件和自定义权限拒绝、签名后授权或运行字段不符、缺少 Widget 和其他 App 隔离。已接入手动 `Full iOS Regression`，日常 CI 仍只构建。

2026-10-20 本地验证：签名适配回归、6 项安装状态回归、14 项适配器回归、7 项产物回归、7 项附件回归和 13 项中文日志回归通过；SignOs Release 设备构建通过。用固定版本的同一 Zsign 库重签实际博物女神 1.1.4 GitHub 包，确认两个目标运行组已对齐、实际签名权限与原手机 SignOs 产物完全相同。

独立 iPhone 17 Pro / iOS 27 模拟器先复现：仅授权兼容组但未写运行字段时，App 日志显示图片获取成功，结果落入私有缓存，桌面仍占位。对同一包调用本次生产适配代码并重新安装后，实际点击刷新，东京国立博物馆“小袖 黒綸子地遠州模様”显示在桌面；共享日志确认单件候选成功后停止、Widget 成功渲染，系统日志未命中图片超限、归档或 Chrono 错误。

真机尚待验收：测试服务启动返回 LocalAuthentication Code=-2（认证被取消），没有安装测试包或将手机结果写成通过。macOS 严格验签对手机原有 Zsign 产物与本机重签产物均返回失败，因此上述 Zsign 后置结果仅证明共享配置与权限一致，不能替代独立验签或 iOS 实际安装验收。SignOs 发布和真机结果完成后另行回填。公开证据见 [验收摘要](evidence/museummuse-shared-group-20261020.json)。
