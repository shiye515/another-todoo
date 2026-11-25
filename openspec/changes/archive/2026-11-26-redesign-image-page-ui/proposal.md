# Proposal

## Why

当前图片页是纯列表布局，每个条目旁固定「量化图发送 / 抖动图发送」两个按钮：用户看不到量化效果对比、无法直观选择要发送的版本，且每新增一种量化算法都要再加一个发送按钮，交互随算法数量膨胀。设计稿 `docs/image-page-ui-design.html` 已定义新交互（库列表 + 量化预览详情 + 选中发送模型），需按其重构图片页 UI。

## What Changes

- **布局重构**：图片页由纯列表改为「库列表（左，约 218pt）+ 详情区（右）」两栏；库列表负责资产管理（缩略图、名称、日期、已选算法徽标），详情区完整展示成品图与全部量化预览。
- **量化变体数据驱动**：详情区的量化变体卡片由算法清单驱动（现有四种：标准量化/无抖动、Floyd–Steinberg、Atkinson、Ostromoukhov，后三种为误差扩散抖动），新增算法只需在清单追加一项；标记为规划中的算法以虚线占位卡展示，不参与计算、持久化与发送。
- **发送模型重构**（**BREAKING** 交互变更）：移除每算法一个发送按钮，改为「点击变体卡片选中 + 底部统一『发送到设备』」；未选中时发送按钮禁用；选中状态随条目持久化（`selectedVariantID`），重启后保留。
- **重新量化细分**：每张变体卡提供「重新生成」（从成品图重算该变体并覆盖持久化副本），底部操作栏提供「重新量化全部」。
- **原图说明**：界面标注的「原图」即 528×792 裁剪成品（原图不保留），卡片副标题注明尺寸。
- **底部操作栏**：详情区底部固定操作栏 = 选中信息 + 「重新量化全部」+「发送到设备」（主按钮）。
- 发送进度弹窗沿用现有 `TransferProgressSheet`，发送流程（编码 payload、蓝牙传输、防并发）不变。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `image-library`：
  - 「条目列表与逐条发送」需求改为库列表 + 详情区布局、变体卡片选中模型与底部统一发送；条目级双发送按钮不再存在。
  - 「量化图持久化与重新量化」需求扩展为按变体「重新生成」与「重新量化全部」，并要求量化算法清单可扩展（追加算法即出现新变体卡）。
  - 新增条目级量化变体选中状态的持久化要求（随 manifest 保存，旧数据缺省为未选中）。

## Impact

- `macos/Views/ImageView.swift`：主要重构（两栏布局、详情区、变体卡片行、底部操作栏）。
- `macos/Models/LibraryImage.swift`：新增变体选中状态字段（manifest 向后兼容解码）。
- `macos/Services/ImageLibrary.swift`：量化变体注册表（id/名称/说明 ↔ 持久化文件）、单变体重算 API。
- `macos/Services/ImageProcessor.swift`：量化算法扩展（Floyd–Steinberg / Atkinson / Ostromoukhov 误差扩散核，Ostromoukhov 可变系数表 + 蛇形扫描）。
- `macos/Tests/ImageLibraryTests.swift` 等：选中状态持久化、单变体重算的测试。
- 设备页、裁剪流程、传输服务不受影响。
