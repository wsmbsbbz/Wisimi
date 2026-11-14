## Context

此前 Wisimi 存在两套并行的离线内容机制：
1. `DownloadStore` 将下载文件以扁平 UUID 命名保存在 `Application Support/Downloads/`，以 `index.json` 记录 `workID: Int` 与 `DownloadedWork` 快照，并在 `OnlineWorkSource.cachedWork` 与 `WorkSource.resourceURL` 中以「在线作品 ID 冒充离线源」实现本地优先播放和离线打开。
2. `LocalWorkLibrary` 将用户从「文件」导入的文件夹保存在 `Application Support/LocalWorks/<uuid>/files/`，通过 `<uuid>/index.json`（包含 `LocalWorkEntry` 与 `[TrackNode]`）记录层级目录与元信息，并使用与在线首页相同的双列瀑布流展示。

## Decisions

- **统一存储位置与清单格式**：`DownloadStore` 默认目录切换为 `LocalWorkLibrary.shared.directory`（`Application Support/LocalWorks`），自身的任务队列与字节进度保存在隐藏文件 `.downloads.json`（被 `LocalWorkLibrary.loadCatalog()` 的 `.skipsHiddenFiles` 与 UUID 目录过滤自动忽略）；下载作品的媒体与封面直接落盘在 `<localWorkID>/files/<relativePath>`，并在每次变更时同步生成标准 `LocalWorkManifest` 写入 `<localWorkID>/index.json`，再通知 `LocalWorkLibrary.invalidateCatalog()` 刷新目录内存缓存。
- **提交即出现与逐文件可用**：用户在在线详情提交下载后立即写入 `<localWorkID>/index.json`，确保在没有独立下载页的情况下，用户能在「本地」中看到进度并执行暂停、继续、重试或删除；`LocalWorkLibrary.resolve` 通过检查 `<localWorkID>/files/<relativePath>` 是否存在来决定是否赋予 `file://` 的 `mediaStreamUrl`，因此已下载完成的单个文件可直接播放、预览图片或作为匹配字幕加载，未完成或缺失文件自动排除在 `playableTracks` 之外。
- **按 `onlineWorkID` 合并多次下载与封面补全**：`LocalWorkEntry` 新增 `onlineWorkID: Int?`（导入作品为 `nil`）和 `byteCount: Int64`；当同一在线作品再次提交下载时复用已有 `localWorkID`，将新选文件并入裁剪后的树结构（叶节点按 `hash ?? relativePath` 对应），已有本地文件不重复下载；首次创建时自动触发主封面下载到 `<localWorkID>/files/cover.<ext>`。下载来源作品不触发 `DLsiteMetadataClient` 同步。
- **完全分离在线与本地身份**：移除 `OnlineWorkSource.cachedWork`、`WorkDetailPageState.prepareDebugSnapshot` 和 `WorkSource.resourceURL`；在线详情不再替用户切换本地流，而是在存在对应 `onlineWorkID` 的本地作品时展示提示横幅并提供「打开本地作品」按钮。
- **移除独立页面与旧目录清理**：删除 `DownloadsView`、`WorksRoute.downloads`、`DownloadFilter` 与 `DownloadWorkGroup`；默认初始化时直接删除遗留的 `Application Support/Downloads/` 目录，不做兼容迁移。

## Risks / Trade-offs

- **同 RJ 既导入又下载**：本期仅在在线下载来源之间按 `onlineWorkID` 合并去重；如果用户手动导入了一部含相同 RJ 号的文件夹又从在线下载，本地库中会出现两部作品（各自拥有独立 `UUID`）。后续如需合并，可在本地详情或导入流程增加按 `catalogCode` 的查重提示。
- **清单与任务状态并发刷新**：`DownloadStore` 运行在 `@MainActor`，`LocalWorkLibrary` 为 `actor`；`DownloadStore` 通过递增 `catalogRevision` 并异步调用 `LocalWorkLibrary.invalidateCatalog()` 触发界面重读磁盘清单。每次清单刷新都会重新读取当前页和正在浏览的本地详情，且通过 `resolvingDirectoryPath` 保留用户当前打开的子目录路径，不影响 `WorkAudioPlayer` 正在播放的队列实例。
- **在线目录树变更**：同一作品二次补下文件时，如果服务端重命名或调整了目录，将以最新目录结构为准并保留旧目录中仍存在的已选叶节点。
