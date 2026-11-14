## Why

用户需要在 Wisimi 中整理和收听自己的 ASMR 文件。作品身份与媒体读取目前绑定 asmr.one，需要让本地与未来的作品来源共用详情和播放流程。

## What Changes

- 首页新增本地库，可选择文件夹并复制导入，在离线时浏览、播放及恢复进度。
- 作品根目录可以通过可选的 `wisimi.json` 提供标题、社团、时长、评分、销量、作品编号、标签、声优及封面。缺少元信息时由目录与文件生成基本详情。
- 使用带来源的作品标识与统一的作品读取、资源解析接口，保留 asmr.one 的在线能力与下载数据。

## Capabilities

### New Capabilities

- `local-work-library` 负责本地导入、元信息、浏览、播放和管理。

### Modified Capabilities

## Impact

影响作品导航、详情、目录、封面与播放器。导入使用 iOS 系统文件选择器与应用内存储。
