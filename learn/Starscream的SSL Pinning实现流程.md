# Starscream 的 SSL Pinning 实现流程

## 问题

Starscream 的 SSL Pinning（证书锁定）是怎么实现的？

## 整体架构

SSL Pinning 涉及 3 层，通过 `CertificatePinning` 协议贯穿：

```
┌──────────┐         ┌──────────┐         ┌─────────────────────┐
│ WebSocket │ ──────▶ │ WSEngine  │ ──────▶ │ TCPTransport /       │
│           │         │           │         │ FoundationTransport  │
└──────────┘         └──────────┘         └──────────┬────────────┘
                                                     │
     certPinner 从用户一路传到 Transport              │ TLS 握手时调用
                                                     ▼
                                           ┌───────────────────┐
                                           │ CertificatePinning │
                                           │ (FoundationSecurity)│
                                           └───────────────────┘
                                             evaluateTrust()
                                             验证证书是否可信
```

---

## 完整流程（逐步走一遍代码）

### 第 1 步：用户创建 WebSocket，传入 certPinner

**文件**: `Sources/Starscream/WebSocket.swift`

```swift
public convenience init(
    request: URLRequest,
    certPinner: CertificatePinning? = FoundationSecurity(),  // 默认使用系统验证
    compressionHandler: CompressionHandler? = nil,
    useCustomEngine: Bool = true
) {
    // iOS 12+ 使用 TCPTransport
    self.init(request: request, engine: WSEngine(
        transport: TCPTransport(),
        certPinner: certPinner,         // ← 传给 WSEngine
        compressionHandler: compressionHandler
    ))
}
```

注意：`certPinner` 默认值是 `FoundationSecurity()`，即默认就启用了系统级 SSL 验证。用户也可以传入自定义实现来做证书锁定。

### 第 2 步：WSEngine 保存 certPinner，连接时传给 Transport

**文件**: `Sources/Engine/WSEngine.swift`

```swift
public init(transport: Transport,
            certPinner: CertificatePinning? = nil, ...) {
    self.certPinner = certPinner   // ← 保存下来
}

public func start(request: URLRequest) {
    // ...
    transport.connect(url: url,
                      timeout: request.timeoutInterval,
                      certificatePinning: certPinner)  // ← 传给 Transport
}
```

WSEngine 自己不做 SSL 验证，只是把 `certPinner` 透传给 Transport 层。

### 第 3 步：Transport 在 TLS 握手时调用 certPinner

这一步根据 Transport 的实现不同，有两条路径：

#### 路径 A：TCPTransport（iOS 12+，基于 Network.framework）

**文件**: `Sources/Transport/TCPTransport.swift`

```swift
public func connect(url: URL, timeout: Double = 10, certificatePinning: CertificatePinning? = nil) {
    // ...
    let tlsOptions = isTLS ? NWProtocolTLS.Options() : nil
    if let tlsOpts = tlsOptions {
        // ① 在 TLS 选项上设置验证回调
        sec_protocol_options_set_verify_block(
            tlsOpts.securityProtocolOptions,
            { (sec_protocol_metadata, sec_trust, sec_protocol_verify_complete) in

                // ② 从 sec_trust 中提取 SecTrust 对象
                let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()

                // ③ 如果没有 pinner，直接放行
                guard let pinner = certificatePinning else {
                    sec_protocol_verify_complete(true)
                    return
                }

                // ④ 调用 pinner 验证证书
                pinner.evaluateTrust(trust: trust, domain: parts.host, completion: { (state) in
                    switch state {
                    case .success:
                        sec_protocol_verify_complete(true)   // 验证通过，继续连接
                    case .failed(_):
                        sec_protocol_verify_complete(false)  // 验证失败，断开连接
                    }
                })
            }, queue)
    }
    // ⑤ 用配置好的 TLS 参数创建连接
    let parameters = NWParameters(tls: tlsOptions, tcp: options)
    let conn = NWConnection(host: ..., port: ..., using: parameters)
}
```

**关键点**：`sec_protocol_options_set_verify_block` 是 Network.framework 提供的 API，它允许在 TLS 握手过程中插入自定义的证书验证逻辑。这个 block 会在 TLS 握手的"验证服务器证书"阶段被系统自动调用。

#### 路径 B：FoundationTransport（iOS 12 以下，基于 Stream）

**文件**: `Sources/Transport/FoundationTransport.swift`

```swift
open func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case .openCompleted:
        if aStream == inputStream {
            // ① Stream 打开完成，从 outputStream 中提取 SSL 信息
            let (trust, domain) = getSecurityData()

            // ② 如果有 pinner 且有 trust，进行验证
            if let pinner = certPinner, let trust = trust {
                pinner.evaluateTrust(trust: trust, domain: domain, completion: { [weak self] (state) in
                    switch state {
                    case .success:
                        self?.isOpen = true
                        self?.delegate?.connectionChanged(state: .connected)  // 验证通过
                    case .failed(let error):
                        self?.delegate?.connectionChanged(state: .failed(error))  // 验证失败
                    }
                })
            } else {
                // 没有 pinner，直接认为连接成功
                isOpen = true
                delegate?.connectionChanged(state: .connected)
            }
        }
    }
}
```

**`getSecurityData()` 做了什么？** 从已建立的 SSL Stream 中提取两样东西：

```swift
private func getSecurityData() -> (SecTrust?, String?) {
    // 从 outputStream 获取服务器的证书链（SecTrust）
    let trust = outputStream.property(forKey: kCFStreamPropertySSLPeerTrust) as! SecTrust?

    // 获取服务器的域名
    var domain = outputStream.property(forKey: kCFStreamSSLPeerName) as! String?

    // 如果域名为空，尝试从 SSLContext 中获取
    if domain == nil, let sslContextOut = ... {
        SSLGetPeerDomainName(sslContextOut, ...)
    }
    return (trust, domain)
}
```

### 第 4 步：FoundationSecurity 执行实际的证书验证

**文件**: `Sources/Security/FoundationSecurity.swift`

无论是哪条路径，最终都调用到 `CertificatePinning.evaluateTrust()`。默认实现 `FoundationSecurity` 的逻辑如下：

```swift
extension FoundationSecurity: CertificatePinning {
    public func evaluateTrust(trust: SecTrust, domain: String?, completion: ((PinningState) -> ())) {
        // ① 如果允许自签名证书，直接通过
        if allowSelfSigned {
            completion(.success)
            return
        }

        // ② 设置 SSL 验证策略（包含域名校验）
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as NSString?))

        // ③ 执行证书链验证
        handleSecurityTrust(trust: trust, completion: completion)
    }
}
```

证书链验证分两个版本：

```swift
// iOS 12+ / macOS 10.14+：新 API
private func handleSecurityTrust(trust: SecTrust, completion: ((PinningState) -> ())) {
    var error: CFError?
    if SecTrustEvaluateWithError(trust, &error) {
        completion(.success)     // 证书链有效
    } else {
        completion(.failed(error))  // 证书链无效
    }
}

// 更老的系统：旧 API
private func handleOldSecurityTrust(trust: SecTrust, completion: ((PinningState) -> ())) {
    var result: SecTrustResultType = .unspecified
    SecTrustEvaluate(trust, &result)
    if result == .unspecified || result == .proceed {
        completion(.success)
    } else {
        completion(.failed(...))
    }
}
```

---

## 协议设计

### CertificatePinning 协议

**文件**: `Sources/Security/Security.swift`

```swift
public protocol CertificatePinning: AnyObject {
    func evaluateTrust(trust: SecTrust, domain: String?, completion: ((PinningState) -> ()))
}

public enum PinningState {
    case success
    case failed(CFError?)
}
```

这个协议只有一个方法，接收三个参数：

| 参数 | 含义 |
|------|------|
| `trust: SecTrust` | 服务器的证书链，由系统在 TLS 握手时提供 |
| `domain: String?` | 服务器域名，用于验证证书是否属于该域名 |
| `completion` | 验证结果回调：`.success` 或 `.failed` |

### 为什么设计成协议？

用户可以提供自定义实现来做真正的"证书锁定"（将服务器证书与预埋在 App 中的证书比对），而不仅仅是系统默认的证书链验证。例如：

```swift
class MyCertPinning: CertificatePinning {
    func evaluateTrust(trust: SecTrust, domain: String?, completion: ((PinningState) -> ())) {
        // 取出服务器证书
        let serverCert = SecTrustGetCertificateAtIndex(trust, 0)
        // 与预埋证书比对
        if serverCert == myPinnedCert {
            completion(.success)
        } else {
            completion(.failed(nil))
        }
    }
}

let socket = WebSocket(request: request, certPinner: MyCertPinning())
```

---

## 两条路径的对比

| | TCPTransport (iOS 12+) | FoundationTransport (旧版) |
|---|---|---|
| **底层** | Network.framework `NWConnection` | `CFStream` / `InputStream` + `OutputStream` |
| **验证时机** | TLS 握手过程中（`sec_protocol_options_set_verify_block`） | Stream `.openCompleted` 事件后 |
| **验证方式** | 系统回调 verify block，在 block 中调用 pinner | 手动从 Stream 提取 `SecTrust`，再调用 pinner |
| **失败行为** | `sec_protocol_verify_complete(false)` → 连接不会建立 | `connectionChanged(.failed)` → WSEngine 收到错误 |

**关键区别**：TCPTransport 的验证发生在连接建立**之前**（TLS 握手阶段），而 FoundationTransport 的验证发生在连接建立**之后**（Stream 已 open，再检查证书）。

---

## 完整时序图

```
用户                WebSocket       WSEngine        TCPTransport        系统 TLS         FoundationSecurity
 │                    │               │                │                   │                    │
 │ socket.connect()   │               │                │                   │                    │
 │──────────────────▶│               │                │                   │                    │
 │                    │ engine.start() │                │                   │                    │
 │                    │──────────────▶│                │                   │                    │
 │                    │               │ transport.connect(certPinner)       │                    │
 │                    │               │───────────────▶│                   │                    │
 │                    │               │                │ NWConnection.start │                    │
 │                    │               │                │──────────────────▶│                    │
 │                    │               │                │                   │                    │
 │                    │               │                │    TLS 握手中...    │                    │
 │                    │               │                │    verify block 被调用                   │
 │                    │               │                │                   │                    │
 │                    │               │                │ pinner.evaluateTrust(trust, domain)     │
 │                    │               │                │───────────────────────────────────────▶│
 │                    │               │                │                   │                    │
 │                    │               │                │                   │    SecTrustEvaluate │
 │                    │               │                │                   │    验证证书链        │
 │                    │               │                │                   │                    │
 │                    │               │                │                .success                 │
 │                    │               │                │◀───────────────────────────────────────│
 │                    │               │                │                   │                    │
 │                    │               │                │ sec_protocol_verify_complete(true)      │
 │                    │               │                │──────────────────▶│                    │
 │                    │               │                │                   │                    │
 │                    │               │                │  TLS 握手完成，连接就绪                   │
 │                    │               │  .connected    │                   │                    │
 │                    │               │◀──────────────│                   │                    │
 │                    │               │                │                   │                    │
 │                    │               │ 开始 HTTP Upgrade 握手...                                │
```

---

## 与 Alamofire SSL Pinning 的对比

> 详细的 Alamofire SSL Pinning 流程见 [Alamofire的SSL Pinning实现流程.md](./Alamofire的SSL%20Pinning实现流程.md)

### 架构层面

```
Starscream:
  用户 → WebSocket → WSEngine → TCPTransport ──┐
                                                ├── CertificatePinning.evaluateTrust()
  用户 → WebSocket → WSEngine → FoundationTransport ──┘
  （自己管理 TCP 连接，自己拦截 TLS 握手）

Alamofire:
  用户 → Session → URLSession ──── 系统 TLS ──── URLSessionDelegate.didReceive challenge
                                                        │
                                    ServerTrustManager.serverTrustEvaluator(forHost:)
                                                        │
                                              ServerTrustEvaluating.evaluate()
  （基于 URLSession，利用系统回调介入 TLS 握手）
```

### 逐项对比

| 维度 | Starscream | Alamofire |
|------|-----------|-----------|
| **网络层** | 自建 TCP（NWConnection / CFStream） | 基于 URLSession |
| **TLS 介入方式** | `sec_protocol_options_set_verify_block` 或 Stream `.openCompleted` 后手动验证 | `URLSessionTaskDelegate.didReceive challenge` 系统回调 |
| **验证协议** | `CertificatePinning`（1 个方法） | `ServerTrustEvaluating`（1 个方法） |
| **协议签名** | `evaluateTrust(trust:domain:completion:)` — 异步，通过 completion 回调 | `evaluate(_:forHost:) throws` — 同步，通过 throw 报错 |
| **按 Host 分发** | ❌ 不支持，全局一个 pinner | ✅ `ServerTrustManager` 维护 host → evaluator 映射 |
| **内置策略数量** | 1 个（`FoundationSecurity`，仅系统默认验证） | 6 个（Default / PinnedCertificates / PublicKeys / Revocation / Composite / Disabled） |
| **证书锁定** | 需用户自己实现 `CertificatePinning` 协议 | 内置 `PinnedCertificatesTrustEvaluator`，自动从 Bundle 加载证书 |
| **公钥锁定** | 需用户自己实现 | 内置 `PublicKeysTrustEvaluator`，自动从 Bundle 提取公钥 |
| **自签名证书** | `FoundationSecurity(allowSelfSigned: true)` — 跳过所有验证 | `PinnedCertificatesTrustEvaluator(acceptSelfSignedCertificates: true)` — 将预埋证书设为锚点，仍执行链验证 |
| **安全守卫** | 无 | `allHostsMustBeEvaluated`：未配置的 host 直接报错 |
| **Sendable / 并发安全** | 未适配 Swift Concurrency | `ServerTrustEvaluating: Sendable`，`ServerTrustManager: @unchecked Sendable` |

### 核心差异解读

#### 1. 同步 vs 异步

```swift
// Starscream — 异步 completion
func evaluateTrust(trust: SecTrust, domain: String?, completion: ((PinningState) -> ()))

// Alamofire — 同步 throws
func evaluate(_ trust: SecTrust, forHost host: String) throws
```

Starscream 使用异步回调是因为它需要在 `sec_protocol_options_set_verify_block` 中调用 `sec_protocol_verify_complete`，这本身就是异步流程。

Alamofire 使用同步 throws 是因为 `URLSessionDelegate.didReceive challenge` 的 completionHandler 可以在任意时机调用，所以内部验证可以是同步的。

#### 2. 开箱即用 vs 自己动手

Starscream 的 `FoundationSecurity` 只做系统默认的证书链验证，不做真正的"锁定"。如果要做证书锁定或公钥锁定，用户必须自己实现 `CertificatePinning` 协议：

```swift
// Starscream：用户自己实现证书锁定
class MyCertPinning: CertificatePinning {
    func evaluateTrust(trust: SecTrust, domain: String?, completion: ((PinningState) -> ())) {
        let serverCert = SecTrustGetCertificateAtIndex(trust, 0)
        if serverCert == myPinnedCert {
            completion(.success)
        } else {
            completion(.failed(nil))
        }
    }
}
```

Alamofire 则开箱即用，只需把证书文件放进项目：

```swift
// Alamofire：一行配置搞定
let manager = ServerTrustManager(evaluators: [
    "api.example.com": PinnedCertificatesTrustEvaluator()
    // 自动从 Bundle.main 加载 .cer/.crt/.der 文件
])
```

#### 3. 职责定位不同

这是设计取舍，不是优劣之分：

- **Starscream** 是一个 WebSocket 库，SSL Pinning 只是附带功能。它提供协议扩展点，让用户按需实现，保持库本身轻量。
- **Alamofire** 是一个全功能 HTTP 库，SSL Pinning 是核心安全特性。它提供完整的策略体系，覆盖各种生产场景。
