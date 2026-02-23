# Alamofire 的 SSL Pinning 实现流程

## 问题

Alamofire 的 SSL Pinning（证书锁定）是怎么实现的？

## 整体架构

Alamofire 的 SSL Pinning 采用**策略模式**，围绕三层抽象展开：

```
┌──────────┐        ┌────────────────────┐        ┌────────────────────────────┐
│  Session  │──────▶│ ServerTrustManager  │──────▶│ ServerTrustEvaluating       │
│           │       │ (host → evaluator)  │       │ (具体验证策略)               │
└──────────┘        └────────────────────┘        │                            │
                                                  │ ├─ DefaultTrustEvaluator    │
                                                  │ ├─ PinnedCertificates...    │
                                                  │ ├─ PublicKeysTrust...       │
                                                  │ ├─ RevocationTrust...       │
                                                  │ ├─ CompositeTrust...        │
                                                  │ └─ DisabledTrustEvaluator   │
                                                  └────────────────────────────┘
```

---

## 完整流程（逐步走一遍代码）

### 第 1 步：用户配置 Session 和 ServerTrustManager

```swift
let manager = ServerTrustManager(evaluators: [
    "api.example.com": PinnedCertificatesTrustEvaluator(),  // 证书锁定
    "cdn.example.com": PublicKeysTrustEvaluator(),           // 公钥锁定
])

let session = Session(serverTrustManager: manager)
```

`ServerTrustManager` 是一个 **host → evaluator 的映射表**，不同域名可以使用不同的验证策略。

**文件**: `Source/Features/ServerTrustEvaluation.swift`

```swift
open class ServerTrustManager {
    public let allHostsMustBeEvaluated: Bool  // 是否要求所有 host 都必须有对应的 evaluator
    public let evaluators: [String: any ServerTrustEvaluating]

    open func serverTrustEvaluator(forHost host: String) throws -> (any ServerTrustEvaluating)? {
        guard let evaluator = evaluators[host] else {
            if allHostsMustBeEvaluated {
                throw AFError.serverTrustEvaluationFailed(reason: .noRequiredEvaluator(host: host))
            }
            return nil
        }
        return evaluator
    }
}
```

### 第 2 步：URLSession 收到 TLS Challenge

当 `URLSession` 与服务器进行 TLS 握手时，系统会回调 `URLSessionTaskDelegate`。

**文件**: `Source/Core/SessionDelegate.swift`

```swift
open func urlSession(_ session: URLSession,
                     task: URLSessionTask,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

    let evaluation: ChallengeEvaluation
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
        // ← SSL/TLS 服务器信任验证走这里
        evaluation = attemptServerTrustAuthentication(with: challenge)
    // ...
    }

    completionHandler(evaluation.disposition, evaluation.credential)
}
```

### 第 3 步：从 Challenge 中提取 host 和 SecTrust，查找对应的 Evaluator

**文件**: `Source/Core/SessionDelegate.swift`

```swift
func attemptServerTrustAuthentication(with challenge: URLAuthenticationChallenge) -> ChallengeEvaluation {
    // ① 从 challenge 中提取 host 和 SecTrust
    let host = challenge.protectionSpace.host
    guard let trust = challenge.protectionSpace.serverTrust else {
        return (.performDefaultHandling, nil, nil)
    }

    do {
        // ② 从 ServerTrustManager 中查找该 host 对应的 evaluator
        guard let evaluator = try stateProvider?.serverTrustManager?.serverTrustEvaluator(forHost: host) else {
            return (.performDefaultHandling, nil, nil)  // 没有 evaluator，走系统默认
        }

        // ③ 调用 evaluator 验证
        try evaluator.evaluate(trust, forHost: host)

        // ④ 验证通过，使用该证书的凭证继续连接
        return (.useCredential, URLCredential(trust: trust), nil)
    } catch {
        // ⑤ 验证失败，取消连接
        return (.cancelAuthenticationChallenge, nil, error.asAFError(...))
    }
}
```

### 第 4 步：具体的 Evaluator 执行验证

Alamofire 提供了 6 种内置的 evaluator：

#### 4.1 DefaultTrustEvaluator — 系统默认验证

```swift
public func evaluate(_ trust: SecTrust, forHost host: String) throws {
    if validateHost {
        try trust.af.performValidation(forHost: host)      // 验证域名匹配
    }
    try trust.af.performDefaultValidation(forHost: host)   // 系统默认证书链验证
}
```

只做系统级验证，不做额外锁定。

#### 4.2 PinnedCertificatesTrustEvaluator — 证书锁定（最常用）

```swift
public func evaluate(_ trust: SecTrust, forHost host: String) throws {
    // ① 确保有预埋证书
    guard !certificates.isEmpty else {
        throw AFError.serverTrustEvaluationFailed(reason: .noCertificatesFound)
    }

    // ② 如果允许自签名，把预埋证书设为信任锚点
    if acceptSelfSignedCertificates {
        try trust.af.setAnchorCertificates(certificates)
    }

    // ③ 系统默认验证（证书链）
    if performDefaultValidation {
        try trust.af.performDefaultValidation(forHost: host)
    }

    // ④ 域名验证
    if validateHost {
        try trust.af.performValidation(forHost: host)
    }

    // ⑤ 核心：比对证书数据
    //    把服务器证书链中所有证书的 Data 与预埋证书的 Data 取交集
    //    如果交集为空，说明没有匹配的证书 → 验证失败
    let serverCertificatesData = Set(trust.af.certificateData)
    let pinnedCertificatesData = Set(certificates.af.data)
    let pinnedCertificatesInServerData = !serverCertificatesData.isDisjoint(with: pinnedCertificatesData)
    if !pinnedCertificatesInServerData {
        throw AFError.serverTrustEvaluationFailed(reason: .certificatePinningFailed(...))
    }
}
```

预埋证书默认从 `Bundle.main` 中自动加载所有 `.cer`、`.crt`、`.der` 文件：

```swift
public init(certificates: [SecCertificate] = Bundle.main.af.certificates, ...)
```

#### 4.3 PublicKeysTrustEvaluator — 公钥锁定

```swift
public func evaluate(_ trust: SecTrust, forHost host: String) throws {
    guard !keys.isEmpty else {
        throw AFError.serverTrustEvaluationFailed(reason: .noPublicKeysFound)
    }

    // 系统验证 + 域名验证...

    // 核心：比对公钥而非整个证书
    let pinnedKeysInServerKeys: Bool = {
        for serverPublicKey in trust.af.publicKeys {
            if keys.contains(serverPublicKey) {
                return true
            }
        }
        return false
    }()

    if !pinnedKeysInServerKeys {
        throw AFError.serverTrustEvaluationFailed(reason: .publicKeyPinningFailed(...))
    }
}
```

与证书锁定的区别：只比对公钥，不比对整个证书。这样证书续期时，只要公钥不变就不需要更新 App。

#### 4.4 其他 Evaluator

| Evaluator | 用途 |
|-----------|------|
| `RevocationTrustEvaluator` | 额外检查证书是否被吊销（CRL/OCSP） |
| `CompositeTrustEvaluator` | 组合多个 evaluator，全部通过才算通过 |
| `DisabledTrustEvaluator` | 禁用所有验证（**仅限调试！**） |

---

## 关键设计点

### 1. 策略模式 + 按 Host 分发

```swift
let manager = ServerTrustManager(evaluators: [
    "api.example.com": .pinnedCertificates,     // 证书锁定
    "cdn.example.com": .publicKeys,              // 公钥锁定
    "debug.example.com": DisabledTrustEvaluator() // 禁用验证
])
```

不同域名可以使用完全不同的验证策略，非常灵活。

### 2. allHostsMustBeEvaluated 安全守卫

```swift
public let allHostsMustBeEvaluated: Bool  // 默认 true
```

当设为 `true` 时，如果请求的 host 在 evaluators 中找不到对应的策略，直接抛错。防止开发者遗漏某个域名的配置。

### 3. 基于 URLSession 原生回调

Alamofire 利用 `URLSessionTaskDelegate.didReceive challenge` 这个系统回调来介入 TLS 握手，不需要自己管理底层 TCP 连接。这是与 Starscream 最大的架构区别。

### 4. 证书自动发现

```swift
// 自动从 Bundle.main 加载所有证书文件
public var certificates: [SecCertificate] {
    paths(forResourcesOfTypes: [".cer", ".CER", ".crt", ".CRT", ".der", ".DER"]).compactMap { path in
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) as CFData,
              let cert = SecCertificateCreateWithData(nil, data) else { return nil }
        return cert
    }
}
```

只需把证书文件拖进 Xcode 项目，Alamofire 就能自动找到并使用。

---

## 完整时序图

```
用户              Session          SessionDelegate      ServerTrustManager     Evaluator
 │                  │                   │                     │                   │
 │ session.request()│                   │                     │                   │
 │─────────────────▶│                   │                     │                   │
 │                  │ URLSession 发起请求 │                     │                   │
 │                  │                   │                     │                   │
 │                  │    TLS 握手中...    │                     │                   │
 │                  │                   │                     │                   │
 │                  │ didReceive challenge                     │                   │
 │                  │ (ServerTrust)      │                     │                   │
 │                  │──────────────────▶│                     │                   │
 │                  │                   │                     │                   │
 │                  │                   │ serverTrustEvaluator(forHost: "api.example.com")
 │                  │                   │────────────────────▶│                   │
 │                  │                   │                     │                   │
 │                  │                   │   返回 PinnedCertificatesTrustEvaluator  │
 │                  │                   │◀────────────────────│                   │
 │                  │                   │                     │                   │
 │                  │                   │ evaluator.evaluate(trust, forHost:)     │
 │                  │                   │────────────────────────────────────────▶│
 │                  │                   │                     │                   │
 │                  │                   │                     │  1. 系统默认验证    │
 │                  │                   │                     │  2. 域名验证        │
 │                  │                   │                     │  3. 证书/公钥比对   │
 │                  │                   │                     │                   │
 │                  │                   │                success / throw          │
 │                  │                   │◀───────────────────────────────────────│
 │                  │                   │                     │                   │
 │                  │  .useCredential   │                     │                   │
 │                  │  或 .cancel        │                     │                   │
 │                  │◀─────────────────│                     │                   │
 │                  │                   │                     │                   │
 │                  │  TLS 握手完成/失败  │                     │                   │
```
