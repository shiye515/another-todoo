# TodooCard Skills 架构图

```mermaid
flowchart TB
    U[User / AI Agent]
    E[scripts/prepare_and_send.sh<br/>编排入口]

    subgraph Build[构建层]
        BS[scripts/build_sender.sh]
        BC[scripts/build_converter.sh]
    end

    subgraph Img[图像与协议层]
        SIPS[/usr/bin/sips<br/>格式归一/旋转]
        CONV[scripts/image_to_payload.swift<br/>六色量化 + 面板映射]
        QLZ[scripts/quicklz_payload.py<br/>v157+ QuickLZ level-3]
        VAL[scripts/validate_payload.py<br/>结构与回解校验]
    end

    subgraph BLE[设备通信层]
        SENDER[scripts/mac_image_transfer.swift<br/>CoreBluetooth 状态机]
        CARD[TodooCard/T3 Device]
    end

    U --> E
    E --> BS --> SENDER
    E --> BC --> CONV
    E --> SIPS --> CONV
    CONV --> RAW[*.controller.bin]
    CONV --> LEGACY[*.protocol.legacy.qlz]
    RAW --> QLZ --> LATEST[*.protocol.qlz]
    RAW --> VAL
    LEGACY --> VAL
    LATEST --> VAL

    VAL -->|--send| SENDER
    SENDER <-->|Control: FEF1/FDF1| CARD
    SENDER <-->|Data: FEF2/FDF2| CARD
    CARD -->|ACK/Checkpoint/Diagnostics| SENDER
```

## 图示说明（简要）

- `prepare_and_send.sh` 是单一入口，统一编排 list/pair/probe/prepare/send。
- 图像处理和协议封装在本地完成并先校验，再进入 BLE 发送。
- BLE 层通过控制通道 + 数据通道执行分块传输，并依据 ACK/Checkpoint 驱动续传或失败诊断。
