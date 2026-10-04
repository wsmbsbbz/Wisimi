# 实施任务

## 1. 下载与持久化

- [x] 1.1 实现系统后台下载、原子索引、结果校验、任务恢复与去重，以本地 HTTP 自检验证成功、失败和恢复。
- [x] 1.2 实现暂停、继续、重试和删除，以自检验证状态及文件同步，并在 README 说明后台限制。

## 2. 目录与离线访问

- [x] 2.1 实现跨目录多选、文件夹递归全选和大小统计，以嵌套目录自检验证选择集合。
- [x] 2.2 实现下载管理、目录状态与入口，通过 iOS 构建和模拟器不同尺寸检查布局。
- [x] 2.3 接入本地媒体、字幕、图片和离线目录，以本地文件命中与重启检查验证，并更新 README。

## 3. 集成与发布

- [x] 3.1 运行已有状态自检及 Debug/Release 构建，记录结果并通过 OpenSpec 严格校验。
- [x] 3.2 更新 1.3.0 版本与更新记录，提交并推送 main 和 v1.3.0，确认远端提交与发布产物。

## 验证结果

- `sh scripts/check-state.sh` 与 `sh scripts/check-downloads.sh` 通过；额外延迟 HTTP 服务启动 12 秒的自检通过。
- Debug 模拟器与 Release 真机目标构建通过；iPhone 17e 和 iPad mini 目录多选及状态布局检查通过，本地 MP4 真实解码与缓存字幕集成自检通过。
- [远端 CI](https://github.com/wsmbsbbz/Wisimi/actions/runs/37177434772) 与 [Release 工作流](https://github.com/wsmbsbbz/Wisimi/actions/runs/37177562486) 均成功。
- [v1.3.0](https://github.com/wsmbsbbz/Wisimi/releases/tag/v1.3.0) 已发布；远端下载 IPA 校验压缩包及版本 1.3.0 / build 6 通过，SHA256 为 `01386b2b05837aaff5cf35036fcaa89d24db0905df6544a1b8919dcc37b0de8f`。
