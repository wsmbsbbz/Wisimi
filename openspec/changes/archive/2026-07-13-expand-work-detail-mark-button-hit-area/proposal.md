## Why

作品详情页的“标记”按钮虽然视觉上占据整行，但目前只有文字、图标等内容区域可以触发，容易造成点击无响应的误解。需要让整个可见按钮区域都能响应，以提高操作的可发现性和容错性。

## What Changes

- 扩大作品详情页“标记”按钮的可点击区域，使按钮边框内任意位置均可触发添加标记操作。
- 保持现有标记菜单、加载禁用状态和视觉样式不变。
- 确保按钮命中区域随不同 iPhone 屏幕宽度自适应，不依赖固定分辨率。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `work-detail-action-sheets`：补充作品详情页“标记”按钮完整可见区域均可触发标记菜单的交互要求。

## Impact

- 影响 `Wisimi/Features/Works/WorkDetailView.swift` 中作品详情标记按钮的 SwiftUI 命中区域。
- 不涉及 API、数据模型、依赖或持久化变更。
