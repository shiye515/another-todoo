# Tasks

## 1. 图片库服务与模型

- [x] 1.1 `ImageEditConfiguration` 补充 `Codable`；新建 `macos/Models/LibraryImage.swift`（id/displayName/addedAt/configuration，Codable）与 `macos/Services/ImageLibrary.swift`：Application Support 目录管理（每条目目录 processed/quantized/dithered.png + 库根 manifest.json 原子读写）、`add(displayName:processedCGImage:configuration:)` 存成品并即时生成两个量化图、`remove(_:)` 删条目目录+元数据、启动加载（校验成品存在、量化图缺失自动补建）、每条目成品/量化图 NSImage 内存缓存（后台解码）；编译通过
- [x] 1.2 `ImageLibrary` 单元测试（临时目录注入）：多张添加互不覆盖、删除只影响目标、重启加载、成品缺失条目被清理、量化图缺失自动补建；测试通过

## 2. 处理流程与列表重构

- [x] 2.1 `ImageProcessor` 改造：`beginAdd(urls:)` 添加裁剪队列（依次弹裁剪 sheet，取消跳过该张）、确认后经 `ImageLibrary.add` 入库；`requantize(entry:)` 重新量化编排（后台重算两个量化图并覆盖持久化副本，进行中状态防重复触发）；移除量化预览 @Published、`refreshPreview` 与 `.selection` 步骤；全量构建无错误
- [x] 2.2 `ImageView` 重构为单列列表（无处理区）：行 = 缩略图 + 名称/日期 + 量化图发送 + 抖动图发送 + 重新量化（进行中转圈）+ 删除（悬停）；空库引导文案；工具栏"添加图片"（⌘O 多选）接 `beginAdd`；截图验证列表与空态
- [x] 2.3 接线验证：两个发送按钮 → 持久化量化图编码 payload → `TransferProgressSheet`（`.sheet(item:)`）；传输进行中发送/重新量化按钮全局禁用；重新量化覆盖持久化副本（界面操作验证）；删除按钮接线（界面操作验证）
- [x] 2.4 移除量化预览三列 UI（`QuantizationView`）及无关状态；构建与既有测试通过

## 3. 持久化与传输验证

- [x] 3.1 重启恢复验证：完成 2 张图的添加裁剪 → 重启应用 → 列表完整恢复、量化图从磁盘直接可用、发送按钮立即可用；手动删除某条目目录后重启 → 该条目消失且 manifest 清理
- [x] 3.2 真机传输验证：量化图发送与抖动图发送各走一次现有流程（进度弹窗 → 成功），设备成像与预期版本一致；重新量化后再次发送使用新量化图；传输中重复点击被忽略
