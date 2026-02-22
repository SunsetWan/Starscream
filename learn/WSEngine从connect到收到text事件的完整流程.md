# WSEngine：从 `socket.connect()` 到收到 `.text` 事件的完整流程

## 问题

以 WSEngine 为例，从 `socket.connect()` 到收到 `.text` 事件，经过了哪些模块？

## 回答

整个流程经过 **6 个模块**，分为 **握手阶段** 和 **数据阶段**。

---

## 整体流程图

```
socket.connect()
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  WebSocket.connect()                                │
│  ① engine.register(delegate: self)                  │
│  ② engine.start(request: request)                   │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WSEngine.start(request:)                           │
│  ① transport.register(delegate: self)               │
│  ② framer.register(delegate: self)                  │
│  ③ httpHandler.register(delegate: self)             │
│  ④ transport.connect(url:timeout:certificatePinning:)│
└──────────────────────┬──────────────────────────────┘
                       │
═══════════════════════════════════════════════════════
                  握手阶段
═══════════════════════════════════════════════════════
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  TCPTransport.connect(url:)                         │
│  NWConnection 建立 TCP/TLS 连接                      │
│  连接就绪 → connectionChanged(.connected)            │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WSEngine.connectionChanged(.connected)             │
│  ① 生成 secKeyValue                                 │
│  ② HTTPWSHeader.createUpgrade() 构造 Upgrade 请求    │
│  ③ httpHandler.convert() 序列化为 Data               │
│  ④ transport.write() 发送给服务器                     │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  服务器返回 HTTP 101 Switching Protocols             │
│  TCPTransport.readLoop() 读到数据                    │
│  → connectionChanged(.receive(data))                │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WSEngine.connectionChanged(.receive) [didUpgrade=false]│
│  → httpHandler.parse(data:)                         │
│                                                     │
│  FoundationHTTPHandler:                             │
│  ① CFHTTPMessage 解析 HTTP 响应                      │
│  ② 检查状态码 == 101                                 │
│  ③ 回调 didReceiveHTTP(.success(headers))           │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WSEngine.didReceiveHTTP(.success)                  │
│  ① headerChecker.validate() 验证 Sec-WebSocket-Accept│
│  ② didUpgrade = true, canSend = true                │
│  ③ compressionHandler?.load(headers:)               │
│  ④ broadcast(.connected(headers))                   │
└──────────────────────┬──────────────────────────────┘
                       │
═══════════════════════════════════════════════════════
                  数据阶段
═══════════════════════════════════════════════════════
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  TCPTransport.readLoop() 读到 WebSocket 帧数据       │
│  → connectionChanged(.receive(data))                │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WSEngine.connectionChanged(.receive) [didUpgrade=true]│
│  → framer.add(data:)                                │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WSFramer.add(data:) / process()                    │
│  按 RFC 6455 解析帧：FIN, opcode, mask, payload      │
│  → delegate.frameProcessed(.frame(frame))           │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WSEngine.frameProcessed(.frame)                    │
│  → frameHandler.add(frame:)                         │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  FrameCollector.add(frame:)                         │
│  ① 处理分片（fragmentation）                         │
│  ② 如需解压，调用 decompress()                       │
│  ③ frame.isFin → String(data:encoding:.utf8)        │
│  ④ delegate.didForm(.text(string))                  │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WSEngine.didForm(.text)                            │
│  → broadcast(.text(string))                         │
│  → delegate?.didReceive(event: .text(string))       │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  WebSocket.didReceive(event:)                       │
│  callbackQueue.async {                              │
│      delegate?.didReceive(event: .text, client: self)│
│      onEvent?(.text(string))                        │
│  }                                                  │
└─────────────────────────────────────────────────────┘
```

---

## 各模块详解

### 1. WebSocket（入口）

**文件**: `Sources/Starscream/WebSocket.swift`

```swift
public func connect() {
    engine.register(delegate: self)
    engine.start(request: request)
}
```

用户调用 `socket.connect()` 后，WebSocket 将自身注册为 `EngineDelegate`，然后启动 Engine。

### 2. WSEngine（核心调度器）

**文件**: `Sources/Engine/WSEngine.swift`

WSEngine 是整个流程的中枢，它同时实现了 4 个 delegate 协议：

| 协议 | 作用 |
|------|------|
| `TransportEventClient` | 接收 TCP 连接状态和数据 |
| `FramerEventClient` | 接收解析后的 WebSocket 帧 |
| `FrameCollectorDelegate` | 接收组装后的完整消息 |
| `HTTPHandlerDelegate` | 接收 HTTP 升级握手结果 |

`start(request:)` 方法注册所有内部组件的 delegate，然后发起 TCP 连接：

```swift
public func start(request: URLRequest) {
    self.request = request
    transport.register(delegate: self)
    framer.register(delegate: self)
    httpHandler.register(delegate: self)
    frameHandler.delegate = self
    transport.connect(url: url, timeout: request.timeoutInterval, certificatePinning: certPinner)
}
```

### 3. TCPTransport（传输层）

**文件**: `Sources/Transport/TCPTransport.swift`

基于 `Network.framework` 的 `NWConnection` 实现。连接就绪后通过 `stateUpdateHandler` 回调 `.connected`：

```swift
conn.stateUpdateHandler = { [weak self] (newState) in
    switch newState {
    case .ready:
        self?.delegate?.connectionChanged(state: .connected)
    // ...
    }
}
```

通过 `readLoop()` 持续读取数据，每次读到数据都回调 `.receive(data)`。

### 4. HTTP 握手模块

#### HTTPWSHeader（构造请求）

**文件**: `Sources/Framer/HTTPHandler.swift`

为 URLRequest 添加 WebSocket 握手所需的 HTTP 头：

- `Upgrade: websocket`
- `Connection: Upgrade`
- `Sec-WebSocket-Version: 13`
- `Sec-WebSocket-Key: <随机 base64>`

#### FoundationHTTPHandler（解析响应）

**文件**: `Sources/Framer/FoundationHTTPHandler.swift`

用 `CFHTTPMessage` 解析服务器的 HTTP 101 响应，提取 headers 后回调 `didReceiveHTTP(.success(headers))`。

#### FoundationSecurity（验证）

**文件**: `Sources/Security/FoundationSecurity.swift`

验证 `Sec-WebSocket-Accept` 头的 SHA-1 值是否匹配，确保握手合法。

### 5. WSFramer（帧解析器）

**文件**: `Sources/Framer/Framer.swift`

在专用 DispatchQueue 上按 RFC 6455 格式解析 WebSocket 帧：

```swift
public func add(data: Data) {
    queue.async { [weak self] in
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

`process()` 方法解析 FIN 位、opcode、mask、payload length、payload 等字段。

### 6. FrameCollector（消息组装器）

**文件**: `Sources/Framer/FrameCollector.swift`

处理 WebSocket 的消息分片（fragmentation）：

```swift
public func add(frame: Frame) {
    // 处理 ping/pong/close 等控制帧...

    let payload: Data
    if needsDecompression {
        payload = delegate?.decompress(data: frame.payload, isFinal: frame.isFin) ?? frame.payload
    } else {
        payload = frame.payload
    }
    buffer.append(payload)

    if frame.isFin {
        if isText {
            if let string = String(data: buffer, encoding: .utf8) {
                delegate?.didForm(event: .text(string))
            }
        } else {
            delegate?.didForm(event: .binary(buffer))
        }
        reset()
    }
}
```

当所有分片收齐（`isFin == true`）后，将 buffer 转为 String，回调 `.text(string)`。

---

## 模块间的 Delegate 链

### 什么是 Delegate 链？

在 Starscream 中，模块之间不直接调用彼此的方法，而是通过 **delegate 协议** 通信。每个模块只知道"我要把事件通知给我的 delegate"，不关心 delegate 具体是谁。WSEngine 作为中枢，把自己注册为多个模块的 delegate，串联起整条链路。

### 完整的链路图

```
┌──────────────┐    TransportEventClient     ┌──────────┐
│ TCPTransport │ ──────────────────────────▶  │ WSEngine  │
└──────────────┘  "TCP 有数据来了/连上了"       └────┬─────┘
                                                   │
                    ┌──────────────────────────────┤
                    │ WSEngine 把数据分发给          │
                    │ 两个下游模块                   │
                    ▼                              ▼
          ┌─────────────────────┐        ┌──────────────┐
          │ FoundationHTTPHandler│        │   WSFramer    │
          └────────┬────────────┘        └──────┬───────┘
                   │ HTTPHandlerDelegate         │ FramerEventClient
                   │ "HTTP 握手成功了"             │ "解析出一个帧了"
                   ▼                              ▼
             ┌──────────┐                  ┌──────────┐
             │ WSEngine  │                 │ WSEngine  │
             └──────────┘                  └────┬─────┘
                                                │
                                                │ WSEngine 把帧交给
                                                ▼
                                       ┌────────────────┐
                                       │ FrameCollector  │
                                       └───────┬────────┘
                                               │ FrameCollectorDelegate
                                               │ "完整消息拼好了"
                                               ▼
                                         ┌──────────┐
                                         │ WSEngine  │
                                         └────┬─────┘
                                               │ EngineDelegate
                                               │ "这是最终事件"
                                               ▼
                                         ┌──────────┐
                                         │ WebSocket │
                                         └────┬─────┘
                                               │
                                               ▼
                                       用户 delegate / onEvent
```

### 逐跳解释

#### 第 1 跳：TCPTransport → WSEngine

- **协议**: `TransportEventClient`
- **注册时机**: `WSEngine.start()` 中调用 `transport.register(delegate: self)`
- **回调方法**: `connectionChanged(state:)`
- **传递的内容**: TCP 连接状态（`.connected`、`.receive(data)`、`.failed` 等）

```swift
// TCPTransport 内部：连接就绪时
self?.delegate?.connectionChanged(state: .connected)

// TCPTransport 内部：读到数据时
s.delegate?.connectionChanged(state: .receive(data))
```

```swift
// WSEngine 接收（实现 TransportEventClient）：
public func connectionChanged(state: ConnectionState) {
    switch state {
    case .connected:
        // 发送 HTTP Upgrade 请求...
    case .receive(let data):
        if didUpgrade {
            framer.add(data: data)        // → 走第 3 跳
        } else {
            httpHandler.parse(data: data)  // → 走第 2 跳
        }
    }
}
```

#### 第 2 跳：FoundationHTTPHandler → WSEngine（仅握手阶段）

- **协议**: `HTTPHandlerDelegate`
- **注册时机**: `WSEngine.start()` 中调用 `httpHandler.register(delegate: self)`
- **回调方法**: `didReceiveHTTP(event:)`
- **传递的内容**: HTTP 握手结果（`.success(headers)` 或 `.failure(error)`）

```swift
// FoundationHTTPHandler 内部：解析到 101 响应
delegate?.didReceiveHTTP(event: .success(headers))
```

```swift
// WSEngine 接收（实现 HTTPHandlerDelegate）：
public func didReceiveHTTP(event: HTTPEvent) {
    case .success(let headers):
        didUpgrade = true   // 从此数据走 Framer 而不再走 HTTPHandler
        canSend = true
        broadcast(event: .connected(headers))  // → 通知 WebSocket
}
```

> 握手完成后，这条链路就不再使用了。后续数据直接走第 3 跳。

#### 第 3 跳：WSFramer → WSEngine（数据阶段）

- **协议**: `FramerEventClient`
- **注册时机**: `WSEngine.start()` 中调用 `framer.register(delegate: self)`
- **回调方法**: `frameProcessed(event:)`
- **传递的内容**: 解析后的帧（`.frame(Frame)`）或错误

```swift
// WSFramer 内部：成功解析出一个帧
s.delegate?.frameProcessed(event: .frame(frame))
```

```swift
// WSEngine 接收（实现 FramerEventClient）：
public func frameProcessed(event: FrameEvent) {
    case .frame(let frame):
        frameHandler.add(frame: frame)  // → 走第 4 跳
}
```

#### 第 4 跳：FrameCollector → WSEngine

- **协议**: `FrameCollectorDelegate`
- **注册时机**: `WSEngine.init()` 中 `frameHandler.delegate = self`
- **回调方法**: `didForm(event:)`
- **传递的内容**: 组装后的完整消息（`.text(String)`、`.binary(Data)` 等）

```swift
// FrameCollector 内部：分片收齐，拼出完整消息
delegate?.didForm(event: .text(string))
```

```swift
// WSEngine 接收（实现 FrameCollectorDelegate）：
public func didForm(event: FrameCollector.Event) {
    case .text(let string):
        broadcast(event: .text(string))  // → 走第 5 跳
}
```

#### 第 5 跳：WSEngine → WebSocket → 用户

- **协议**: `EngineDelegate`
- **注册时机**: `WebSocket.connect()` 中调用 `engine.register(delegate: self)`
- **回调方法**: `didReceive(event:)`
- **传递的内容**: 最终的 `WebSocketEvent`（`.text`、`.binary`、`.connected` 等）

```swift
// WSEngine 内部的 broadcast 方法：
private func broadcast(event: WebSocketEvent) {
    delegate?.didReceive(event: event)
}
```

```swift
// WebSocket 接收（实现 EngineDelegate），再转发给用户：
public func didReceive(event: WebSocketEvent) {
    callbackQueue.async {
        self.delegate?.didReceive(event: event, client: self)  // 用户的 delegate
        self.onEvent?(event)                                    // 用户的闭包
    }
}
```

### 为什么 WSEngine 出现了这么多次？

注意到 WSEngine 在图中反复出现——它**同时是 4 个模块的 delegate**：

| 谁通知 WSEngine | 通过什么协议 | WSEngine 的回调方法 |
|----------------|------------|-------------------|
| TCPTransport | `TransportEventClient` | `connectionChanged(state:)` |
| FoundationHTTPHandler | `HTTPHandlerDelegate` | `didReceiveHTTP(event:)` |
| WSFramer | `FramerEventClient` | `frameProcessed(event:)` |
| FrameCollector | `FrameCollectorDelegate` | `didForm(event:)` |

这正是 WSEngine 作为"中枢调度器"的设计意图：所有事件都汇聚到 WSEngine，由它决定下一步交给谁处理，最终通过 `EngineDelegate` 把结果传给 WebSocket。

---

## 关键设计点

1. **协议驱动的分层架构**：每个模块通过 protocol + delegate 解耦，Transport、Framer、HTTPHandler 都可以替换实现。

2. **WSEngine 是中枢**：它同时作为 4 个 delegate 的实现者，串联了从 TCP 到用户回调的整个链路。

3. **两阶段数据路由**：`didUpgrade` 标志决定收到的 TCP 数据是走 HTTP 解析还是 WebSocket 帧解析，巧妙地复用了同一个 `connectionChanged(.receive)` 回调。

4. **线程安全**：`canSend`、`isConnecting`、`didUpgrade` 等共享状态通过 `DispatchSemaphore` (mutex) 保护；帧解析和写操作分别在独立的 DispatchQueue 上执行。
