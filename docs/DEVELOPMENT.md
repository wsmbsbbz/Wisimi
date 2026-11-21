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

仓库提供不依赖网络的离线回归脚本，覆盖状态管理、下载管线和核心重构模块：

```sh
sh scripts/check-state.sh
sh scripts/check-downloads.sh
bash scripts/check-refactor.sh
```

各脚本职责如下：

- **`scripts/check-state.sh`**：验证播放状态与列表请求竞态逻辑。
- **`scripts/check-downloads.sh`**：使用本机 HTTP 服务验证嵌套目录、字幕附带、去重、响应与完整性校验、同作品合并、暂停继续、失败重试、持久化恢复及删除。
- **`scripts/check-refactor.sh`**：使用本地音频样本、URLSession 测试响应和隔离 Keychain 项，验证旁白缓存与回退、列表请求、播放列表编辑、详情加载与标记竞态、配置归一化、凭据错误路径，以及本地作品导入/元信息/同名轨道/字幕路径/取消和删除。测试不调用远程 TTS，不产生付费请求。脚本会使用 LLVM 对九个核心重构模块分别统计行、函数与区域覆盖率，均强制不低于 **80%**（该统计不代表整个应用的 UI 覆盖率）。

## 调试入口与离线界面夹具

以下命令参数与环境变量仅在 `Debug` 构建生效，建议在隔离的模拟器中配合验收脚本使用。

### 集成自检开关

| 环境变量 | 说明 |
| --- | --- |
| `WISIMI_PLAYBACK_CHECKS=1` | 运行本地音频播放与睡眠定时器集成自检 |
| `WISIMI_WORKS_CHECKS=1` | 运行列表请求竞态自检 |
| `WISIMI_VIDEO_CHECKS=1` | 运行本机生成的 H.264 + AAC MP4 集成自检（真实解码、混合队列、画面绑定、字幕跳转、重试及定时停止） |
| `WISIMI_DOWNLOAD_PLAYBACK_CHECKS=1` | 验证本地下载 MP4 的真实解码与本地字幕 |
| `WISIMI_NARRATION_CHECKS=1` | 验证旁白截止任务取消及换曲状态复位 |
| `WISIMI_LOCAL_MEDIA_CHECKS=<path>` | 指定模拟器容器内 `Tests/Fixtures/silence.mp3` 副本的绝对路径，运行本地 MP4/CAF、VTT/LRC、缓存旁白、恢复和删除自检 |

### 离线界面夹具（`WISIMI_DEBUG_SCREEN`）

| `WISIMI_DEBUG_SCREEN` 值 | 用途 | 可选叠加变量 |
| --- | --- | --- |
| `local-library` | 直接进入本地作品库 | `WISIMI_LOCAL_MEDIA_CHECKS` |
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
