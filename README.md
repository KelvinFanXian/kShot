<p align="center">
  <img src="Resources/AppIcon.png" width="180" alt="KShot Logo">
</p>

<h1 align="center">KShot</h1>

<p align="center">轻量、原生、重视隐私的 macOS 截图与本地文字识别工具。</p>

## 功能

- 使用全局快捷键 `⌃⌘A` 随时截图
- 冻结当前屏幕，支持多显示器手动框选
- 实时显示选区像素尺寸
- 支持矩形、箭头、文字和马赛克标注
- 支持拖动选区以及八方向缩放
- 支持撤销、重做和按钮悬停状态
- 截图完成后自动写入系统剪贴板
- 内置百度 PP-OCRv6 tiny 模型，可在截图中划选文字并自动复制
- OCR 全程在本机完成，无需 API Key，不会上传截图

## 系统要求

- macOS 13 或更高版本
- 从源码构建需要 Xcode 15 或更高版本

## 构建与安装

```bash
git clone https://github.com/KelvinFanXian/kShot.git
cd kShot
make app
cp -R .build/app/KShot.app /Applications/
open /Applications/KShot.app
```

也可以运行 `make run`，直接构建并启动开发版本。

首次截图时，请按照 macOS 提示授予 KShot“屏幕与系统音频录制”权限。授权后仍无法截图时，请完全退出 KShot 后重新打开。

## 使用方法

1. 点击菜单栏中的取景框图标，或按 `⌃⌘A`。
2. 拖动鼠标框选截图区域。
3. 拖动选区内部可移动选区，拖动边缘控制点可调整大小。
4. 使用悬浮工具栏添加标注，或点击蓝色文字识别按钮后划选文字。
5. 按 `Enter`、双击选区或点击绿色勾号完成截图。

### 快捷操作

| 操作 | 快捷键 |
| --- | --- |
| 开始截图 | `⌃⌘A` |
| 完成截图 | `Enter` |
| 取消截图 | `Esc` |
| 撤销标注 | `⌘Z` 或 `Delete` |
| 重做标注 | `⇧⌘Z` |

### 截图内文字识别

完成截图区域框选后，点击工具栏中的蓝色文字取景框按钮。光标变为十字后，在目标文字上拖动并松开，识别结果会自动写入剪贴板。

KShot 使用百度 PaddleOCR 开源的 PP-OCRv6 tiny 识别模型，并通过 ONNX Runtime 在本机执行推理。

## 开发

```bash
make build   # Debug 构建
make test    # 运行测试
make app     # 生成并签名 KShot.app
make run     # 构建并启动
```

更换 `Resources/AppIcon.png` 后，可重新生成 macOS 图标：

```bash
swift scripts/generate-app-icon.swift Resources/AppIcon.png Resources/AppIcon.icns
```

## 技术栈

- Swift、AppKit
- ScreenCaptureKit、CoreGraphics、NSPasteboard
- PaddleOCR PP-OCRv6 tiny
- ONNX Runtime

## 许可证

KShot 基于 [MIT License](LICENSE) 开源。PaddleOCR 与 ONNX Runtime 使用各自的开源许可证，相关文件随项目一并保留。

作者：范显
