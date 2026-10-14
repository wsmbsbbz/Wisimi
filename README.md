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
- 文件多选与递归全选当前文件夹，批量下载音视频、匹配字幕、图片及其他目录文件
- 下载管理：按作品展示封面、所选文件完成数量与汇总进度，支持全部/未完成/已下载筛选和页内展开；可管理单文件、整部作品及全部任务，删除前确认；目录直接标识已缓存文件
- 从下载管理打开本地作品目录，断网可播放已缓存音视频并读取本地字幕、查看已缓存图片
- 在线播放音频与 MP4 视频，同目录混合队列支持上一首、下一首、精确进度拖动、后台播放控制和播放进度恢复
- MP4 播放器完整按比例显示视频，支持全屏观看及独立字幕入口；返回目录后可继续收听视频声音
- 播放器区分准备与正在播放，支持音频失败后从当前位置重试
- 睡眠定时器：15、30、60 分钟后停止或本曲结束停止，同时停止中文旁白
- 搜索、筛选和模式切换以最新请求为准；刷新失败保留已有内容并提供重试
- 读取 VTT/LRC 字幕，播放时显示当前字幕并支持点击字幕跳转
- 使用 Edge 或自备 OpenRouter 凭据生成中文旁白，支持固定模型、精选音色、表达预设、音量和模型专属语速；MiniMax 仅提供 6 种适合 ASMR 的精选女音，并额外支持固定句内停顿、呼吸、叹息、吸气、呼气、哼唱与唇音效果
- 作品详情展示首页同款的相似作品瀑布流，默认四个作品，可页内展开、收起和翻页；空结果隐藏，无需登录，浏览保持播放队列与返回位置
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
sh scripts/check-downloads.sh
bash scripts/check-refactor.sh
```

`check-refactor.sh` 使用本地音频样本、URLSession 测试响应和隔离的 Keychain 项验证旁白缓存与回退、列表请求、播放列表编辑、详情加载与标记竞态、配置归一化和凭据错误路径。测试不调用远程 TTS，不产生付费合成请求。使用 LLVM 统计重构的九个核心模块，分别强制行、函数与区域覆盖率不低于 80%；该统计不代表整个应用的 UI 覆盖率。

Debug 模拟器中设置 `WISIMI_PLAYBACK_CHECKS=1` 可运行本地音频播放与睡眠定时器集成自检；设置 `WISIMI_WORKS_CHECKS=1` 可运行列表竞态自检。设置 `WISIMI_VIDEO_CHECKS=1` 可运行本机生成的 H.264 + AAC MP4 集成自检（真实解码、混合队列、画面绑定、字幕跳转、重试及定时停止）。`WISIMI_DEBUG_SCREEN=video` 提供本地视频界面验证入口。`WISIMI_DEBUG_SCREEN=player` 或 `mini-player` 提供播放器预览，叠加 `WISIMI_SLEEP_TIMER=1` 显示活动定时器；`WISIMI_DEBUG_SCREEN=list-error` 显示刷新失败保留内容的场景。上述入口只存在于 Debug 构建。

`check-downloads.sh` 使用本机 HTTP 服务验证嵌套目录、字幕附带、去重、响应与完整性校验、暂停继续、失败重试、持久化恢复及删除。Debug 模拟器中设置 `WISIMI_DOWNLOAD_PLAYBACK_CHECKS=1` 验证本地 MP4 真实解码与本地字幕；`WISIMI_DEBUG_SCREEN=downloads`、`download-detail`、`download-selection` 提供下载状态与多选布局验证入口。`downloads-many` 增加 80 个文件，`downloads-empty` 清空隔离模拟器测试下载并展示空态；`WISIMI_DEBUG_DOWNLOAD_EXPANDED=1` 自动展开作品，`WISIMI_DEBUG_DOWNLOAD_MINIPLAYER=1` 在下载页显示测试迷你播放器。上述下载布局入口应只在隔离模拟器使用。

MP4 的实际可播放性取决于 iOS 支持的编码和媒体服务器可用性；加载或解码失败时可以在播放器中重试。

## Release

`main` 分支和 PR 会在 GitHub Actions 的 `xcode-27` runner 上进行无签名 Release 构建。推送形如 `v1.0.0` 的 tag，或手动运行 `iOS Release` 并填写已有 tag，会构建未签名 `.ipa`、验证压缩包内容，并上传到 GitHub Release。

该 `.ipa` 不能直接安装，用户必须自行签名后侧载。

## Privacy and Data

- Wisimi 会直接请求 asmr.one 相关接口，作品数据来自 asmr.one。
- 登录 asmr.one 后的 token 只保存在本机 Keychain 中，不会提交到仓库，也不会由 Wisimi 上传到其他服务。
- 用户填写的 OpenRouter Token 使用 `AfterFirstUnlockThisDeviceOnly` 策略保存在本机 Keychain，不参与同步，也不会写入偏好设置、缓存名称或日志。
- 设备首次解锁后，OpenRouter Token 可供锁屏后台旁白读取；已有 Token 在应用初始化时原位更新权限，读取错误不会当成未配置凭据。
- 播放进度、TTS 设置和 TTS 临时缓存保存在本机。
- 用户下载保存在本机 Application Support，排除 iCloud 备份；不会随临时缓存自动清理，可在下载管理中删除。下载管理的占用统计针对已完成文件，进行中的任务还可能占用系统临时空间。
- 下载由 iOS 后台调度，可使用蜂窝网络。暂停与继续使用系统任务；用户强制退出可能取消后台下载，重新打开后可重试。后台处理时机与能否续传由系统和服务器决定。
- 离线支持已保存的作品目录与成功下载的文件；未缓存的媒体仍需联网，生成新的中文旁白仍依赖在线 TTS 服务。

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

Debug 模拟器中设置 `WISIMI_NARRATION_CHECKS=1` 可验证旁白截止任务取消及换曲状态复位；`WISIMI_DEBUG_SCREEN=narration` 提供长中文、无空格英文和显式换行的离线字幕夹具，不调用远程 TTS；叠加 `WISIMI_DEBUG_NARRATION_STATE=enabled` 显示正常混音状态。`WISIMI_DEBUG_SCREEN=work-actions` 使用真实标记和播放列表按钮与标签，点击只操作本地演示状态，不登录或变更远程作品。

叠加 `WISIMI_DEBUG_LARGE_TEXT=1` 使用 SwiftUI 的 `accessibility3` 字体档位，便于离线复现辅助功能布局。界面回归应在隔离的小屏、大屏模拟器及辅助功能大字体下验收：点击字幕文字只跳转时间，点击周边空白返回封面，拖动、复制和旁白重试不返回；长字幕完整换行，高亮切换不改变相邻行间距，混音状态无独立卡片。操作夹具中点击按钮图标、文字和右侧空白均应触发同一动作；开启模拟加载后标记计数不再增加，标签保持与指标胶囊相近的紧凑高度。

## License

应用代码采用 MIT。Edge v2 签名文件遵循 LGPL-3.0，第三方通知与 GPL/LGPL 文本见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，也随应用资源提供。

Debug 模拟器中设置 `WISIMI_DEBUG_SCREEN=similar` 使用中性的离线相似作品夹具；`similar-empty`、`similar-error`、`similar-page-error` 分别验证空态、首次失败和第二页失败；`similar-pagination` 与 `similar-page-error` 每页两项，便于直接点击分页入口。叠加 `WISIMI_DEBUG_SIMILAR_MINIPLAYER=1` 显示本地测试迷你播放器，叠加 `WISIMI_DEBUG_LARGE_TEXT=1` 验证辅助功能大字体。叠加 `WISIMI_DEBUG_SIMILAR_EXPANDED=1` 直接展示展开状态。验收覆盖页内展开、收起、上下分页、空结果隐藏与完整标签卡片；翻页后结果替换，标题保持可达。
