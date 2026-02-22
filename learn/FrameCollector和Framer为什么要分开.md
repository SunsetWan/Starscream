# FrameCollector 和 Framer 为什么要分开？

## 问题

`WSFramer`（Framer.swift）和 `FrameCollector`（FrameCollector.swift）都在处理 WebSocket 帧，为什么要拆成两个类？

## 回答

因为它们解决的是**两个不同层次的问题**：

```
TCP 字节流 ──WSFramer──▶ Frame, Frame, Frame ──FrameCollector──▶ .text("完整消息")
            「拆帧」                             「拼消息」
         字节 → 帧结构体                      帧结构体 → 完整消息
```

### WSFramer：解决"字节边界"问题

TCP 是字节流，没有消息边界。WSFramer 的职责是按 RFC 6455 的二进制帧格式，从连续的字节流中识别出一个个独立的 `Frame`：

- 解析 FIN 位、opcode、mask、payload length
- 处理"数据不够，等更多数据到来"的情况（`needsMoreData`）
- 一次 TCP receive 可能包含多个帧，需要循环切割

它**只关心二进制格式**，不关心消息的语义。

### FrameCollector：解决"消息分片"问题

RFC 6455 允许一条消息被拆成多个帧发送（fragmentation）。FrameCollector 的职责是把这些分片帧重新组装成完整消息：

- 第一帧的 opcode 决定消息类型（text/binary）
- 后续帧的 opcode 是 `continueFrame`
- 最后一帧的 `isFin == true` 表示消息结束
- 同时处理解压缩和控制帧（ping/pong/close）的分发

它**只关心消息语义**，不关心底层字节怎么切割。

### 如果合并成一个类会怎样？

会导致**两种复杂性混在一起**：

```swift
// 假设合并后的代码（伪码）
func process() {
    // 一边要处理"字节不够，等更多数据"
    // 一边要处理"帧不够，等更多分片"
    // 一边要处理"控制帧要立即响应"
    // 一边要处理"解压缩"
    // 代码会非常难以理解和维护
}
```

### 分开的好处

| 好处 | 说明 |
|------|------|
| **单一职责** | WSFramer 只管拆字节，FrameCollector 只管拼消息，各自逻辑清晰 |
| **可独立测试** | 可以给 WSFramer 喂各种字节流测试解帧正确性，不需要关心分片逻辑；反之亦然 |
| **可复用** | 如果换一种帧格式，只需替换 Framer；如果改变分片策略，只需改 FrameCollector |
| **线程隔离** | WSFramer 在自己的 DispatchQueue 上解帧，FrameCollector 不需要关心线程问题 |

### 类比

想象一个邮件系统：

- **WSFramer** = 邮局拆包裹：把运输带上连续的包裹拆开，取出里面的信件（不管信件内容）
- **FrameCollector** = 收件人拼信件：一封长信可能分成多个信封寄来，收件人按顺序把它们拼成完整的信
