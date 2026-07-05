## Why

作品详情页主封面在加载前没有稳定高度，加载完成后会把目录区域突然下推；个别页面还会因为图片尺寸参与布局而撑大页面。asmr.one 的封面源图保证为 4:3，因此详情页可以用固定比例容器稳定布局。

## What Changes

- 作品详情页主封面加载前后 SHALL 保持相同的 4:3 布局空间。
- 作品详情页主封面 SHALL 限制在可用屏幕宽度内，不因图片原始尺寸撑大页面。
- 主封面继续使用 `scaledToFill` 并裁切到 4:3 容器内。
- 不改变列表封面、迷你播放器封面、播放器封面或 tracks 图片预览行为。

## Capabilities

### New Capabilities
- `work-detail-cover-layout`: 定义作品详情页主封面的稳定占位、4:3 展示比例和屏幕内约束。

### Modified Capabilities

## Impact

- Affected code: `Wisimi/Features/Works/WorkDetailView.swift`, possibly `Wisimi/Shared/UI/CoverImage.swift` if the smallest clean fix is a reusable optional aspect-ratio constraint.
- APIs: No network or model changes.
- Dependencies: No new dependencies.
