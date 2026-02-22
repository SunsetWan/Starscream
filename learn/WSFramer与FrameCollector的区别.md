# WSFramer 与 FrameCollector 的区别

## 问题

`Sources/Framer` 目录下的 `WSFramer`（Framer.swift）和 `FrameCollector`（FrameCollector.swift）命名很相近，它们各自的用途是什么？区别在哪里？

## 回答

两者是流水线上的前后两道工序：

```
TCP 字节流 ──WSFramer──▶ Frame, Frame, Frame ──FrameCollector──▶ .text("完整消息")
              拆帧                                   拼消息
```

### WSFramer（Framer.swift）— 拆字节

- 处理的是**原始 TCP 字节流**，按 RFC 6455 的二进制帧格式（FIN、opcode、mask、payload length…）解析出一个个独立的 `Frame` 结构体
- 类比：把一条长长的纸带剪成一张张卡片

```swift
// WSFramer 的核心：从 buffer 中解析出 Frame
public func add(data: Data) {
    queue.async {
        self?.buffer.append(data)
        while(true) {
            let event = self?.process() ?? .needsMoreData
            switch event {
            case .processedFrame(let frame, let split):
                s.delegate?.frameProcessed(event: .frame(frame))
                // ...
            }
        }
    }
}
```

### FrameCollector（FrameCollector.swift）— 拼消息

- 接收 WSFramer 产出的 `Frame`，处理**消息分片（fragmentation）**：一条消息可能被拆成多个 continuation frame，FrameCollector 把它们的 payload 拼回完整的 `String` 或 `Data`
- 同时处理解压缩、控制帧分发（ping/pong/close）
- 类比：把多张卡片的内容拼回一封完整的信

```swift
// FrameCollector 的核心：累积分片，isFin 时输出完整消息
public func add(frame: Frame) {
    // 控制帧（ping/pong/close）直接分发...

    buffer.append(payload)
    frameCount += 1

    if frame.isFin {
        if isText {
            delegate?.didForm(event: .text(String(data: buffer, encoding: .utf8)!))
        } else {
            delegate?.didForm(event: .binary(buffer))
        }
        reset()
    }
}
```

### 对比总结

| | WSFramer | FrameCollector |
|---|---|---|
| **输入** | 原始 TCP 字节流（Data） | 解析后的 Frame 结构体 |
| **输出** | `Frame` 结构体 | 完整消息（`.text` / `.binary` / `.ping` 等） |
| **职责** | 按 RFC 6455 帧格式拆解二进制数据 | 组装分片、解压缩、分发控制帧 |
| **类比** | 把纸带剪成卡片 | 把多张卡片拼回一封信 |
