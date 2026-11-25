# Tasks

## 1. 数据层：变体注册表与选中状态

- [x] 1.1 新增量化变体注册表（id / 名称 / 说明 / 是否规划中 / 持久化文件名 / 量化参数映射），含 `plain`（→ `quantized.png`，无抖动）、`floyd`（→ `dithered.png`，Floyd–Steinberg）、`atkinson`（planned，不产出文件）；新增单元测试验证变体↔文件名与量化参数映射正确，且 planned 变体不在计算/持久化路径中。验证：`xcodebuild -project macos/TodooCardMacApp.xcodeproj -scheme TodooCardMacApp test` 通过。
- [x] 1.2 `LibraryImage` 增加可选 `selectedVariantID`，`decodeIfPresent` 向后兼容；新增测试：旧格式 manifest JSON（无该字段）解码成功且为未选中、未知变体 id 解码后视为未选中。验证：上述测试命令通过。
- [x] 1.3 `ImageLibrary` 按变体重算 API（从成品图重算指定变体并仅覆盖该变体持久化副本与缓存）与「重新量化全部」（顺序重算全部已实现变体）；缺失文件补建覆盖全部已实现变体。新增/更新测试：单变体重算不影响其余变体、重算全部覆盖全部变体、缺失变体文件自动补建。验证：上述测试命令通过。

## 2. 图片页 UI 重构

- [x] 2.1 两栏布局骨架：左库列表（定宽约 218pt）+ 右详情区（ScrollView），保留空库空态与错误提示、工具栏「添加图片」与裁剪 sheet 流程不变。验证：`xcodebuild -project macos/TodooCardMacApp.xcodeproj -scheme TodooCardMacApp build` 通过，运行后空库显示空态、添加/裁剪流程可用。
- [x] 2.2 库列表条目：2:3 量化缩略图、显示名、添加日期、已选变体名称徽标（未选中不显示）；删除入口移到条目悬停按钮 + 右键菜单，删除行为与现有需求一致。验证：运行后条目信息与徽标正确，删除仅移除目标条目。
- [x] 2.3 详情区内容：成品图卡片（标注「原图（裁剪成品）」与 528×792）+ 变体卡片横向滚动行（卡片含预览、名称、说明），规划中变体渲染为不可交互占位卡。验证：运行后选中任一条目可见成品图与全部变体卡，Atkinson 为占位卡且点击无效果。
- [x] 2.4 变体选中交互：点击变体卡设置并持久化 `selectedVariantID`（写入 manifest），卡片显示选中标识，库列表徽标同步；重启后选中状态恢复。验证：运行后选中 → 重启 → 仍为选中状态（结合 1.2 测试）。
- [x] 2.5 底部操作栏与发送：选中信息（变体名/说明/大小/量化时间）、「重新量化全部」、「发送到设备」主按钮（未选中禁用）；变体卡「重新生成」按钮（进行中转圈、不可重复触发）；发送沿用 payload 编码 → TransferProgressSheet → 蓝牙传输，传输/编码/重算进行中禁用全部操作。验证：运行后未选中禁用发送、选中后可发送并弹进度窗、传输期间按钮禁用。

- [x] 2.6 量化变体行横向滚动支持普通鼠标滚轮（纵向滚轮换算横向滚动，含换算单元测试）；验证：构建/测试通过，滚动条可见

## 3. 集成验证

- [x] 3.1 按 delta spec 场景走查（库列表/详情切换、徽标、占位卡、选中发送、单变体重算、重新量化全部、重启恢复、旧数据加载、删除），并运行完整测试与构建：`xcodebuild -project macos/TodooCardMacApp.xcodeproj -scheme TodooCardMacApp test` 全绿。验证：场景逐条勾验 + 测试输出无失败。

## 4. 量化算法扩展（Atkinson、Ostromoukhov）

- [x] 4.1 新增 `QuantizationAlgorithm`（none/floydSteinberg/atkinson/ostromoukhov）并重写误差扩散：Floyd–Steinberg 保持原核逐行扫描、Atkinson 六邻居各 1/8（只传播 3/4 误差）、Ostromoukhov 按亮度查可变系数表 + 蛇形扫描；验证：`QuantizationAlgorithmTests`（调色板约束、纯色不变、中灰抖动、确定性、系数表 256 项/和式/黑白对称）通过
- [x] 4.2 注册表接入：atkinson 转正、新增 ostromoukhov（`atkinson.png`/`ostromoukhov.png`），缺失变体文件启动自动补建；验证：全量测试通过、启动后旧条目自动补建新变体图、卡片自动出现且可选中
- [x] 4.3 同步规划产物（proposal/design/spec delta 与四种算法实现一致）
