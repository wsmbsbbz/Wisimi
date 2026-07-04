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
- 在线播放音频，支持上一首、下一首、进度拖动、后台播放控制和播放进度恢复
- 读取 VTT/LRC 字幕，播放时显示当前字幕并支持点击字幕跳转
- 使用 Edge 在线 TTS 生成中文旁白，支持混音开关、音量和最大语速设置
- 登录 asmr.one 账号，保存 token 到 Keychain
- 标记作品状态：想听、在听、听过、重听、搁置
- 创建、编辑、删除播放列表，并把作品加入或移出播放列表

## Requirements

- Xcode 26.3 或更新版本
- SwiftUI
- iOS 27.0+

## Build

打开 `Wisimi.xcodeproj`，选择 `Wisimi` scheme/target 后运行。

也可以用命令行构建：

```sh
xcodebuild -project Wisimi.xcodeproj -scheme Wisimi -configuration Debug -sdk iphonesimulator build
```

## Release

推送 `v*` tag 或手动运行 `iOS Release` GitHub Actions workflow 会生成未签名 `.ipa` 并上传到 GitHub Release。

该 `.ipa` 不能直接安装，用户必须自行签名后侧载。

## Privacy and Data

- Wisimi 会直接请求 asmr.one 相关接口，作品数据来自 asmr.one。
- 登录后的 token 只保存在本机 Keychain 中，不会提交到仓库，也不会由 Wisimi 上传到其他服务。
- 播放进度、TTS 设置和 TTS 临时缓存保存在本机。

## Third-party Services

- Wisimi 是非官方客户端，不隶属于 asmr.one。
- 在线 TTS 功能依赖 Microsoft Edge Read Aloud 使用的在线语音服务。该服务可能变更、限流、失效，使用时也应遵守对应服务条款。

## Roadmap

- 更完整的播放器队列管理
- TTS 声音、语言和缓存管理
- 更细的错误提示和重试体验
- 面向不同 iOS 设备尺寸的持续 UI 打磨

## License

MIT
