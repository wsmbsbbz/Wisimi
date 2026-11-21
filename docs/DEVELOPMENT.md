# 开发与验证指南

本文档面向参与构建、调试和验证 Wisimi 的开发者。关于应用功能和使用方式，请参阅根目录 [README.md](../README.md)。

## 开发环境要求

- macOS 27
- Xcode 27
- iOS 27 SDK（部署目标 `iOS 27.0+`）
- SwiftUI

## 构建项目

在 Xcode 中打开 `Wisimi.xcodeproj`，选择 `Wisimi` scheme / target 后即可运行。

也可以使用命令行构建模拟器版本：

```sh
xcodebuild -project Wisimi.xcodeproj -scheme Wisimi -configuration Debug -sdk iphonesimulator build
```

## 自动化验证与覆盖率

项目使用 `WisimiTests`（基于 Swift Testing）运行单元测试与集成测试，测试均运行在隔离目录、内存 Stub 和 `URLProtocol` Mock 下，不调用远程接口，不产生付费 TTS 请求：

```sh
xcodebuild test \
  -project Wisimi.xcodeproj \
  -scheme Wisimi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -enableCodeCoverage YES
```

测试套件涵盖：
- **`ModelsAndDecodingTests`**：模型解码、轨道分类、客户端请求构造与路由解析。
- **`StateAndTimerTests`**：播放状态机、睡眠定时器、列表/详情/相似作品/播放列表竞态与取消。
- **`TTSTests`**：TTS 混音配置、缓存指纹、Edge/OpenRouter 请求校验、回退策略与 Keychain 凭据存储。
- **`LocalLibraryAndDownloadTests`**：本地作品导入、DLsite 元数据同步、文本解码与下载队列生命周期。
- **`AudioPlayerIntegrationTests`**：字幕解析、旁白截止、MP4 播放与睡眠定时器集成验证。

CI 流水线通过 `xcrun xccov` 对核心逻辑模块强制校验 **≥ 80%** 的行覆盖率门禁。

## 调试入口与离线界面夹具

以下环境变量仅在 `Debug` 构建生效，用于在模拟器中快速拉起特定界面状态以验收多设备布局。

### 离线界面夹具（`WISIMI_DEBUG_SCREEN`）

| `WISIMI_DEBUG_SCREEN` 值 | 用途 | 可选叠加变量 |
| --- | --- | --- |
| `local-library` | 直接进入本地作品库 | — |
| `player` / `mini-player` | 播放器与迷你播放器预览 | `WISIMI_SLEEP_TIMER=1`（显示活动睡眠定时器） |
| `video` | 本地视频播放器界面验证 | — |
| `narration` | 长中文、无空格英文和显式换行的离线字幕夹具（不调用远程 TTS） | `WISIMI_DEBUG_NARRATION_STATE=enabled`（显示正常混音状态） |
| `tts-settings` / `openrouter-credentials` | 直接打开中文旁白设置或 OpenRouter 凭据配置页 | — |
| `list-error` | 刷新失败保留已有内容的列表场景 | — |
| `work-actions` | 标记与播放列表操作区验收（仅操作本地演示状态，不访问远程） | — |
| `downloads` / `downloads-many` / `downloads-empty` / `download-local-detail` | 本地下载状态与详情页布局验证（`downloads-many` 增加 80 个文件，`downloads-empty` 清空隔离测试下载展示空态，`download-local-detail` 直达本地下载作品详情） | `WISIMI_DEBUG_DOWNLOAD_MINIPLAYER=1` |
| `similar` / `similar-empty` / `similar-error` / `similar-page-error` / `similar-pagination` | 中性离线相似作品夹具（验证空态、首次/翻页失败与每页两项分页） | `WISIMI_DEBUG_SIMILAR_MINIPLAYER=1`、`WISIMI_DEBUG_SIMILAR_EXPANDED=1` |

### 辅助功能大字体

任意界面夹具均可叠加 `WISIMI_DEBUG_LARGE_TEXT=1`，强制使用 SwiftUI 的 `accessibility3` 字体档位，便于在小屏、大屏模拟器下复现与验收辅助功能大字体布局。

验收要点：
- **播放器与字幕**：点击字幕文字仅跳转时间，点击周边空白返回封面，拖动、复制和旁白重试不返回；长字幕完整换行，高亮切换不改变相邻行间距，混音状态无独立卡片。
- **操作区域**：点击按钮图标、文字和右侧空白均触发同一动作；开启模拟加载后标记计数不再增加，标签保持与指标胶囊相近的紧凑高度。
- **相似作品**：覆盖页内展开、收起、上下分页、空结果隐藏与完整标签卡片；翻页后结果替换，标题保持可达。

## CI 与发布流程

- `main` 分支和所有 PR 会在 GitHub Actions 的 `xcode-27` runner 上执行离线回归测试、覆盖率校验与无签名 Release 构建（详见 [.github/workflows/ios-ci.yml](../.github/workflows/ios-ci.yml)）。
- 推送形如 `v1.6.0` 的 tag，或在 Actions 中手动触发 `iOS Release` 并指定已有 tag，会自动注入 `MARKETING_VERSION`、构建未签名 `.ipa`、校验归档内容并发布至 GitHub Releases（详见 [.github/workflows/ios-release.yml](../.github/workflows/ios-release.yml)）。
