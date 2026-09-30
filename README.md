# Wisimi

Wisimi 是一个用 SwiftUI 实现的非官方 asmr.one iOS 客户端。

asmr.one 的 Web 版在移动端已经能用，但 Wisimi 希望在它的内容基础上提供更贴近移动端和个人使用习惯的体验。

## Features

- 播放有字幕的作品时，用中文 TTS 叠加旁白（是的，我不懂日语）
- 按自己的收藏、标记和播放列表来整理作品
- 使用 asmr.one 的推荐接口获取个性化推荐
- 查看最新作品、热门作品、收藏、播放列表和推荐作品
- 搜索作品、标签、声优、社团和 RJ 号
- 按字幕、排序字段和排序方向筛选作品
- 查看作品详情、封面、评分、时长、销量、标签、声优和音轨目录
- 长按复制作品标题、标签、声优、社团、文件名和字幕；详情标题支持文字选择
- 在线播放音频，支持上一首、下一首、进度拖动、后台播放控制和播放进度恢复
- 播放器区分准备与正在播放，支持音频失败后从当前位置重试
- 睡眠定时器：15、30、60 分钟后停止或本曲结束停止，同时停止中文旁白
- 搜索、筛选和模式切换以最新请求为准；刷新失败保留已有内容并提供重试
- 读取 VTT/LRC 字幕，播放时显示当前字幕并支持点击字幕跳转
- 使用 Edge 或自备 OpenRouter 凭据生成中文旁白，支持固定模型、精选音色、表达预设、音量和模型专属语速；MiniMax 仅提供 6 种适合 ASMR 的精选女音，并额外支持固定句内停顿、呼吸、叹息、吸气、呼气、哼唱与唇音效果
- 登录 asmr.one 账号，保存 token 到 Keychain
- 标记作品状态：想听、在听、听过、重听、搁置
- 创建、编辑、删除播放列表，并把作品加入或移出播放列表

## Requirements

- macOS 27、Xcode 27 和 iOS 27 SDK
- SwiftUI
- iOS 27.0+

## Build

打开 `Wisimi.xcodeproj`，选择 `Wisimi` scheme/target 后运行。

也可以用命令行构建：

```sh
xcodebuild -project Wisimi.xcodeproj -scheme Wisimi -configuration Debug -sdk iphonesimulator build
```

## Verification

运行不依赖网络的状态与列表请求竞态自检：

```sh
sh scripts/check-state.sh
```

Debug 模拟器中设置 `WISIMI_PLAYBACK_CHECKS=1` 可运行本地音频播放与睡眠定时器集成自检；设置 `WISIMI_WORKS_CHECKS=1` 可运行列表竞态自检。`WISIMI_DEBUG_SCREEN=player` 或 `mini-player` 提供播放器预览，叠加 `WISIMI_SLEEP_TIMER=1` 显示活动定时器；`WISIMI_DEBUG_SCREEN=list-error` 显示刷新失败保留内容的场景。上述入口只存在于 Debug 构建。

## Release

`main` 分支和 PR 会在 GitHub Actions 的 `xcode-27` runner 上进行无签名 Release 构建。推送形如 `v1.0.0` 的 tag，或手动运行 `iOS Release` 并填写已有 tag，会构建未签名 `.ipa`、验证压缩包内容，并上传到 GitHub Release。

该 `.ipa` 不能直接安装，用户必须自行签名后侧载。

## Privacy and Data

- Wisimi 会直接请求 asmr.one 相关接口，作品数据来自 asmr.one。
- 登录 asmr.one 后的 token 只保存在本机 Keychain 中，不会提交到仓库，也不会由 Wisimi 上传到其他服务。
- 用户填写的 OpenRouter Token 使用 `WhenUnlockedThisDeviceOnly` 策略保存在本机 Keychain，不参与同步，也不会写入偏好设置、缓存名称或日志。
- 播放进度、TTS 设置和 TTS 临时缓存保存在本机。

## Third-party Services

- Wisimi 是非官方客户端，不隶属于 asmr.one。
- 免费兜底依赖 Microsoft Edge Read Aloud 使用的在线语音服务。该服务可能变更、限流或失效。
- 可选的付费 TTS 通过用户自己的 OpenRouter Token 直接调用，目前固定支持 `minimax/speech-2.8-turbo`、`minimax/speech-2.8-hd` 和实验性的 `google/gemini-3.1-flash-tts-preview`，不会请求动态模型目录。
- OpenRouter 调用会消耗用户自己的 credits。连接测试本身也会合成一句简短中文并产生极少量费用；实际费用、可用性、内容政策和 NSFW 接受程度由 OpenRouter 及上游模型服务商决定，Wisimi 不作保证。
- 当前 TTS 采用整句音频：Edge 和 MiniMax 缓存 MP3，Gemini 请求原始 PCM 后在本机封装为 WAV。MiniMax 通过 OpenRouter 标准 `speed` 支持 0.5x～2.0x，并使用固定、已实测的文本标签实现句内效果；不会发送未经验证的 provider 高级参数。MiniMax 音色目录只保留 6 种适合 ASMR 的女音，不提供男音。结果按模型、音色、文本、语速和表达等设置缓存在系统临时目录，缓存前和命中时都会验证音频可解析。OpenRouter 失败时仅自动回退 Edge，不会自动改用另一款付费模型。
- 请遵守 OpenRouter、Microsoft Edge 及对应上游模型服务商的服务条款和内容政策。

## Roadmap

- 更完整的播放器队列管理
- TTS 缓存管理和低延迟流式音频
- 更细的错误提示和重试体验
- 面向不同 iOS 设备尺寸的持续 UI 打磨

## License

MIT
