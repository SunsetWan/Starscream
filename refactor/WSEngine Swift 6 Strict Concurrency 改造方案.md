# WSEngine Swift 6 Strict Concurrency 改造方案

> 目标：分析 `WSEngine` 适配 Swift 6 strict concurrency 的技术路径，对比多种方案的优劣，给出推荐实施路线。

---

## 一、现状分析：WSEngine 的并发模型

### 1.1 当前同步原语

```swift
public class WSEngine: Engine, TransportEventClient, FramerEventClient,
                       FrameCollectorDelegate, HTTPHandlerDelegate {
    // 同步原语 ①：DispatchSemaphore 保护状态标志位
    private let mutex = DispatchSemaphore(value: 1)
    private var canSend = false
    private var isConnecting = false
    private var didUpgrade = false

    // 同步原语 ②：专用串行队列序列化写操作
    private let writeQueue = DispatchQueue(label: "com.vluxe.starscream.writequeue")
}
```

### 1.2 数据流与线程模型

```
                用户线程                    Transport 队列              WSFramer 队列
                  │                            │                          │
    write()       │                            │                          │
    ─────────────▶│                            │                          │
                  │  writeQueue.async           │                          │
                  │──────────────────▶          │                          │
                  │  mutex.wait/signal          │                          │
                  │  framer.createWriteFrame    │                          │
                  │  transport.write            │                          │
                  │                             │                          │
                  │                  NWConnection callback                 │
                  │                  ◀──────────│                          │
                  │  connectionChanged()        │                          │
                  │◀────────────────────────────│                          │
                  │                             │                          │
                  │  httpHandler.parse()         │                          │
                  │  framer.add(data:)           │                          │
                  │                              │     queue.async          │
                  │                              │────────────────────────▶│
                  │                              │  frameProcessed()       │
                  │◀──────────────────────────────────────────────────────│
                  │  delegate?.didReceive()      │                          │
```

**关键问题**：回调可能从 3 个不同的队列/线程到达 WSEngine：
1. **用户线程** — 调用 `start()`、`write()`、`stop()`
2. **Transport 队列** — `NWConnection` 的 `com.vluxe.starscream.networkstream` 队列
3. **WSFramer 队列** — `com.vluxe.starscream.wsframer` 队列

### 1.3 持有的非 Sendable 对象

| 属性 | 类型 | Sendable? | 说明 |
|------|------|-----------|------|
| `transport` | `Transport` (protocol) | ❌ | `AnyObject`，内部持有 `NWConnection` + 可变状态 |
| `framer` | `Framer` (protocol) | ❌ | `WSFramer` 内部有 `DispatchQueue` + 可变 `buffer` |
| `httpHandler` | `HTTPHandler` (protocol) | ❌ | 协议类型，实现类有可变状态 |
| `frameHandler` | `FrameCollector` (class) | ❌ | 有可变 `buffer`、`frameCount` 等 |
| `compressionHandler` | `CompressionHandler?` (protocol) | ❌ | 有内部状态 |
| `certPinner` | `CertificatePinning?` (protocol) | ❌ | `AnyObject` 协议 |
| `headerChecker` | `HeaderValidator` (protocol) | ❌ | `AnyObject` 协议 |
| `delegate` | `EngineDelegate?` (weak) | ❌ | `AnyObject` 协议 |

### 1.4 协议拓扑（全部是同步 + AnyObject）

```
Engine (同步方法)
  ├── register(delegate:)
  ├── start(request:)
  ├── stop(closeCode:)
  ├── forceStop()
  ├── write(data:opcode:completion:)
  └── write(string:completion:)

EngineDelegate: AnyObject (同步回调)
  └── didReceive(event:)

TransportEventClient: AnyObject (同步回调)
  └── connectionChanged(state:)

FramerEventClient: AnyObject (同步回调)
  └── frameProcessed(event:)

FrameCollectorDelegate: AnyObject (同步回调)
  ├── didForm(event:)
  └── decompress(data:isFinal:) -> Data?

HTTPHandlerDelegate: AnyObject (同步回调)
  └── didReceiveHTTP(event:)
```

所有协议都是：
- `AnyObject` 约束（只能 class/actor 实现）
- **同步方法**（没有 `async`）
- **没有 `Sendable` 约束**

### 1.5 Package.swift 现状

```swift
// swift-tools-version:5.3
```

没有启用任何 strict concurrency 检查，也没有 Swift 6 language mode。

---

## 二、Swift 6 Strict Concurrency 会报什么错？

如果把 `Package.swift` 改为 Swift 6 mode 或启用 `StrictConcurrency=complete`，WSEngine 会面临以下编译错误：

### 2.1 WSEngine 自身不是 Sendable

```swift
// ❌ Class 'WSEngine' does not conform to 'Sendable'
// 因为它有可变存储属性（canSend, isConnecting, didUpgrade 等）
// 且不是 final class + 全 let 属性
```

### 2.2 跨隔离域传递 non-Sendable 类型

```swift
// WSEngine 持有的 Transport、Framer 等都不是 Sendable
// 在 closure 里捕获它们会报错：
writeQueue.async { [weak self] in
    // ❌ Capture of 'self' with non-Sendable type 'WSEngine' in @Sendable closure
    guard let s = self else { return }
    s.mutex.wait()  // ❌ Instance method 'wait' is unavailable from async contexts
}
```

### 2.3 Completion handler 不是 @Sendable

```swift
public func write(data: Data, opcode: FrameOpCode, completion: (() -> ())?) {
    // ❌ completion 没有标记 @Sendable，但在 writeQueue.async 里调用
}
```

### 2.4 delegate 跨线程回调

```swift
private func broadcast(event: WebSocketEvent) {
    delegate?.didReceive(event: event)
    // ❌ WebSocketEvent 关联值包含 Error?（不是 Sendable）
    // ❌ delegate 是 non-Sendable 的 AnyObject 引用
}
```

---

## 三、方案对比

### 方案 A：Actor 化（理想方案）

**核心思路**：`class WSEngine` → `actor WSEngine`，移除所有 GCD 同步原语，用 actor 隔离保证线程安全。

#### 改造要点

```swift
// ① WSEngine 改为 actor
public actor WSEngine: Engine, TransportEventClient, FramerEventClient,
                       FrameCollectorDelegate, HTTPHandlerDelegate {
    // ② 移除 GCD 同步原语
    // private let mutex = DispatchSemaphore(value: 1)  // 删除
    // private let writeQueue = DispatchQueue(...)       // 删除

    // ③ 可变状态自动受 actor 隔离保护
    private var canSend = false
    private var isConnecting = false
    private var didUpgrade = false

    // ④ 持有的子组件也被 actor 隔离保护
    private let transport: Transport
    private let framer: Framer
    // ...
}
```

#### 问题 1：同步协议 → 需要 `nonisolated` + `Task` 跳板

当前所有协议方法都是同步的。actor 实现同步协议方法时必须标记 `nonisolated`，然后跳回 actor：

```swift
extension WSEngine: TransportEventClient {
    // 协议要求是同步的，actor 必须 nonisolated
    nonisolated public func connectionChanged(state: ConnectionState) {
        Task { await self.handleConnectionChanged(state) }
    }

    // 真正的逻辑在 actor-isolated 方法中
    private func handleConnectionChanged(_ state: ConnectionState) {
        switch state {
        case .connected:
            // ... actor-isolated，安全访问所有属性
        }
    }
}
```

**⚠️ 风险：事件顺序**

```
Transport 队列快速发出三个事件：
  connectionChanged(.connected)    → Task①
  connectionChanged(.receive(d1))  → Task②
  connectionChanged(.receive(d2))  → Task③

这三个 Task 会按 actor 的 FIFO 顺序执行，
但 Task 的创建本身是异步的，理论上 Task② 可能在 Task① 之前创建。
在实践中，由于 Transport 队列是串行的，Task 创建顺序通常是确定的。
但这不是编译器保证的——这是一个微妙的正确性假设。
```

#### 问题 2：non-Sendable 存储属性

```swift
actor WSEngine {
    private let transport: Transport  // ← Transport 不是 Sendable
}
```

Swift 6 中，actor 可以持有 non-Sendable 类型作为存储属性（它们被隔离在 actor 内）。**但问题是这些对象的回调会从其他线程/队列调用到 actor**：

```swift
// Transport 内部在自己的队列上调用 delegate.connectionChanged()
// 这个调用到达 WSEngine 时，是从外部线程进入 actor
// 需要 nonisolated 入口 + Task 跳回 actor
```

#### 问题 3：delegate 发射跨越隔离边界

```swift
actor WSEngine {
    weak var delegate: EngineDelegate?  // ❌ non-Sendable 跨边界

    private func broadcast(event: WebSocketEvent) {
        delegate?.didReceive(event: event)
        // ❌ 从 actor 内部调用外部 non-Sendable 对象的方法
        // 需要 delegate 标记为 Sendable，或者用 nonisolated 调用
    }
}
```

解决方式：

```swift
// 方式 A：将 delegate 调用标记为 nonisolated
nonisolated private func emitEvent(_ event: WebSocketEvent) {
    delegate?.didReceive(event: event)  // 但 delegate 是 actor-isolated 的...
}
// → 行不通，nonisolated 方法不能访问 actor-isolated 的 delegate 属性

// 方式 B：要求 EngineDelegate 是 Sendable
public protocol EngineDelegate: AnyObject, Sendable {
    func didReceive(event: WebSocketEvent)
}
// → API 破坏性变更，WebSocket 类也需要改
```

#### 问题 4：`decompress` 的同步返回值

```swift
public protocol FrameCollectorDelegate: AnyObject {
    func decompress(data: Data, isFinal: Bool) -> Data?  // 同步返回
}
```

如果 WSEngine 是 actor，`decompress` 需要 `nonisolated`，但它需要访问 `compressionHandler`（actor-isolated 属性）：

```swift
// ❌ 矛盾：
nonisolated public func decompress(data: Data, isFinal: Bool) -> Data? {
    return compressionHandler?.decompress(data: data, isFinal: isFinal)
    // ❌ Actor-isolated property 'compressionHandler' can not be referenced from nonisolated context
}
```

**这是 actor 方案最难解决的问题**。除非把协议改成 async：

```swift
// 协议改为 async（API 破坏性变更）
public protocol FrameCollectorDelegate: AnyObject {
    func decompress(data: Data, isFinal: Bool) async -> Data?
}
```

#### Actor 方案的完整改造代价

| 改动 | 影响范围 | 破坏性 |
|------|---------|--------|
| WSEngine class → actor | WSEngine.swift | 🔴 内部重写 |
| 5 个 delegate 协议全部加 async | Framer.swift, Transport.swift, HTTPHandler.swift, FrameCollector.swift, Engine.swift | 🔴 API 破坏 |
| EngineDelegate 加 Sendable | Engine.swift | 🔴 API 破坏 |
| WebSocket 调用 engine 全部加 await | WebSocket.swift | 🔴 API 破坏 |
| Transport/Framer/HTTPHandler 所有实现类适配 async | TCPTransport, WSFramer, FoundationHTTPHandler... | 🔴 全面重写 |
| WebSocketEvent 枚举 Sendable 化 | WebSocket.swift | 🟡 Error? 关联值问题 |
| CertificatePinning 协议 async 化 | Security.swift | 🔴 API 破坏 |

**结论**：actor 方案本质上是**全新架构**，不是"迁移"。

---

### 方案 B：`@unchecked Sendable` + 单队列隔离（Alamofire 方式）

**核心思路**：保持 class，手动保证线程安全，用 `@unchecked Sendable` 告诉编译器"我已确保安全"。

#### Alamofire 的做法

```swift
// Alamofire 的核心类全部是这个模式：
open class Session: @unchecked Sendable { ... }
public class Request: @unchecked Sendable { ... }
open class SessionDelegate: NSObject, @unchecked Sendable { ... }

// 线程安全通过以下手段保证：
// ① Protected<T> — 基于 os_unfair_lock 的线程安全包装器
final class Protected<Value> {
    private let lock = UnfairLock()
    private nonisolated(unsafe) var value: Value

    func read<U>(_ closure: (Value) throws -> U) rethrows -> U {
        try lock.around { try closure(self.value) }
    }

    @discardableResult
    func write<U>(_ closure: (inout Value) throws -> U) rethrows -> U {
        try lock.around { try closure(&self.value) }
    }
}

// ② rootQueue — 所有内部操作的串行根队列
public let rootQueue: DispatchQueue  // serial
```

#### WSEngine 的改造

**Step 1：声明 `@unchecked Sendable`**

```swift
public final class WSEngine: Engine, TransportEventClient, FramerEventClient,
                              FrameCollectorDelegate, HTTPHandlerDelegate,
                              @unchecked Sendable {
    // final 是必须的（non-final class 不能 conform Sendable）
}
```

**Step 2：合并为单一引擎队列**

当前有两个并发域（`mutex` 保护状态 + `writeQueue` 序列化写入），回调还从 Transport/Framer 的队列到达。改为统一的 `engineQueue`：

```swift
public final class WSEngine: /* ... */, @unchecked Sendable {
    // ① 统一的引擎队列（替代 mutex + writeQueue）
    private let engineQueue = DispatchQueue(label: "com.vluxe.starscream.engine")

    // ② 所有状态变量不再需要额外锁保护
    //    因为只在 engineQueue 上访问
    private var canSend = false
    private var isConnecting = false
    private var didUpgrade = false
    private var secKeyValue = ""
    private var request: URLRequest!

    // ③ 子组件也只在 engineQueue 上操作
    private let transport: Transport
    private let framer: Framer
    // ...
}
```

**Step 3：所有入口方法跳到 engineQueue**

```swift
// 用户调用的方法
public func start(request: URLRequest) {
    engineQueue.async { [self] in
        guard !isConnecting, !canSend else { return }
        self.request = request
        isConnecting = true

        transport.register(delegate: self)
        framer.register(delegate: self)
        httpHandler.register(delegate: self)
        frameHandler.delegate = self

        guard let url = request.url else { return }
        transport.connect(url: url, timeout: request.timeoutInterval,
                          certificatePinning: certPinner)
    }
}

public func write(data: Data, opcode: FrameOpCode, completion: (() -> ())?) {
    engineQueue.async { [self] in
        guard canSend else { return }

        var isCompressed = false
        var sendData = data
        if let compressedData = compressionHandler?.compress(data: data) {
            sendData = compressedData
            isCompressed = true
        }

        let frameData = framer.createWriteFrame(opcode: opcode, payload: sendData,
                                                 isCompressed: isCompressed)
        transport.write(data: frameData) { _ in
            completion?()
        }
    }
}

// 从其他队列到达的回调 — 统一跳到 engineQueue
public func connectionChanged(state: ConnectionState) {
    engineQueue.async { [self] in
        handleConnectionChanged(state)
    }
}

public func frameProcessed(event: FrameEvent) {
    engineQueue.async { [self] in
        handleFrameProcessed(event)
    }
}

public func didReceiveHTTP(event: HTTPEvent) {
    engineQueue.async { [self] in
        handleHTTPEvent(event)
    }
}

public func didForm(event: FrameCollector.Event) {
    engineQueue.async { [self] in
        handleFrameCollectorEvent(event)
    }
}

// decompress 是同步返回的，不需要跳队列
// 因为它从 FrameCollector.add() 同步调用，
// 而 FrameCollector.add() 已经在 engineQueue 上了
public func decompress(data: Data, isFinal: Bool) -> Data? {
    return compressionHandler?.decompress(data: data, isFinal: isFinal)
}
```

**Step 4：协议和 delegate 不需要改动**

```swift
// 完全保持现有 API 不变：
public protocol Engine { /* 不变 */ }
public protocol EngineDelegate: AnyObject { /* 不变 */ }
public protocol TransportEventClient: AnyObject { /* 不变 */ }

// WebSocket 也不需要改动
open class WebSocket: WebSocketClient, EngineDelegate { /* 不变 */ }
```

**Step 5（可选）：子组件也标记 `@unchecked Sendable`**

```swift
// 如果子组件从 WSEngine 外部也被使用，需要标记
// 如果只在 WSEngine 内部使用，不需要（被 @unchecked Sendable 的宿主覆盖）

// TCPTransport 已经用 DispatchQueue 保护，可以标记
@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
public final class TCPTransport: Transport, @unchecked Sendable { ... }

// WSFramer 已经用 DispatchQueue 保护
public final class WSFramer: Framer, @unchecked Sendable { ... }
```

#### 改造代价

| 改动 | 影响范围 | 破坏性 |
|------|---------|--------|
| WSEngine 加 `final` + `@unchecked Sendable` | WSEngine.swift | 🟡 `final` 可能影响子类化（但 WSEngine 极少被继承） |
| 合并 mutex + writeQueue → engineQueue | WSEngine.swift | 🟢 内部重构，API 不变 |
| delegate 回调入口加 engineQueue.async | WSEngine.swift | 🟢 行为略变（callback 延迟一跳），API 不变 |
| TCPTransport/WSFramer 加 `@unchecked Sendable` | 各文件 | 🟢 仅加声明 |
| WebSocketEvent 考虑 Sendable | WebSocket.swift | 🟡 `.error(Error?)` 的 Error 不是 Sendable |
| completion 参数加 `@Sendable` | Engine 协议 | 🟡 可能影响调用者 |

**总结**：改动集中在 WSEngine.swift 内部，API 基本不变。

---

### 方案 C：Mutex（iOS 18+ / Synchronization 框架）

**核心思路**：用 `import Synchronization` 的 `Mutex<T>` 替代 `DispatchSemaphore`，实现编译器可验证的同步。

```swift
import Synchronization

public final class WSEngine: /* ... */, Sendable {
    // Mutex 包装所有可变状态
    private let state = Mutex(EngineState())

    struct EngineState {
        var canSend = false
        var isConnecting = false
        var didUpgrade = false
        var secKeyValue = ""
        var request: URLRequest? = nil
    }

    // 不可变属性（init 后不变）
    private let transport: Transport      // ← 问题：Transport 不是 Sendable
    private let framer: Framer            // ← 问题：Framer 不是 Sendable
    // ...
}
```

**问题**：`Mutex` 只能保护 `Sendable` 类型的值。`Transport`、`Framer` 等协议类型不是 Sendable，无法放入 `Mutex`。

如果要用 Mutex，要么：
- 所有协议加 `Sendable` 约束（API 破坏）
- 只用 Mutex 保护简单状态，子组件仍用其他方式隔离

**适用场景**：Mutex 最适合保护"简单值状态"（如 `canSend`、`isConnecting`），不适合保护"持有 non-Sendable 引用"的复杂对象图。

```swift
// Mutex 最佳使用场景：替代 DispatchSemaphore 保护标志位
// 但 WSEngine 的问题不仅仅是标志位，还有跨线程的子组件操作
// 所以 Mutex 不是完整解决方案
```

---

### 方案 D：AsyncStream 替代 Delegate（面向未来）

**核心思路**：不改 WSEngine 内部，在 `WebSocket` 层提供 `AsyncStream<WebSocketEvent>` 作为现代 API。

#### 在 WebSocket 上添加 AsyncStream（增量式，不破坏现有 API）

```swift
extension WebSocket {
    /// 现代 async/await API，与 delegate/onEvent 并存
    public func events() -> AsyncStream<WebSocketEvent> {
        AsyncStream { continuation in
            let previousHandler = self.onEvent
            self.onEvent = { event in
                previousHandler?(event)       // 保留原有回调
                continuation.yield(event)      // 同时发射到 stream
            }
            continuation.onTermination = { @Sendable _ in
                // 清理：恢复原有回调
                self.onEvent = previousHandler
            }
        }
    }
}

// 用户使用：
let socket = WebSocket(request: request)
socket.connect()

for await event in socket.events() {
    switch event {
    case .connected(let headers):
        print("Connected: \(headers)")
    case .text(let message):
        print("Received: \(message)")
    case .disconnected(let reason, let code):
        print("Disconnected: \(reason) (\(code))")
        break
    case .error(let error):
        print("Error: \(error?.localizedDescription ?? "unknown")")
    default:
        break
    }
}
```

#### 更进一步：async write

```swift
extension WebSocket {
    /// async 版本的 write
    public func write(string: String) async {
        await withCheckedContinuation { continuation in
            write(string: string) {
                continuation.resume()
            }
        }
    }

    public func write(data: Data) async {
        await withCheckedContinuation { continuation in
            write(data: data) {
                continuation.resume()
            }
        }
    }
}
```

#### 对比 Alamofire 的 Concurrency.swift

Alamofire 在 `Source/Features/Concurrency.swift` 中提供了类似的增量式 async API：

```swift
// Alamofire 的做法：在 Request 上提供 StreamOf<T>（本质是 AsyncStream 包装）
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension Request {
    public func uploadProgress(...) -> StreamOf<Progress> {
        stream(bufferingPolicy: bufferingPolicy) { [unowned self] continuation in
            uploadProgress(queue: underlyingQueue) { progress in
                continuation.yield(progress)
            }
        }
    }
}

// DataTask — async/await 版本的请求
public struct DataTask<Value>: Sendable where Value: Sendable {
    public var response: DataResponse<Value, AFError> {
        get async { await task.value }
    }

    public var value: Value {
        get async throws { try await result.get() }
    }
}
```

**关键区别**：
- Alamofire 的 `StreamOf` / `DataTask` 是**新增 API**，不替代现有的 closure/delegate API
- 内部仍然基于 GCD + `@unchecked Sendable`
- async API 只是**桥接层**，不改变内部架构

---

## 四、方案对比总表

| 维度 | A: Actor | B: @unchecked Sendable | C: Mutex | D: AsyncStream |
|------|----------|----------------------|----------|----------------|
| **编译器安全保证** | ✅ 完全由编译器保证 | ❌ 手动保证，编译器不检查 | 🟡 部分保证（值类型） | ❌ 不解决内部并发 |
| **API 破坏性** | 🔴 全面破坏 | 🟢 几乎无 | 🟡 需要 iOS 18+ | 🟢 纯增量 |
| **改动范围** | 🔴 XL（全部协议+实现） | 🟢 S（WSEngine 内部） | 🟡 M（状态管理重构） | 🟢 S（WebSocket 增加方法） |
| **事件顺序保证** | 🟡 需要额外设计 | ✅ 单队列天然保证 | ✅ 锁保证原子性 | N/A |
| **reentrancy 风险** | 🟡 actor reentrancy | 🟡 同步回调可能重入 | 🟡 死锁风险 | N/A |
| **与现有子组件兼容** | 🔴 全部需要适配 | ✅ 完全兼容 | 🟡 non-Sendable 问题 | ✅ 完全兼容 |
| **实施工时** | >2 天 | 1-3 小时 | 半天 | 1-2 小时 |
| **Alamofire 选择** | ❌ | ✅ 正是这个方案 | ❌ | ✅ 增量提供 |

---

## 五、推荐方案：B + D 组合

### 第一阶段：B 方案（@unchecked Sendable + 单队列）— 解决编译问题

**目标**：在 Swift 6 mode 下干净编译，不改变公开 API。

```
改动清单：
├── WSEngine.swift
│   ├── class → final class
│   ├── 加 @unchecked Sendable
│   ├── 移除 mutex (DispatchSemaphore) + writeQueue
│   ├── 新增 engineQueue (串行 DispatchQueue)
│   ├── 所有入口方法 → engineQueue.async
│   └── 内部逻辑方法 private 化
│
├── TCPTransport.swift
│   └── 加 @unchecked Sendable（已有 queue 保护）
│
├── WSFramer.swift（Framer.swift）
│   └── 加 @unchecked Sendable（已有 queue 保护）
│
├── FrameCollector.swift
│   └── 考虑 @unchecked Sendable 或保持内部使用
│
├── Engine.swift
│   └── completion 参数加 @Sendable
│
├── WebSocket.swift
│   ├── 加 @unchecked Sendable
│   └── onEvent 闭包加 @Sendable
│
└── Package.swift
    └── 启用 StrictConcurrency=complete 或 Swift 6 mode
```

### 第二阶段：D 方案（AsyncStream）— 提供现代 API

**目标**：为使用者提供 async/await 风格的 API，与 delegate/closure API 并存。

```
新增文件：
└── Sources/Starscream/WebSocket+Concurrency.swift
    ├── func events() -> AsyncStream<WebSocketEvent>
    ├── func write(string:) async
    ├── func write(data:) async
    └── func connect() async throws  // 可选：等待 connected 事件
```

### 第三阶段（远期）：A 方案 — 如果决定做 v5 大版本

仅当决定发布 Starscream 5.0（允许 API 破坏）时，才考虑 actor 化：

```
需要重新设计的协议：
├── Engine → async 方法
├── Transport → async 方法 + Sendable
├── Framer → async 方法 + Sendable
├── EngineDelegate → AsyncStream 或 @Sendable closure
├── CertificatePinning → async evaluateTrust
└── 移除所有 AnyObject 约束（actor 不需要）
```

---

## 六、WebSocketEvent 的 Sendable 问题

不论哪个方案，`WebSocketEvent` 都需要解决 Sendable 问题：

```swift
public enum WebSocketEvent {
    case connected([String: String])  // ✅ Sendable
    case disconnected(String, UInt16) // ✅ Sendable
    case text(String)                 // ✅ Sendable
    case binary(Data)                 // ✅ Sendable
    case pong(Data?)                  // ✅ Sendable
    case ping(Data?)                  // ✅ Sendable
    case error(Error?)                // ❌ Error 不是 Sendable！
    case viabilityChanged(Bool)       // ✅ Sendable
    case reconnectSuggested(Bool)     // ✅ Sendable
    case cancelled                    // ✅ Sendable
    case peerClosed                   // ✅ Sendable
}
```

### 问题：`.error(Error?)` 中的 `Error` 不符合 `Sendable`

**解决方案 1**：`@unchecked Sendable`（最简单）

```swift
public enum WebSocketEvent: @unchecked Sendable {
    // ...
    case error(Error?)  // Error 不是 Sendable，但实际使用的都是值类型 Error
}
```

**解决方案 2**：改为 `(any Error & Sendable)?`（Swift 6 推荐）

```swift
public enum WebSocketEvent: Sendable {
    // ...
    case error((any Error & Sendable)?)  // 🔴 API 破坏性变更
}
```

**解决方案 3**：包装为 Sendable 的错误类型

```swift
public struct WebSocketError: Error, Sendable {
    public let underlyingError: (any Error & Sendable)?
    public let message: String
}

public enum WebSocketEvent: Sendable {
    case error(WebSocketError?)
}
```

**推荐**：第一阶段用方案 1（`@unchecked Sendable`），因为 Starscream 实际使用的 Error 类型（`WSError`、`TCPTransportError`、`HTTPUpgradeError`）都是值类型，本身是 Sendable 的。

---

## 七、WSFramer 的队列冲突问题

改造 WSEngine 为单队列后，需要注意 WSFramer 内部也有自己的队列：

```swift
public class WSFramer: Framer {
    private let queue = DispatchQueue(label: "com.vluxe.starscream.wsframer")

    public func add(data: Data) {
        queue.async { [weak self] in   // ← WSFramer 自己的队列
            self?.buffer.append(data)
            // ... 处理帧
            // 回调 delegate：
            s.delegate?.frameProcessed(event: .frame(frame))
            // ↑ 这个回调发生在 WSFramer.queue 上，不是 engineQueue 上！
        }
    }
}
```

**问题**：如果 WSEngine 所有逻辑都在 `engineQueue` 上，但 WSFramer 的回调在 `wsframer.queue` 上到达，就需要在入口处跳回 `engineQueue`（方案 B 的 Step 3 已经处理了这个问题）。

**深层问题**：如果 WSFramer 的 `add(data:)` 本身也被 `engineQueue.async` 调用，那么内部再 `queue.async` 就多了一次不必要的队列跳转。

**优化选项**：

```
选项 A（保守）：保持 WSFramer 的 queue 不变
  engineQueue → framer.add(data:) → wsframer.queue → delegate.frameProcessed()
                                                      → engineQueue.async { handle... }
  缺点：多一次队列跳转，微小的延迟

选项 B（激进）：移除 WSFramer 的 queue，让它完全在 engineQueue 上运行
  engineQueue → framer.add(data:) → 直接处理 → delegate.frameProcessed()
                                                → 直接在 engineQueue 上，无需跳转
  优点：减少延迟，逻辑更清晰
  缺点：需要修改 WSFramer，且 WSFramer 不再是独立线程安全的
```

推荐选项 A（第一阶段），选项 B 留给后续优化。

---

## 八、与 Alamofire 的对比总结

| 维度 | Alamofire | Starscream (推荐方案) |
|------|-----------|---------------------|
| **Sendable 策略** | `@unchecked Sendable` | `@unchecked Sendable` |
| **锁/队列** | `Protected<T>` (os_unfair_lock) + `rootQueue` | `engineQueue` (串行 DispatchQueue) |
| **async API** | 增量提供 `DataTask`、`StreamOf<T>` | 增量提供 `AsyncStream<WebSocketEvent>` |
| **delegate 改造** | 保留，不改 | 保留，不改 |
| **Actor 使用** | 不使用 | 不使用 |
| **Swift 6 兼容** | `@preconcurrency` + `@unchecked Sendable` | 同样策略 |
| **为什么不用 actor** | 大量 URLSession callback + 已有 queue 架构 | 大量 delegate callback + 已有 queue 架构 |

**核心洞察**：Alamofire 和 Starscream 面临的挑战本质相同——**基于 delegate/callback 的网络库，内部已有 GCD 队列架构，完整 actor 化需要重写整个 API surface**。两者都选择了务实路线：`@unchecked Sendable` + 文档化的线程安全保证 + 增量提供 async API。

---

## 九、实施检查清单

### 第一阶段（Swift 6 编译通过）

- [ ] `Package.swift` 升级到 `swift-tools-version:5.9`+，启用 `StrictConcurrency=complete`
- [ ] `WSEngine` 加 `final` + `@unchecked Sendable`
- [ ] 合并 `mutex` + `writeQueue` → 单一 `engineQueue`
- [ ] 所有 delegate 回调入口跳到 `engineQueue`
- [ ] `WebSocket` 加 `@unchecked Sendable`
- [ ] `WebSocketEvent` 加 `@unchecked Sendable`
- [ ] `TCPTransport` 加 `@unchecked Sendable`
- [ ] `WSFramer` 加 `@unchecked Sendable`
- [ ] `Engine` 协议的 completion 参数加 `@Sendable`
- [ ] `WebSocket.onEvent` 闭包类型加 `@Sendable`
- [ ] 验证：`swift build` 无 concurrency 警告
- [ ] 验证：Thread Sanitizer 跑测试无 data race

### 第二阶段（现代 async API）

- [ ] 新建 `WebSocket+Concurrency.swift`
- [ ] 实现 `events() -> AsyncStream<WebSocketEvent>`
- [ ] 实现 `write(string:) async`
- [ ] 实现 `write(data:) async`
- [ ] 可选：`connect() async throws`（等待 `.connected` 或 `.error`）
- [ ] 添加 async API 的单元测试

---

## 附录：关键引用

| 资料 | 说明 |
|------|------|
| [Alamofire Protected.swift](../Alamofire-master/Source/Core/Protected.swift) | `@unchecked Sendable` 线程安全包装器参考 |
| [Alamofire Concurrency.swift](../Alamofire-master/Source/Features/Concurrency.swift) | 增量 async API 参考（`StreamOf<T>`、`DataTask`） |
| [Alamofire Session.swift](../Alamofire-master/Source/Core/Session.swift) | `@unchecked Sendable` + rootQueue 架构参考 |
| [SE-0302 Sendable](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md) | Sendable 协议提案 |
| [SE-0306 Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md) | Actor 提案 |
| [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/migrationguide/) | 官方迁移指南 |
