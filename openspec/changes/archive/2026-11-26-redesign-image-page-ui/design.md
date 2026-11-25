# Design

## Context

图片页现状（见 `macos/Views/ImageView.swift`）是单列 `List`：每个 `EntryRow` = 缩略图 + 名称/日期 + 「量化图发送 / 抖动图发送 / 重新量化 / 删除」按钮组。数据侧 `ImageLibrary` 为每个条目持久化三个文件：`processed.png`（528×792 裁剪成品）、`quantized.png`（无抖动）、`dithered.png`（Floyd–Steinberg），元数据在 `manifest.json`（`LibraryImage`：id / displayName / addedAt / configuration）。发送流程：`ImageProcessor.makeControllerPayload` 后台编码 → `PendingTransfer` 驱动 `.sheet` 弹出 `TransferProgressSheet`，经 `TodooCardTransferService` 蓝牙传输。行为契约见 `openspec/specs/image-library/spec.md`，动机与范围见 proposal.md。

## Goals / Non-Goals

**Goals:**
- 按 `docs/image-page-ui-design.html` 落地两栏布局（库列表 + 量化预览详情）与「选中变体 + 统一发送」交互。
- 量化变体以注册表数据驱动：新增算法 = 注册表追加一项，卡片自动出现，布局不破。
- 选中状态随条目持久化，旧 manifest 向后兼容（缺字段 = 未选中，绝不导致条目丢失）。

**Non-Goals:**
- 不实现清单四种之外的新量化算法；`QuantizedVariant` 的 planned 机制保留（清单标记为规划中的算法仅出占位卡，不实现）。
- 不改动裁剪流程（CropSheetView）、传输服务、设备页、payload 编码格式。
- 不做条目重命名、排序、搜索、拖拽导入等图片库新功能。
- 不引入 Liquid Glass / 新视觉体系；配色与控件遵循现有 macOS 系统样式，仅按设计稿组织布局与信息层级。

## Decisions

**D1 布局：自定义两栏 `HStack`，不用 `NavigationSplitView`。**
左栏固定宽约 218pt 的库列表，右栏 `ScrollView` 承载详情区，底部操作栏用 `.safeAreaInset(edge: .bottom)` 实现设计稿的 sticky 效果。备选 `NavigationSplitView`：应用外层已有自己的侧栏（图片/设备），再嵌一层 split 会产生双重导航语义与多余的 column visibility 行为，弃用。详情区内部「原图卡 + 变体行」用 `ScrollView(.horizontal)` + `LazyHStack`，容纳未来更多算法（设计稿明确要求横向滚动）。

**D2 变体注册表：`QuantizedVariant`（id / 名称 / 说明 / 是否规划中 / 文件名 / 量化算法），单一真源。**
现有四个变体：`plain` → `quantized.png`（`QuantizationAlgorithm.none`，最近邻）、`floyd` → `dithered.png`（`.floydSteinberg`）、`atkinson` → `atkinson.png`（`.atkinson`）、`ostromoukhov` → `ostromoukhov.png`（`.ostromoukhov`）；前两个映射到既有文件以避免数据迁移，新变体按 `<id>.png` 命名（存量条目启动时自动补建新变体图）。计算入口为 `ImageProcessor.computeQuantized(_:algorithm:)`，注册表只做 id → 算法/文件 的映射；算法实现集中在 `QuantizationAlgorithm`：Floyd–Steinberg（7/16、3/16、5/16、1/16，逐行扫描）、Atkinson（六邻居各 1/8、只传播 3/4 误差，逐行扫描）、Ostromoukhov（论文可变系数表按亮度索引、蛇形扫描、蓝噪声频谱；系数表与 dithr 开源库数据核对，256 项且黑白对称）。备选：把文件名直接改成 `<id>.png` 全量迁移——需要一次性重命名存量文件且旧版本回滚即数据丢失，收益低，弃用。`planned: true` 的条目只进 UI 占位卡，不进持久化与计算路径。

**D3 选中状态：`LibraryImage.selectedVariantID: String?`，`decodeIfPresent` 向后兼容。**
用可选 String 而非枚举强类型，使旧 manifest（无该字段）与未来新变体 id 都能安全解码；未知 id 解码后视为未选中。注意 `ImageLibrary.loadFromDisk` 在整体解码失败时会清空 `entries`——因此该字段必须是可选或有默认值，并补一条「旧 manifest 解码」测试兜底（见 Risks）。

**D4 发送与并发控制沿用现状。**
`send(entry, variant)` 仍走 `makeControllerPayload` → `PendingTransfer` → `TransferProgressSheet`；`sendDisabled`（传输/编码/重新量化任一进行中即禁用）逻辑平移到底部操作栏，满足「传输期间禁止重复触发」的既有要求。`encodingEntryID` 扩展为可与变体维度共存的进行中集合（编码中条目、重算中 (条目, 变体)）。

**D5 重新量化拆为单变体与全部两个入口。**
`ImageLibrary` 新增按变体重算 API（从成品图重算指定变体并覆盖其持久化副本 + 缓存），「重新量化全部」= 顺序重算全部已实现变体；进行中状态以 (条目 id, 变体 id) 粒度呈现（变体卡上转圈），互不阻塞不同变体但整体沿用禁用策略防蓝牙并发。

**D6 删除入口：库列表条目悬停显示删除按钮 + 右键菜单。**
设计稿未画删除控件，但既有需求「删除图片条目」必须保留。放在库列表条目（悬停垃圾桶 / 右键菜单），详情区不重复提供；实现细节不进 spec。

## Risks / Trade-offs

- [manifest 兼容：新增字段若解码失败会让 `loadFromDisk` 清空整个库（文件仍在但条目“消失”）] → 字段用 `String?` + `decodeIfPresent`，并用旧格式 manifest JSON 的解码测试验证；解码失败路径不改。
- [变体行横向滚动在小窗口下可发现性差] → 详情区宽度不足时变体卡等宽（约 236pt）并允许滚动；原图卡固定在行首不参与滚动。
- [规划中占位卡被误实现或误发送] → 占位卡不参与点击选中、不生成预览、不进发送路径；注册表中 planned 项不产出文件。
- [选中变体的量化图文件缺失时发送失败] → 沿用现有「缺失自动补建」机制，发送前按注册表校验并补建所选变体文件。
- [两栏布局在极窄窗口下挤压详情区] → 库列表定宽、详情区 `minWidth` 保护；不做自适应折叠（Non-Goal）。

## Migration Plan

无数据迁移：文件名沿用（D2），manifest 新字段可选（D3）。部署即替换 UI 与读写代码；回滚只需回退代码，库文件与 manifest 均向后可读（旧代码忽略新增字段——旧 `LibraryImage` 解码含未知字段不受影响，Codable 默认忽略多余 key）。

## Open Questions

（无）
