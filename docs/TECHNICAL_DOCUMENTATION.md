# TodooCard Skills 技术文档

本文档基于 `todoocard-skills` 当前实现（`scripts/*.sh|*.swift|*.py` 与 `SKILL.md`）整理，面向工程实现与维护，聚焦三部分：**流程**、**架构**、**技术细节**。

## 一、流程（Workflow）

### 1. 端到端主流程

`scripts/prepare_and_send.sh` 是统一入口，负责参数校验、依赖检查、构建工具链、图片准备、协议打包、本地校验和可选 BLE 发送。

主流程如下：

1. **模式解析与互斥校验**  
   支持 `--list` / `--pair` / `--probe` / `--input ... [--send]` 四类模式，且一次只允许一个操作模式。

2. **环境与输入安全校验**  
   - 必须存在 `swiftc`；prepare/send 还要求 `python3` 与 `/usr/bin/sips`。  
   - `pair/probe/send` 必须指定精确 `--device-id`。  
   - `prepare/send` 校验输入文件存在、大小不超过 100MB、像素不超过 50MP。

3. **临时运行目录装配**  
   在 `/tmp` 下创建临时目录，复制 scripts，构建：
   - `mac-image-transfer`（Swift，BLE 侧）
   - `image-to-payload`（Swift，图像转 payload）

4. **分支执行**
   - `--list`：只扫描打印附近 BLE 设备信息。  
   - `--pair`：等待配对窗口打开后执行加密配对校验。  
   - `--probe`：验证设备身份、加密链路与特征能力，不写屏。  
   - `prepare/send`：
     1) 用 `sips` 归一为 PNG（可选 `--rotate-right-90`）；  
     2) `image_to_payload.swift` 生成 `*.controller.bin` 与 legacy `*.protocol.legacy.qlz`；  
     3) `quicklz_payload.py` 生成 v157+ `*.protocol.qlz`；  
     4) `validate_payload.py` 对 raw/QuickLZ 双路径进行可解码一致性校验；  
     5) 仅当显式 `--send` 才调用 BLE 发送。

### 2. 配对与探测流程

`mac_image_transfer.swift` 中 `pairOnly/probeOnly` 是独立流程：

- **pair**：只在广告位 `pairing=open`（能力位 `0x02`）时连接；通过读取加密 Battery Level (`180F/2A19`) 作为配对成功唯一判据。  
- **probe**：验证厂商 ID (`0x5053`)、屏幕类型 (`0x134C`)、加密可达性与 FEF1/FEF2 特征；v165+ 额外读取保留 ACK 诊断特征。

### 3. 传输流程（send）

发送由控制通道（FEF1/FDF1）+ 数据通道（FEF2/FDF2）驱动：

1. 请求 block size（`requestBlockSize`）。  
2. 上报 payload 总长度与模式（`requestScreenSize`）。  
3. 启动传输（`requestStartTransfer`）。  
4. 分块写入并处理 `dataAck`：  
   - 新固件（v157+）使用**32 块窗口 + durable checkpoint**；  
   - 旧路径按 ACK index 逐块推进。  
5. 必须收到 `0x05/0x08` 最终刷新确认才判定成功；断连不视为成功。  

失败时若 firmware >= v165，会优先读取诊断特征后再退出。

## 二、架构（Architecture）

### 1. 模块分层

> 架构图文件已单独放在：`docs/architecture-diagram.md`

```text
prepare_and_send.sh  (编排层 / CLI 入口)
 ├─ build_sender.sh + mac_image_transfer.swift      (BLE 连接、配对、探测、发送)
 ├─ build_converter.sh + image_to_payload.swift     (图像归一、六色量化、面板映射)
 ├─ quicklz_payload.py                              (v157+ QuickLZ level-3 编码与自验)
 ├─ validate_payload.py                             (payload 结构/解码一致性校验)
 └─ test_protocol.py                                (QuickLZ 协议确定性测试)
```

### 2. 职责划分

- **Shell 编排层**：参数互斥、安全限制、依赖探测、临时目录生命周期、工具调用顺序。  
- **Swift 图像层**：面向像素与控制器格式，做 palette/dither/orientation/controller pack。  
- **Python 协议层**：实现并验证 QuickLZ 封装（新旧两种格式可识别）。  
- **Swift BLE 层**：CoreBluetooth 生命周期、特征协商、控制命令状态机、可靠传输策略与失败诊断。

### 3. 数据与控制流

1. **输入图像** → `sips` 归一 PNG；  
2. PNG → 六色半字节 bitmap (`.bin`)；  
3. bitmap → 控制器 raw (`.controller.bin`)；  
4. raw → legacy QuickLZ (`.protocol.legacy.qlz`) + v157+ QuickLZ (`.protocol.qlz`)；  
5. `validate_payload.py` 解包回 raw 并与 expected raw 比对；  
6. `mac-image-transfer` 根据广播固件能力选择 `compressed/raw/legacy` 发送策略。  

## 三、技术细节（Technical Details）

### 1. 设备识别与安全边界

- 广播解析结构：`manufacturerID/screenType/capabilityFlags/firmwareVersion`。  
- 仅接受 `manufacturer=0x5053`、`screen=0x134C` 的目标设备。  
- `secure pairing` 判定：`firmware>=0x8C && flag&0x01`。  
- 新设备配对窗口（`flag&0x02`）开启时，拒绝 probe/send，避免配对与传图混线。  
- OTA 恢复模式（`flag&0x08`）下拒绝传图。

### 2. 图像处理与方向策略

- 调色板固定为 6 色：black/white/yellow/red/blue/green（4-bit code 打包，每字节两像素）。  
- 抖动算法：Floyd–Steinberg 误差扩散。  
- T3 强制方向：`todoocard-correct`，在底层做 `rotated180 + flippedHorizontally`；调用方不可覆盖 `--screen-orientation`。  
- 输出文件：
  - `<prefix>.bin`：面板位图；
  - `<prefix>.controller.bin`：控制器顺序位图；
  - `<prefix>.protocol.legacy.qlz`：旧固件兼容流。

### 3. QuickLZ 协议实现

- v157+ 路径：2KB 独立 block，QuickLZ 1.5 level-3；payload 以四字节 `0x00` 前缀拼接分块。  
- 若压缩块不收益，单块退化为 stored block；最终传输时还会与 raw 线路进行“线上字节开销”比较选择最优。  
- `inspect_payload/unwrap_payload` 可验证：
  - header 合法性；
  - block 级 decoded size；
  - 全量 round-trip 一致性。  
- `test_protocol.py` 用固定样本校验输出确定性（含 SHA-256）。

### 4. 传输可靠性机制

- **新固件验证传输**（`firmware>=0x9D`）：  
  - 以 32 blocks 为窗口发送；  
  - 窗口边界等待设备 durable checkpoint；  
  - 超时后只重发窗口尾块探测进度，不盲目全量重传；  
  - 最多 16 次 repair/probe。  
- **ACK 语义**：  
  - `0x01`：包格式/顺序错误；  
  - `0x09`：Flash 写失败；  
  - `0x0A`：Flash 回读校验失败。  
- **成功判据**：必须收到 `dataAck = transferEnd(0x08)`。  
- **控制通道容错**：withResponse 超时可自动 fallback 到 withoutResponse 重试，避免单路径阻塞。

### 5. 运行与隐私约束

- 本地执行，不依赖网络调用。  
- 临时产物在 `/tmp/potatocard-transfer.*`；输入与 payload 视为隐私文件。  
- 通过参数与尺寸上限约束，避免误写设备与大图导致的资源风险。

---

如后续新增型号或协议版本，建议保持当前“编排层 + 图像层 + 协议层 + BLE 层”的分层，不把固件分支逻辑扩散到 Shell 入口，以降低回归风险。
