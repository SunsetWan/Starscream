# Starscream 架构总览

## 目录结构

```
Sources/
├── Starscream/          # API 层 — 用户直接使用的入口
│   └── WebSocket.swift          # WebSocket 类、WebSocketClient 协议、WebSocketEvent 枚举
│
├── Engine/              # 引擎层 — 驱动 WebSocket 生命周期
│   ├── Engine.swift             # Engine 协议定义
│   ├── WSEngine.swift           # 自定义引擎：完整 RFC 6455 实现，组合 Transport/Framer/Security/Compression
│   └── NativeEngine.swift       # 原生引擎：封装 URLSessionWebSocketTask (iOS 13+/macOS 10.15+)
│
├── Transport/           # 传输层 — 底层 TCP 连接
│   ├── Transport.swift          # Transport 协议、ConnectionState 枚举
│   ├── TCPTransport.swift       # 基于 Network.framework (iOS 12+/macOS 10.14+)
│   └── FoundationTransport.swift # 基于 Stream（兼容旧版系统）
│
├── Framer/              # 帧处理层 — WebSocket 帧的解析与构造
│   ├── Framer.swift             # Framer 协议、WSFramer 实现、Frame 结构体、CloseCode/FrameOpCode 枚举
│   ├── FrameCollector.swift     # 分片帧重组、UTF-8 校验
│   ├── HTTPHandler.swift        # HTTPHandler 协议、HTTPWSHeader（构造升级请求）
│   ├── FoundationHTTPHandler.swift      # HTTPHandler 的 Foundation 实现
│   ├── FoundationHTTPServerHandler.swift # 服务端 HTTP 处理
│   └── StringHTTPHandler.swift          # 字符串方式的 HTTP 解析
│
├── Security/            # 安全层 — SSL Pinning 与握手校验
│   ├── Security.swift           # CertificatePinning、HeaderValidator 协议
│   └── FoundationSecurity.swift # 基于 SecTrust 的实现，校验 Sec-WebSocket-Accept
│
├── Compression/         # 压缩层 — permessage-deflate (RFC 7692)
│   ├── Compression.swift        # CompressionHandler 协议
│   └── WSCompression.swift      # zlib 压缩/解压实现
│
├── Server/              # 服务端（辅助/测试用）
│   ├── Server.swift             # Server 协议、Connection 协议、ServerEvent 枚举
│   └── WebSocketServer.swift    # 简易 WebSocket 服务端实现
│
└── DataBytes/           # 工具
    └── Data+Extensions.swift    # Data 字节操作扩展
```

## 分层架构图

```
┌─────────────────────────────────────────────────────┐
│                    用户代码                           │
│         WebSocket / WebSocketDelegate                │
└──────────────────────┬──────────────────────────────┘
                       │ Engine 协议
          ┌────────────┴────────────┐
          ▼                         ▼
   ┌─────────────┐          ┌──────────────┐
   │  WSEngine   │          │ NativeEngine │
   │ (自定义实现) │          │ (系统 API)    │
   └──┬──┬──┬──┬─┘          └──────────────┘
      │  │  │  │
      │  │  │  └──► Compression (压缩/解压)
      │  │  └─────► Security (SSL Pinning + Accept 校验)
      │  └────────► Framer → FrameCollector (帧解析 → 分片重组)
      └───────────► Transport (TCP 连接)
                       │
              ┌────────┴────────┐
              ▼                 ▼
        TCPTransport    FoundationTransport
      (Network.framework)    (Stream)
```

## 模块职责说明

| 模块 | 核心职责 | 关键协议/类 |
|------|---------|------------|
| **Starscream** | 面向用户的 API，分发回调事件到指定队列 | `WebSocket`, `WebSocketClient`, `WebSocketDelegate`, `WebSocketEvent` |
| **Engine** | 编排整个 WebSocket 生命周期（握手→通信→关闭） | `Engine` 协议, `WSEngine`, `NativeEngine` |
| **Transport** | 管理底层 TCP 连接的建立、读写、断开 | `Transport` 协议, `TCPTransport`, `FoundationTransport` |
| **Framer** | 按 RFC 6455 解析/构造 WebSocket 帧，处理 HTTP 升级握手 | `Framer` 协议, `WSFramer`, `FrameCollector`, `HTTPHandler` |
| **Security** | SSL 证书验证、Sec-WebSocket-Accept 头校验 | `CertificatePinning`, `HeaderValidator`, `FoundationSecurity` |
| **Compression** | permessage-deflate 扩展的压缩与解压 | `CompressionHandler`, `WSCompression` |
| **Server** | 简易 WebSocket 服务端（用于测试） | `Server`, `WebSocketServer` |
| **DataBytes** | Data 字节操作工具方法 | `Data+Extensions` |

## 核心设计特点

1. **面向协议设计（POP）**：每一层都通过协议（`Engine`, `Transport`, `Framer`, `CertificatePinning`, `CompressionHandler`）定义接口，实现可替换。

2. **双引擎策略**：`WSEngine` 提供完整的自定义 RFC 6455 实现；`NativeEngine` 封装系统的 `URLSessionWebSocketTask`。在 `WebSocket.init` 中根据系统版本和 `useCustomEngine` 参数自动选择。

3. **WSEngine 是组合中心**：它实现了 `TransportEventClient`、`FramerEventClient`、`FrameCollectorDelegate`、`HTTPHandlerDelegate` 四个回调协议，将 Transport → HTTP 握手 → 帧解析 → 分片重组 → 压缩/解压 的完整流程串联起来。

4. **传输层适配**：`TCPTransport`（基于 Network.framework）用于 iOS 12+；`FoundationTransport`（基于 Stream）兼容更早的系统。
