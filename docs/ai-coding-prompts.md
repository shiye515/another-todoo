# 编码 AI 提示词指南（扩展量化管线）

面向「让 AI 编程助手在本仓库新增量化算法或新的图片处理方式（含 AI 处理）」的需求提示词编写指南。
目的：一条提示词进去，出来的改动**能直接编译、带测试、不碰无关模块**。

## 1. 仓库地图（提示词里可以直接引用）

| 位置 | 职责 | 新算法相关度 |
| --- | --- | --- |
| `macos/Models/QuantizedVariant.swift` | **变体注册表**（id / 名称 / 说明 / 文件名 / 算法映射）——唯一扩展入口 | ★★★ 必改 |
| `macos/Services/QuantizationAlgorithm.swift` | 抖动算法枚举 + 查表数据（如 Ostromoukhov 系数表） | ★★★ 必改 |
| `macos/Services/ImageProcessor.swift` | `computeQuantized(_:algorithm:)` 量化主循环 + `diffuseError` 扩散核 | ★★★ 必改 |
| `macos/Services/ImageLibrary.swift` | 持久化/缓存/按变体重算/缺失自动补建（文件名约定 `<id>.png`，旧两个沿用 `quantized.png`/`dithered.png`） | ★ 通常不动 |
| `macos/Views/ImageDetailView.swift` | 变体卡片（注册表数据驱动，自动出新卡） | ★ 通常不动 |
| `macos/Tests/QuantizationAlgorithmTests.swift` | 算法输出约束测试 | ★★★ 必加用例 |
| `openspec/` | 提案/规格/设计/任务（`openspec new change` 起流程） | 流程要求 |

关键契约（写提示词时必须知道）：

- 输出**只能是六色调色板**：黑/白/黄/红/蓝/绿；成品固定 **528×792**。
- 量化必须**确定性**（同输入同字节），持久化 PNG 并有内存缓存。
- 新变体文件名按 `<variant-id>.png`，存量 `quantized.png`/`dithered.png` 勿改名（数据迁移成本）。
- 缺失文件在启动时**自动补建**，新算法天然被该机制覆盖。
- 「规划中」变体（`isPlanned: true`）只出占位卡，不参与计算/持久化/选中/发送。

## 2. 提示词五段式结构

```
[目标算法/处理方式] + [精确规则（核/公式/参数）] + [输出与兼容约束] + [测试与验收] + [不许动的范围]
```

1. **目标**：算法名 + 一句话效果定位（如「蓝噪声、纹理均匀」）。
2. **精确规则**：误差扩散核的权重表 / 查表数据 / 扫描顺序（逐行 or 蛇形）/ 误差是否全额传播。**能给公式就别只给名字**——「Atkinson」就有六邻居各 1/8 只传 3/4 这种容易做错的细节。
3. **输出与兼容**：六色约束、528×792、确定性、文件名 `<id>.png`、注册表 id/名称/文案。
4. **测试与验收**：必须新增/更新哪些测试（见第 4 节），跑什么命令。
5. **范围**：明确不要动传输流程、裁剪流程、设备页等。

## 3. 可复制模板

### 3.1 新增误差扩散抖动算法（首选模板）

```text
在 TodooCardMacApp 的量化管线里新增一种抖动算法变体：

- 算法：<算法名>，定位：<效果定位，如"有序抖动、纹理规则">。
- 精确规则：<扩散核权重表 / 阈值矩阵 / 查表数据 / 扫描顺序 / 误差传播比例>
  （如来自论文或开源实现，给出出处与关键公式；查表数据请直接粘贴完整表。）
- 注册表：在 QuantizedVariant.registry 追加变体 id "<id>"，名称 "<名称>"，
  说明 "<卡片说明文案>"，文件名 "<id>.png"，isPlanned: false；
  不要改动既有变体的 id 与文件名。
- 输出约束：六色调色板（黑白黄红蓝绿）、528×792、确定性输出；实现放在
  QuantizationAlgorithm + ImageProcessor.diffuseError，不要动 ImageLibrary
  与传输/裁剪流程。
- 测试：QuantizationAlgorithmTests 增加用例——输出仅含调色板色、纯黑/纯白输入
  不变、中灰输入产生抖动混合、同输入两次输出一致；查表数据加不变量测试
  （条目数、归一化和、对称性）。
- 完成后运行：xcodebuild -project macos/TodooCardMacApp.xcodeproj
  -scheme TodooCardMacApp -destination 'platform=macOS' test 全绿。
```

### 3.2 接入 AI 处理方式（模型/外部服务做量化）

```text
为量化管线增加一种"AI 处理"变体，输出仍是六色 528×792：

- 处理方式：<本地 CoreML 模型 / 云端 API / 调用外部工具>，输入裁剪成品
  （processed.png），输出六色图；模型不可用时必须降级：回退到 <某确定性算法>
  并提示用户，绝不阻塞发送。
- 变体注册表按第 1 节契约接入（id、文件名 <id>.png）；AI 结果必须落盘持久化，
  沿用现有"缺失自动补建"与"重新生成"语义（重建即重新调用模型）。
- 异步：量化在后台执行，UI 呈现进行中状态（参考现有 requantizingKeys 机制），
  不得阻塞主线程；超时 <N 秒>。
- 测试：mock 处理实现，覆盖成功/超时/降级三条路径；确定性测试对 AI 变体豁免，
  但需测试"同一条目两次补建文件存在且可读"。
- 隐私/成本：<说明数据是否出网、是否需要用户确认>。
```

### 3.3 重构 / 性能优化

```text
优化 <目标函数/流程>：<当前问题>、<期望指标，如 528×792 全变体重算 < 1s>。
约束：输出字节与现实现一致（同输入同输出），测试全绿，
ImageLibrary 对外 API 与持久化文件格式不变。
```

## 4. 测试与验收清单（写进提示词的"完成定义"）

- [ ] `xcodebuild -project macos/TodooCardMacApp.xcodeproj -scheme TodooCardMacApp -destination 'platform=macOS' test` 全绿
- [ ] 算法用例：调色板约束 / 纯色不变 / 抖动混合 / 确定性（AI 类按 3.2 豁免规则）
- [ ] 新变体文件 `<id>.png` 生成、旧文件未改名、启动自动补建生效
- [ ] UI 自动出现新卡片并可选中/发送/重新生成（注册表驱动，无需改布局）
- [ ] 运行时走查：点击卡片选中 → 底部显示变体信息 → 发送按钮可用；重启后选中恢复

## 5. 反模式（这样写会得到糟糕的结果）

- ❌「把图片量化做得更好看一点」——没有目标算法、没有验收标准。
- ❌ 只给算法名字不给规则——「Atkinson 抖动」不同人实现差异很大；给核/公式/出处。
- ❌「顺便优化一下发送和蓝牙」——范围失控；明确列出**不许动**的模块。
- ❌ 要求"AI 自动选最好的算法"——如果没有可量化的选择标准，请先写成规格需求（OpenSpec）再实现。
- ❌ 让 AI 修改既有 `quantized.png`/`dithered.png` 命名或 manifest 字段语义——会破坏已有用户数据。

## 6. 与 OpenSpec 流程配合

改动超过"注册表 + 算法 + 测试"的规模时（新处理方式、数据模型变更、UI 交互变更），
先走提案再实现：

1. `/openspec-propose` —— 用上面五段式内容作为需求描述，生成 proposal / spec / design / tasks
2. 审阅产物 → `/openspec-apply-change` 实现
3. 完成后 `/openspec-archive-change`（先 sync 到主 spec 再归档）

规格写法提醒：spec 只写**可观察行为**（输出约束、持久化、自愈、选中/发送语义），
扩散核权重、类名、文件名留给 design.md 与代码。
