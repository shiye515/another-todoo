# TodooCardMacApp

最小 macOS SwiftUI 应用骨架，直接在 Xcode 中打开：

```bash
open macos/TodooCardMacApp.xcodeproj
```

应用包含：

- `图片` 菜单及占位页面（选择图片 → 旋转裁剪 → 量化预览 → 发送到设备）
- `设备` 菜单及蓝牙扫描页
- 原生 `NavigationSplitView` 与 `.sidebar` 列表
- BLE 图片传输（CoreBluetooth，参考协议状态机的原生 Swift 实现）

## 构建、运行

应用随主程序一起编译，无独立构建脚本或工具：

**方式一（推荐）**：用 Xcode 打开工程，直接 ⌘R 运行。

**方式二（命令行）**：

```bash
cd macos
xcodegen generate
xcodebuild -project TodooCardMacApp.xcodeproj -scheme TodooCardMacApp \
  -configuration Debug -derivedDataPath .derived CODE_SIGNING_ALLOWED=NO build
open .derived/Build/Products/Debug/TodooCardMacApp.app
```
