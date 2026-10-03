# MP4 播放支持

## Why

作品目录中的 MP4 文件目前不能播放，用户无法在应用内观看作品视频。视频需要沿用现有收听体验，让字幕、中文旁白、进度恢复和定时停止保持一致。

## What Changes

- 识别 API 视频类型及大小写不敏感的 MP4 文件，与同目录音频组成按目录顺序排列的播放队列。
- 视频文件显示视频图标及类型；播放器显示按原始比例完整适配的画面，提供全屏和字幕入口。
- 共用 AVPlayer 和应用播放控制，支持切换、重试、进度恢复、字幕旁白及睡眠定时器；离开画面继续收听。
- 补充本地 MP4 验证，更新说明，发布 1.2.0 小版本到 GitHub。

## Capabilities

### New Capabilities

- `video-playback`: 视频识别、混合队列、画面展示、全屏与统一播放生命周期。

### Modified Capabilities

无。

## Impact

影响 TrackNode、作品文件目录、WorkAudioPlayer、PlayerView、验证脚本、版本字段及发布说明。复用 Apple AVFoundation，无新增依赖或服务端接口。
