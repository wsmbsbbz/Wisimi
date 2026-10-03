# MP4 播放设计

## Context

动机见 proposal.md。目录、队列构建及恢复目前仅允许 type == audio；WorkAudioPlayer 已管理 AVPlayer、字幕、旁白、后台音频、失败重试和睡眠定时器。目标工具链为 Xcode 27 / iOS 27。

## Goals / Non-Goals

目标：画面与音频共享唯一播放实例和控制入口，避免全屏出现独立状态；自适应小屏、横屏与平板。
非目标：转码、下载管理、画中画、额外格式保证、服务端改动。

## Decisions

1. TrackNode 增加 isVideo、isPlayable、playbackURL；识别 video 类型或非目录的 .mp4 文件名。优先视频分类，流地址优先于下载地址。音频与视频共用同目录 playableTracks，恢复复用相同规则。
2. 保留 WorkAudioPlayer 名称和现有职责，本次不做无关全仓重命名。向画面暴露只读 AVPlayer 引用。AVPlayerLayer 仅展示画面，所有控制继续调用播放器方法，避免系统控件直接修改 AVPlayer 导致字幕旁白和播放意图不同步。
3. 播放器视频画面用黑底和 resizeAspect 完整显示，在可用空间内适配任意比例。全屏使用相同画面及进度、暂停、切换、错误和睡眠状态；进入全屏时卸载内嵌画面，退出时回到原进度。切换到音频自动退出全屏。
4. 视频画面不承担字幕切换手势，工具栏独立提供字幕入口。字幕列表沿用点击跳转和旁白状态；全屏画面只在字幕有效时间内显示当前字幕，点击画面可隐藏/显示控制。
5. audiovisualBackgroundPlaybackPolicy = continuesIfPossible；场景进入后台时解绑 AVPlayerLayer，回前台重连。解除画面不会暂停 AVPlayer；继续使用已有音频后台模式及远程控制。
6. 用本机 AVAssetWriter 生成短 MP4 验证素材，覆盖真实视频解码、混合队列、重试、定时器和恢复上下文。Debug 入口提供画面验证，不把素材加入 Release 包。

## Risks / Trade-offs

- MP4 是容器，编码或服务器无法访问会导致播放失败 → 使用现有明确错误与重试，不引入转码。
- 同时连接两块视频画面可能抢占输出 → 全屏期间移除内嵌画面；销毁和后台阶段解绑。
- 长标题、大字号、横屏空间不足 → 视频画面弹性布局，全屏画面占满可用空间，控制区叠加并支持点击画面隐藏，标题限制行数，标题限制行数。

## Migration Plan

无需数据迁移；更新 Debug/Release 版本为 1.2.0、构建号 5。验证后推送 main 和 v1.2.0，复用现有 iOS Release 流程生成 IPA。
