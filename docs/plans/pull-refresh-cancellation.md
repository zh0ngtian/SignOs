# 应用页下拉刷新取消修复

2026-10-14 用户授权在最新代码上应用并发布已定位的修复。范围仅为 `LibraryView.swift` 的刷新闭包；检查流程、远端同步协议和任务管理方式保持原有约定。

## 根因与方案

原闭包引用页面的 `@ObservedObject checker`，捕获 `LibraryView`。检查开始时 `isAutoChecking` / `isChecking` 更新触发页面重算，SwiftUI 将闭包识别为新的刷新动作。iOS 27 的 `PlatformRefreshControlProxy.configuration.didSet` 随后调用 `swift_task_cancel` 取消原检查任务。网络请求收到取消后，`UpdateManager` 转换为 `CancellationError` 并保留旧结果。

把闭包中的调用改为 `AutoUpdateManager.shared.checkNow(notifyWhenClean: false, syncManagedSources: true)`，避免刷新动作捕获变化中的页面值。v1.1.3 Debug 的原代码、单行对照及恢复原代码三次实验已确认根因；本次在最新 main 上重新验证。

## 执行与验收

- [x] 最新 main 的 Debug 包在 iOS 27 模拟器下拉后显示取消，捕获取消栈作为修复前证据。
- [x] 替换刷新闭包的一处管理器引用；在同一模拟器确认刷新入口执行、检查完成且无取消提示。
- [x] 运行更新管理器回归，检查同步顺序、取消传播、失败保留旧结果与重试。
- [x] 完成设备 Release 构建、发布合同回归、工作流核对及 diff 检查。
- [ ] 提交并 push 开发分支，登记 ready，等待协调器的 GitHub Release 与固定 OTA 共同凭证。

功能验收为模拟器运行；不据此声称真机覆盖安装与数据保留已验证。诊断原始数据和 Debug 包留在仓库外，只提交不含设备或签名资料的核验摘要。

本地验收摘要见 [核验记录](evidence/pull-refresh-cancellation-20261014.json)。独立只读审查确认同一 MainActor 单例、检查参数、直接 await、原有取消传播与进度显示均保留，无发布前阻塞问题。发布结果待协调器共同凭证补齐。
