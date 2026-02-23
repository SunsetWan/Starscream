# SSL Pinning API 现代化调研

> 目标：将最低部署目标提升至 iOS 18+，清理过时 API，替换为现代等价物。

## 调研结论总览

| 文件 | 过时 API | 状态 | 替换方案 |
|------|---------|------|---------|
| `FoundationSecurity.swift` | `SecTrustEvaluate` | ⛔ **iOS 13.0 已废弃** | 移除，直接用 `SecTrustEvaluateWithError` |
| `FoundationSecurity.swift` | `#available` 分支检查 | 🟡 **死代码** | iOS 18+ 永远走新分支，移除旧分支 |
| `FoundationSecurity.swift` | `CC_SHA1`（CommonCrypto） | 🟡 **可替换** | 改用 `CryptoKit` 的 `Insecure.SHA1` |
| `TCPTransport.swift` | `@available(macOS 10.14, iOS 12.0, ...)` | 🟡 **多余** | iOS 18+ 永远可用，移除注解 |
| `TCPTransport.swift` | `#else typealias TCPTransport = FoundationTransport` | 🟡 **死代码** | iOS 18+ Network.framework 永远可用，移除 fallback |
| `TCPTransport.swift` | `sec_protocol_options_set_verify_block` | ✅ **仍为当前 API** | 无需替换 |
| `TCPTransport.swift` | `sec_trust_copy_ref` | ✅ **仍为当前 API** | 无需替换 |
| `FoundationSecurity.swift` | `SecTrustSetPolicies` | ✅ **仍为当前 API** | 无需替换 |
| `FoundationSecurity.swift` | `SecPolicyCreateSSL` | ✅ **仍为当前 API** | 无需替换 |
| `WebSocket.swift` | `#available` 三段式分支 | 🟡 **可简化** | iOS 18+ `FoundationTransport` 分支是死代码 |

---

## 逐文件详细分析

### 1. FoundationSecurity.swift

#### 1.1 `SecTrustEvaluate` — ⛔ iOS 13.0 已废弃

**当前代码（`handleOldSecurityTrust` 方法）：**

```swift
// ⛔ SecTrustEvaluate 在 iOS 13.0 已废弃
private func handleOldSecurityTrust(trust: SecTrust, completion: ((PinningState) -> ())) {
    var result: SecTrustResultType = .unspecified
    SecTrustEvaluate(trust, &result)  // ← 已废弃
    if result == .unspecified || result == .proceed {
        completion(.success)
    } else {
        let e = CFErrorCreate(kCFAllocatorDefault, "FoundationSecurityError" as NSString?, Int(result.rawValue), nil)
        completion(.failed(e))
    }
}
```

**当前的 `handleSecurityTrust` 方法有不必要的 `#available` 分支：**

```swift
private func handleSecurityTrust(trust: SecTrust, completion: ((PinningState) -> ())) {
    if #available(iOS 12.0, OSX 10.14, watchOS 5.0, tvOS 12.0, *) {
        // iOS 18+ 永远走这里
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completion(.success)
        } else {
            completion(.failed(error))
        }
    } else {
        // ← iOS 18+ 永远不会走到这里，死代码
        handleOldSecurityTrust(trust: trust, completion: completion)
    }
}
```

**Apple 文档确认**（来源：[Apple Developer Documentation](https://developer.apple.com/documentation/security/sectrustevaluatewitherror(_:_:))）：

> `SecTrustEvaluate` — Deprecated in iOS 13.0. Use `SecTrustEvaluateWithError(_:_:)` instead.

**建议改为：**

```swift
private func handleSecurityTrust(trust: SecTrust, completion: ((PinningState) -> ())) {
    var error: CFError?
    if SecTrustEvaluateWithError(trust, &error) {
        completion(.success)
    } else {
        completion(.failed(error))
    }
}
```

同时删除 `handleOldSecurityTrust` 方法。

#### 1.2 `CC_SHA1`（CommonCrypto）— 🟡 可替换为 CryptoKit

**当前代码：**

```swift
import CommonCrypto

private extension String {
    func sha1Base64() -> String {
        let data = self.data(using: .utf8)!
        let pointer = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt8] in
            var digest = [UInt8](repeating: 0, count:Int(CC_SHA1_DIGEST_LENGTH))
            CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
            return digest
        }
        return Data(pointer).base64EncodedString()
    }
}
```

**建议改为（使用 CryptoKit）：**

```swift
import CryptoKit

private extension String {
    func sha1Base64() -> String {
        let data = Data(self.utf8)
        let digest = Insecure.SHA1.hash(data: data)
        return Data(digest).base64EncodedString()
    }
}
```

**变化：**
- 移除 `import CommonCrypto`，改用 `import CryptoKit`
- 不再需要 `UnsafeRawBufferPointer` 手动操作内存
- `Insecure.SHA1` 是 CryptoKit 提供的 API（iOS 13.0+），用 `Insecure` 前缀标记它不适合安全用途
- 此处 SHA1 是 RFC 6455 WebSocket 握手协议要求的，不可替换为 SHA256，因此使用 `Insecure.SHA1` 是合理的

### 2. TCPTransport.swift

#### 2.1 `@available` 注解和 `FoundationTransport` fallback — 🟡 死代码

**当前代码：**

```swift
#if canImport(Network)
// ...
@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
public class TCPTransport: Transport {
    // ...
}
#else
typealias TCPTransport = FoundationTransport
#endif
```

**iOS 18+ 的情况：**
- `Network.framework` 从 iOS 12 开始可用，iOS 18+ 永远可以 `import Network`
- `#else` 分支永远不会编译
- `@available` 注解永远满足

**建议改为：**

```swift
import Foundation
import Network

public class TCPTransport: Transport {
    // ... (移除 @available 注解)
}
// 删除 #if canImport(Network) / #else / #endif
// 删除 typealias TCPTransport = FoundationTransport
```

#### 2.2 `sec_protocol_options_set_verify_block` — ✅ 仍为当前 API

**Apple 文档确认**（来源：[Apple Developer Documentation](https://developer.apple.com/documentation/security/sec_protocol_options_set_verify_block(_:_:_:))）：

> `sec_protocol_options_set_verify_block(_:_:_:)` — iOS 12.0+，**未标记废弃**。

这仍然是 `NWConnection` 自定义 TLS 验证的标准方式。Apple 自己的文档（[Creating an Identity for Local Network TLS](https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls)）和 Developer Forums 中 Apple 工程师（Quinn "The Eskimo!"）的回答都在使用此 API，**无需替换**。

#### 2.3 `SecTrustSetPolicies` / `SecPolicyCreateSSL` — ✅ 仍为当前 API

这两个 API 均未被废弃，是 Security framework 中证书验证的标准 API，**无需替换**。

### 3. WebSocket.swift

#### 3.1 三段式 `#available` 分支 — 🟡 可简化

**当前代码：**

```swift
public convenience init(
    request: URLRequest,
    certPinner: CertificatePinning? = FoundationSecurity(),
    compressionHandler: CompressionHandler? = nil,
    useCustomEngine: Bool = true
) {
    if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *), !useCustomEngine {
        self.init(request: request, engine: NativeEngine())
    } else if #available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *) {
        self.init(request: request, engine: WSEngine(transport: TCPTransport(), certPinner: certPinner, compressionHandler: compressionHandler))
    } else {
        // ← iOS 18+ 永远不会走到这里
        self.init(request: request, engine: WSEngine(transport: FoundationTransport(), certPinner: certPinner, compressionHandler: compressionHandler))
    }
}
```

**建议改为：**

```swift
public convenience init(
    request: URLRequest,
    certPinner: CertificatePinning? = FoundationSecurity(),
    compressionHandler: CompressionHandler? = nil,
    useCustomEngine: Bool = true
) {
    if !useCustomEngine {
        self.init(request: request, engine: NativeEngine())
    } else {
        self.init(request: request, engine: WSEngine(transport: TCPTransport(), certPinner: certPinner, compressionHandler: compressionHandler))
    }
}
```

---

## 可删除的文件/代码

如果最低支持 iOS 18+，以下代码变为死代码，可考虑删除：

| 文件/代码 | 原因 |
|----------|------|
| `Sources/Transport/FoundationTransport.swift` | 基于 `CFStream` 的旧 Transport，iOS 12+ 已用 `TCPTransport` (NWConnection) 替代 |
| `FoundationSecurity.handleOldSecurityTrust()` | 使用已废弃的 `SecTrustEvaluate`，iOS 12+ 不再需要 |
| `import CommonCrypto` | 可用 `CryptoKit` 完全替代 |

---

## 不需要替换的 API 汇总

| API | 状态 | 说明 |
|-----|------|------|
| `SecTrustEvaluateWithError` | ✅ 当前 API | iOS 12.0+，未废弃，是 `SecTrustEvaluate` 的正式替代 |
| `SecPolicyCreateSSL` | ✅ 当前 API | iOS 2.0+，未废弃 |
| `SecTrustSetPolicies` | ✅ 当前 API | 未废弃 |
| `sec_protocol_options_set_verify_block` | ✅ 当前 API | iOS 12.0+，未废弃，仍是 NWConnection TLS 验证的标准方式 |
| `sec_trust_copy_ref` | ✅ 当前 API | 未废弃 |
| `NWConnection` / `NWProtocolTLS.Options` | ✅ 当前 API | Network.framework，iOS 12.0+ |

---

## 重构清单（按优先级排序）

| # | 改动 | 文件 | 优先级 | 原因 |
|---|------|------|--------|------|
| 1 | 删除 `handleOldSecurityTrust()` 方法 | `FoundationSecurity.swift` | 🔴 高 | 使用已废弃 API，编译器产生警告 |
| 2 | 移除 `handleSecurityTrust` 中的 `#available` 分支 | `FoundationSecurity.swift` | 🔴 高 | 死代码 |
| 3 | `CC_SHA1` → `CryptoKit Insecure.SHA1` | `FoundationSecurity.swift` | 🟡 中 | 现代化，消除 unsafe 内存操作 |
| 4 | 移除 `TCPTransport` 的 `@available` 注解 | `TCPTransport.swift` | 🟡 中 | 多余注解 |
| 5 | 移除 `#if canImport(Network)` / `#else` fallback | `TCPTransport.swift` | 🟡 中 | 死代码 |
| 6 | 简化 `WebSocket` convenience init 的分支 | `WebSocket.swift` | 🟡 中 | 死代码分支 |
| 7 | 考虑删除 `FoundationTransport.swift` | `Sources/Transport/` | 🟢 低 | 整个文件变为死代码，但可能有外部使用者 |
