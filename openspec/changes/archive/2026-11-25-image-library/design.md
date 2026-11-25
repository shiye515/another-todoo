# Design

## Context

图片页当前是单图状态机：`ImageProcessor`（@MainActor ObservableObject）持有原图、裁剪配置、量化/抖动预览与三态步骤，量化计算已后台化（`computeQuantized` nonisolated + 代次守卫）。发送管线：528×792 图 → `encodeControllerPayload`（内部最近邻量化）→ `TodooCardTransferService`。应用未沙盒、无本地数据存储。见 proposal.md - Why。

## Goals / Non-Goals

**Goals:**

- 图片页重构为单列列表（无处理区）：条目行 = 缩略图 + 名称 + 日期 + 量化图发送 + 抖动图发送 + 重新量化 + 删除
- 图片库服务：多图添加（添加即裁剪队列）、只存 528×792 成品、**两个量化图随条目持久化**、重新量化按钮、重启立即可发
- 发送复用现有管线：持久化量化图 → payload 编码 → `TransferProgressSheet` 进度弹窗

**Non-Goals:**

- 不保留原图（用户明确要求）——裁剪确认即定型，无法重新裁剪
- 不展示量化预览大图（无处理区）——量化图仅作为发送数据与列表缩略图旁的资产存在
- 不做重复去重、拖拽导入、列表重排序
- 不改动发送进度弹窗、传输服务、设备页

## Decisions

1. **库服务独立：`ImageLibrary`（@MainActor ObservableObject）**
   持有 `@Published entries: [LibraryImage]` 与每条目的内存缓存（成品 NSImage、两个量化图 NSImage）；`ImageLibrary` 管资产全生命周期：manifest 读写、PNG 存取、增删、量化图补建与覆盖。
   *备选*：合并进 ImageProcessor——资产与处理职责混杂，否。

2. **存储：每条目一个目录**
   目录 `~/Library/Application Support/TodooCardMacApp/ImageLibrary/<UUID>/`，内含 `processed.png`（528×792 成品）、`quantized.png`（无抖动量化）、`dithered.png`（Floyd–Steinberg 抖动）；`manifest.json` 在库根，为 `Codable` 条目数组（id、displayName、addedAt、configuration），原子写入。删除条目 = 删除整个目录。`ImageEditConfiguration` 补充 `Codable`（`CropMode` 已是 String raw enum）。启动校验 `processed.png` 存在性（条目有效性判定）；量化 PNG 缺失则后台自动从成品补建（自愈）。
   *备选*：全部文件平铺 + 后缀区分——删除需逐文件清理，按条目分目录更干净；量化图不落盘发送时现算——用户明确要求持久化，否。

3. **添加即裁剪队列**
   "添加图片"（多选）→ URL 队列交给 `ImageProcessor.beginAdd(urls:)`：依次载入原图（仅内存）弹裁剪 sheet → 确认后 `render` 成 528×792 → 入库（存成品 + 即时量化生成两个量化图）→ 队列下一张；取消 = 丢弃该 URL。入库时同步生成量化图，保证条目自包含、发送零等待。
   *备选*：允许"稍后裁剪"——与只存成品冲突，否。

4. **量化图持久化 + 重新量化**
   入库与重新量化共用一条路径：`成品 CGImage → computeQuantized(dithering: false / true)` → 写 `quantized.png` / `dithered.png` → 更新内存缓存。重新量化按钮触发同一编排（后台执行），期间该条目按钮呈进行中状态且不可重复触发。量化图文件在启动/发送时缺失 → 后台自动补建后继续（发送等待补建完成）。
   *备选*：量化图不落盘发送时现算——用户明确要求持久化，否。

5. **条目发送路径：直接使用持久化量化图**
   - 量化图发送：`encodeControllerPayload(quantized.png 对应 CGImage)`
   - 抖动图发送：`encodeControllerPayload(dithered.png 对应 CGImage)`
   两者均为后台编码；发送状态由现有 `TransferProgressSheet` + `pendingTransfer`（`.sheet(item:)`）承载；传输进行中全局禁用发送与重新量化按钮。
   *备选*：发送时现算——与持久化目标相悖且引入延迟，否。

6. **布局：图片页 = 单列 List（全宽），无处理区**
   行结构：40pt 缩略图 + 显示名/添加日期 + `量化图发送` + `抖动图发送` + `重新量化`（arrow.triangle.2.circlepath，进行中显示转圈）+ 删除（悬停）。空库显示引导文案。工具栏仅保留"添加图片"。原三列量化预览（`QuantizationView`）与 `currentStep` 状态机整体移除——无处理区后只有"添加队列进行中 / 列表"两种界面态。

7. **`ImageProcessor` 职责收窄**
   保留：裁剪队列（`beginAdd(urls:)` / `confirmCrop()` / `cancelCurrentCrop()`）、裁剪 sheet 数据、`encodeControllerPayload`、重新量化编排。移除：量化预览 @Published、`refreshPreview`、selection 步骤。发送编排（持久化量化图 → payload → pendingTransfer → sheet）保留在视图层。

## Risks / Trade-offs

- [取消裁剪导致误丢刚选的图] → 裁剪窗口注明"取消将跳过该图片"；队列逐张呈现、用户始终在环内
- [成品图不可再编辑（无原图）] → 量化态即定型，与"只存成品"语义一致
- [条目多时磁盘与内存增长] → 每条目约 3 张 PNG（六色内容，每张数十 KB）+ 内存缓存约 2MB；典型规模可接受，必要时后续加"库占用"显示与清理
- [重新量化与传输并发] → 传输中全局禁用重新量化与发送按钮，规避文件替换与连接竞争
- [量化 PNG 解码在列表滚动时卡顿] → 缩略图按条目解码一次缓存，后台执行

## Migration Plan

1. `LibraryImage` + `ImageLibrary`（含临时目录注入的单元测试）
2. `ImageProcessor` 改造（裁剪队列、量化图生成/重新量化编排）+ `ImageEditConfiguration: Codable`
3. `ImageView` 列表重构 + 行内按钮组 + 发送/重新量化接线
4. 构建 + 测试 + 手动验证（添加裁剪队列 / 双按钮发送 / 重新量化 / 重启恢复 / 删除）
5. 回滚：还原提交即可；数据目录与旧逻辑无耦合，可整体删除

## Open Questions

（无）
