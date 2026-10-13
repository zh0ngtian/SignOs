# 软件源添加与管理入口收敛

用户于 2026-10-13 确认：先用公开 URL 添加软件源，需要管理时再在该源设置中填写 Token；不支持管理的源隐藏设置齿轮；移除管理页中的“订阅到 SignOs”和二级“软件源设置”，并按后续要求移除“分享软件源地址”。

实现先按 `CloudSourceEndpoint.managementURL(for:)` 筛选地址，再以公开 `/health` 的 `signos-source-aggregator` 服务标志确认能力，避免普通静态 `/source.json` 被误判。探测不发送 Token；服务无法确认时暂不显示齿轮，重新进入可重查。不增加服务端能力或改变 Token 保存、订阅同步、源身份检查。管理页仅接受已添加源及其管理地址，继续提供 Token 连接、立即同步、订阅管理和本机移除。二级名称/简介编辑页与重复添加源逻辑一并删除。

普通源隐藏齿轮后，原先的移除入口也会消失。因此软件源列表卡片提供长按“移除软件源”与确认弹窗，沿用原有禁用和删除处理；不让普通源失去移除能力。

## 执行与验收

- [x] `SourcesAddView.swift`：删除连接管理服务的导航入口，保留 URL 添加、导入/导出与推荐源。
- [x] `SourceAppsView.swift`：把管理地址检查移到 ToolbarItem 外；普通源不创建设置按钮。
- [x] `CloudSourceManagerView.swift`：只接受已添加源，删除重复订阅、分享按钮、提示、处理函数与二级设置页；保留 Token 连接和身份核对。
- [x] `SourcesView.swift`：删除无调用者的普通源设置页；为源卡片提供带确认的移除菜单。
- [x] README 同步“添加 → 源设置 → Token”流程和普通源移除方式。
- [x] 新增 CloudSourceManagementRegression，覆盖兼容管理服务、同路径静态源、其他/无效健康响应、网络超时和无 Token 探测；运行既有 CloudSourceSubscriptionRegression，核对 Token/连接与订阅操作未退化。
- [x] 完整模拟器构建并验收添加页、普通源无齿轮及可移除、管理源 Token 页面、连接成功后的精简页面；检查深色与大字号。
- [x] 完成发布协调器要求的适配器/产物/附件回归、工作流核对和 diff 检查。

本地验证与截图见 [验收记录](evidence/source-management-entry-20261013/verification.json)。开发提交 push 后登记 ready，GitHub Release 与固定 OTA 的最终结果以发布协调器 batch receipt 为准。

这是删除和收敛现有入口的改动，运行验收覆盖生产界面，不新增仅检查源码文本的测试。
