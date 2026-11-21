# 参与贡献

感谢你关注并愿意改进 Wisimi！

## 反馈问题与提出建议

- 提交 Bug 前，请先在 [Issues](https://github.com/wsmbsbbz/Wisimi/issues) 中搜索是否已有相同记录。
- 请使用仓库提供的 Issue 模板，尽量附带设备型号、iOS 版本、Wisimi 版本与复现步骤。
- 涉及截图或日志时，请避免上传含隐私 Token 或不适宜公开展示的内容。

## 提交代码（Pull Request）

1. Fork 本仓库并从 `main` 创建功能或修复分支。
2. 按照 [开发与验证指南](docs/DEVELOPMENT.md) 完成本地构建与调试。
3. UI 改动请同时验证不同尺寸 iOS 设备与辅助功能大字体（`WISIMI_DEBUG_LARGE_TEXT=1`）下的布局表现。
4. 提交 PR 前，请确保离线测试与覆盖率检查全部通过：

```sh
sh scripts/check-state.sh
sh scripts/check-downloads.sh
bash scripts/check-refactor.sh
```

5. 在 PR 描述中简要说明改动动机、涉及范围以及验证方式。
