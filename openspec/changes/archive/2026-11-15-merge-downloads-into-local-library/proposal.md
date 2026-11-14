## Why

目前在线下载与本地导入各自维护存储目录、作品身份与管理界面：下载后的作品只能在独立「下载管理」页面中查看，离线时仍以在线作品详情形态呈现；主页右上角与在线详情右上角均额外暴露了下载管理入口。为提供统一的本地作品管理体验，需要将在线下载直接并入「本地」作品库，移除独立的「下载管理」页面及入口。

## What Changes

- **下载并入本地作品库**：在线作品详情提交下载后立即在 `LocalWorkLibrary` 中创建或合并为一部本地作品（`WorkReference.local`），封面与所选文件直接落盘到本地库目录，单文件下载完成后即可立即播放或查看，未完成作品在本地卡片与详情中展示下载进度和状态。
- **合并多次下载与局部目录**：同一在线作品（按 `asmr.one` 作品 ID 识别）多次选择文件下载时合并到同一部本地作品，目录树只包含已选文件（含自动附带的匹配字幕）并保持原目录结构。
- **移除「下载管理」入口与页面**：删除主页与在线详情右上角的「下载管理」按钮，删除 `DownloadsView`、相关分组筛选与 `WorksRoute.downloads` 路由。
- **职责迁移到本地列表与本地详情**：
  - 「本地」列表顶部提供未完成任务的全局下载状态条（支持全部暂停、全部继续、重试失败）以及本地总占用统计。
  - 本地详情区分来源（「来自 asmr.one · RJxxxx」并提供「查看在线详情」入口，或「从文件导入」），提供作品级下载管理、单文件暂停/继续/重试/删除以及下载副本删除确认。
- **移除在线详情本地旁路，不做旧下载兼容迁移**：在线详情不再用下载快照离线打开，也不再将在线播放或图片替换成本地缓存文件，改为在已有本地副本时于目录上方展示横幅引导前往本地作品；应用初始化时直接清理旧版 `Application Support/Downloads` 目录。

## Capabilities

### New Capabilities

### Modified Capabilities

- `local-work-library`：本地作品库同时纳管本地导入与在线下载来源的作品，新增下载进度角标、全局下载状态条、本地总占用统计、来源展示与在线详情跳转、单文件下载控制及单文件删除。
- `local-downloads`：下载目标与管理界面并入本地作品库；移除独立下载管理页面、离线在线快照与在线本地优先替换，增加提交前空间校验、封面保存、同作品合并下载及与本地库一致的重启恢复与清理能力。

## Impact

- 数据与存储：`LocalWorkLibrary`、`LocalWorkManifest`、`LocalWorkEntry`、`DownloadStore`、`WorkSource`、`WorkDetailPageState`。
- 导航与界面：删除 `DownloadsView` 与 `WorksRoute.downloads`，修改 `WorksListView`、`WorkDetailView`、`LocalWorksView`、`TrackBrowserView`、`TrackNodeRow`、`WorkRow`、`WorkAudioPlayer`。
- 测试与文档：`DownloadSelfCheck`、`DebugDownloadFixture`、`RefactorChecks`、`scripts/check-downloads.sh`、`README.md`。
