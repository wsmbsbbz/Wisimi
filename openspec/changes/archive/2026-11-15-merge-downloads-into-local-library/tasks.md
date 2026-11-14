## 1. OpenSpec 规格与数据模型整合

- [x] 1.1 创建并同步 `local-work-library` 与 `local-downloads` 的中文 OpenSpec 变更和规格文件。
- [x] 1.2 在 `LocalWorkLibrary` 中扩展 `LocalWorkEntry`（新增 `onlineWorkID` 与 `byteCount`）并导出 `LocalWorkManifest`，实现文件存在性校验、目录失效通知与总占用字节统计。
- [x] 1.3 清理 `WorkSource` 与 `WorkDetailPageState` 中的离线下载快照和本地文件优先替换旁路。

## 2. 重构下载引擎直写本地库

- [x] 2.1 重构 `DownloadStore`，使下载文件直接落盘至 `LocalWorkLibrary` 的 `<localWorkID>/files/` 目录，同步维护 `<localWorkID>/index.json` 与 `.downloads.json`，支持同作品合并下载、封面自动保存、空间校验、单文件/整作品删除与旧 `Downloads/` 目录清理。
- [x] 2.2 精简 `DownloadPresentation`，移除旧分组与筛选类型，保留 `DownloadSummary` 并补充卡片角标状态计算。

## 3. 界面整合与下载管理移除

- [x] 3.1 移除 `DownloadsView.swift`、`WorksRoute.downloads` 及主页与在线详情右上角的「下载管理」按钮，更新 `WorksListView` 和 `WorkAudioPlayer`。
- [x] 3.2 解耦 `TrackNodeRow` 对全局 `DownloadStore` 的直接依赖；更新 `TrackBrowserView` 与 `WorkDetailView`，支持本地副本提示横幅、已下载文件防重选、前往「本地」跳转及本地下载作品的行级进度与操作。
- [x] 3.3 更新 `WorkRow`、`LocalWorksView` 和 `LocalWorkDetailView`，实现卡片未完成角标、顶部全局下载状态条、本地总占用统计、来源展示与在线跳转、作品级下载控制、单文件确认删除和实时刷新。

## 4. 自检、测试与文档验证

- [x] 4.1 更新 `DownloadSelfCheck.swift`、`DebugDownloadFixture.swift`、`scripts/check-downloads.sh`、`Tests/RefactorChecks.swift` 与 `README.md`。
- [x] 4.2 运行 `check-state.sh`、`check-downloads.sh`、`check-refactor.sh`（覆盖率门禁 ≥ 80%）及 `xcodebuild` iOS 构建并全部通过。
