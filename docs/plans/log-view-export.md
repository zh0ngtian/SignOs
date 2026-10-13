# 日志查看与导出

用户已确认新增「设置 → 日志」，汇总诊断日志和活动记录，支持搜索、级别筛选、完整详情与文本导出。

- 沿用设置页图标和系统 List / NavigationStack。列表按时间倒序，级别有文字标识；详情保留换行并支持选择复制。支持空状态、搜索无结果、读写或导出失败提示。
- `AppLogStore` 负责串行记录、原子持久化、筛选与文本格式。日志存于 Application Support，最多 1000 条、2 MiB，单条正文最多 16 KiB；超限删除最早记录。已有最多 200 条活动记录仅迁移一次，后续活动直接同步记录，原活动页继续保留。
- `AppLogger` 将应用原有 Signing / Misc 系统日志同时写入本机日志，补充启动、导入、签名、下载关键结果。URL 用户信息、查询参数、fragment、常见 Token / 密码字段先脱敏，再进入持久化或分享文件。不收集证书内容或设备 UDID，不截获全局 stdout 或第三方底层输出。
- 导出当前筛选结果的固定快照，按时间正序，以 UTF-8 `.txt` 文件通过系统分享菜单保存或发送。包含 SignOs 版本、构建号、系统版本、导出时间和筛选范围。分享期间保持文件，关闭分享菜单后仅删除本次临时导出文件。
- 日志支持确认后清空；清空不影响活动页、历史签名包、发布凭证或安装清理状态。写入失败保留内存日志并显示错误；损坏的存储保留为独立文件，不静默丢弃证据。

## 实施与验证计划

1. [x] 新增 `Tests/AppLogRegression.swift`，以真实临时文件测试重启恢复、条数/容量上限、并发写入、一次性活动迁移、脱敏、组合筛选、全文导出和错误处理；先确认新增 API 尚不存在。
2. [x] 新增 `Feather/Utilities/AppLogStore.swift` 与 `AppLogger.swift`，实现存储、过滤、导出和系统日志双写；运行 `xcrun swiftc Feather/Utilities/AppLogStore.swift Feather/Utilities/LogExportFile.swift Tests/AppLogRegression.swift -o /tmp/signos-log-regression && /tmp/signos-log-regression`。
3. [x] 修改 `Logger++.swift`、`ActivityLog.swift`、`FR.swift`、`DownloadManager.swift` 和启动入口；为独立下载回归编译脚本补入日志依赖。
4. [x] 新增 `Feather/Views/Settings/Logs/LogsView.swift`；设置页加入入口。模拟器验收搜索、筛选、详情、分享、取消后文件清理、重启、清空及浅色/深色/大字号。
5. [x] 更新 README 使用说明；独立代码审查，运行日志回归、下载回归、发布适配器/产物/附件回归和 `git diff --check`。
6. [ ] push 开发分支并核对远端 SHA，以验证记录提交协调器 ready；读取成功批次凭证，核对最终提交、main / 标签 run、Release 和固定 OTA 入口及实际版本/构建号。

不修改安装完成判定、旧包保留策略或外部服务。模拟器验收不代表真机覆盖安装或数据保留验收。
