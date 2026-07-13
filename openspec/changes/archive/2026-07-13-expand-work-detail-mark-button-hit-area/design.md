## Context

作品详情页的标记操作由 `ReviewActionButton` 内的 SwiftUI `Button` 提供。按钮标签中的 `HStack` 已使用 `maxWidth: .infinity` 扩展视觉宽度，但空白区域未被定义为标签的矩形命中形状，导致用户必须点击图标或文字附近才能触发操作。

## Goals / Non-Goals

**Goals:**

- 让标记按钮边框内的整个可见矩形都参与命中测试。
- 使用 SwiftUI 自适应布局，在主流不同尺寸的 iPhone 上保持一致交互。
- 保持现有视觉样式、业务动作、加载状态与底部弹层行为不变。

**Non-Goals:**

- 不调整按钮尺寸、配色或文案。
- 不修改标记 API、状态模型或其他作品详情动作按钮。
- 不为此次局部交互修复引入通用按钮组件或新依赖。

## Decisions

- 在现有按钮标签铺满可用宽度后，使用 SwiftUI 原生命中形状将标签定义为矩形。这样命中范围直接跟随实际布局宽度，无需固定尺寸、`GeometryReader` 或 UIKit 桥接。
- 保留现有 `Button` 的 action、`.disabled(isLoading)` 与 `.buttonStyle(.bordered)`，确保扩大命中区域不会绕过加载期间的禁用行为，也不会改变标记菜单流程。

## Risks / Trade-offs

- [修饰符顺序错误可能仍只命中内容区域] → 将矩形命中形状应用于已扩展至最大宽度的标签容器，并在小屏与大屏模拟器上点击文字外空白区域验证。
- [命中区域意外超出视觉按钮] → 命中形状仅附着于按钮标签，不增加额外 padding 或透明覆盖层。
