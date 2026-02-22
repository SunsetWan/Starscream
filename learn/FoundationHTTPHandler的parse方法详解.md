# FoundationHTTPHandler 的 parse 方法详解

## 问题

`FoundationHTTPHandler.parse(data:) -> Int` 在干什么？返回值是什么意思？

## 核心问题

TCP 是字节流，一次 `receive` 拿到的数据可能包含 **HTTP 响应 + 紧随其后的 WebSocket 帧数据**，粘在一起。`parse` 需要把 HTTP 部分吃掉，并告诉调用方"HTTP 到哪里结束了"。

```
TCP 一次收到的 data:
┌──────────────────────────┬─────────────────────┐
│  HTTP/1.1 101 ...\r\n\r\n │  WebSocket 帧数据     │
└──────────────────────────┴─────────────────────┘
│◄──── 0 ~ offset ────────►│◄── offset ~ end ──►│
        ↓                            ↓
   parse 自己消化               返回 offset
   → 回调 .success(headers)     → 调用方送给 framer
```

## 逐行拆解

```swift
public func parse(data: Data) -> Int {
    // ① 找 HTTP 头的结束标记 "\r\n\r\n"
    //    找到 → offset = 结束位置（正数）
    //    没找到 → offset = -1
    let offset = findEndOfHTTP(data: data)

    // ② 把数据存入 buffer（可能需要多次 TCP receive 才能凑齐完整的 HTTP 响应）
    if offset > 0 {
        // 找到了边界，只取 HTTP 部分（不含后面的 WebSocket 帧数据）
        buffer.append(data.subdata(in: 0..<offset))
    } else {
        // 还没收全 HTTP 头，整段都是 HTTP 数据，全部存入
        buffer.append(data)
    }

    // ③ 尝试用 CFHTTPMessage 解析完整的 HTTP 响应
    //    成功 → 清空 buffer，回调 delegate
    //    失败 → 保留 buffer，等下次数据到来再拼
    if parseContent(data: buffer) {
        buffer = Data()
    }

    // ④ 返回 offset（HTTP 结束位置）给调用方
    //    调用方用它来截取 HTTP 后面的"多余数据"，送给 WSFramer 解析
    return offset
}
```

## 调用方怎么用返回值

在 WSEngine.swift 中：

```swift
case .receive(let data):
    if didUpgrade {
        framer.add(data: data)
    } else {
        let offset = httpHandler.parse(data: data)
        if offset > 0 {
            // HTTP 响应在 offset 处结束，后面的是 WebSocket 帧数据
            let extraData = data.subdata(in: offset..<data.endIndex)
            framer.add(data: extraData)  // 直接送去解帧
        }
    }
```

## 为什么需要 buffer？

因为 HTTP 响应可能分多次 TCP receive 才收全。第一次收到时 `findEndOfHTTP` 返回 -1（没找到 `\r\n\r\n`），数据暂存 buffer；下次再收到数据时拼接后再尝试解析。

### 场景一：HTTP 响应一次收全

```
第 1 次 receive: [HTTP/1.1 101 ...\r\n\r\n][WebSocket帧]
                                           ↑ offset
→ findEndOfHTTP 返回 offset（正数）
→ buffer 只存 HTTP 部分，parseContent 解析成功
→ 返回 offset，调用方把后面的 WebSocket 帧送给 framer
```

## findEndOfHTTP 如何找到 HTTP 头的结束位置

HTTP 响应头以 `\r\n\r\n`（即 `0x0D 0x0A 0x0D 0x0A`）结尾，这是 HTTP 协议规定的头部与 body 之间的分隔符。`findEndOfHTTP` 的任务就是在字节流中找到这 4 个连续字节。

### 前三行：准备工作

```swift
let endBytes = [UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\n")]
var pointer = [UInt8]()
data.withUnsafeBytes { pointer.append(contentsOf: $0) }
```

1. **`let endBytes = [...]`** — 定义要搜索的目标模式。`UInt8(ascii: "\r")` 就是 `0x0D`（回车），`UInt8(ascii: "\n")` 就是 `0x0A`（换行）。把 `\r\n\r\n` 拆成 4 个 `UInt8` 放在数组里，后面逐个比对。

2. **`var pointer = [UInt8]()`** — 创建一个空的 `UInt8` 数组，用来存放 `Data` 的字节内容。

3. **`data.withUnsafeBytes { pointer.append(contentsOf: $0) }`** — 把 `Data` 转换成 `[UInt8]` 数组。`Data` 本身不能直接用下标按字节访问（至少不如数组方便），所以通过 `withUnsafeBytes` 拿到底层的 `UnsafeRawBufferPointer`，再拷贝到 `[UInt8]` 数组里，之后就可以用 `pointer[i]` 逐字节访问了。

简单说，这三行就是：**定义"要找什么" + 把 Data 转成方便逐字节遍历的 `[UInt8]` 数组**。

### 完整源码（带注释）

```swift
private func findEndOfHTTP(data: Data) -> Int {
    let endBytes = [UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\n")]
    var pointer = [UInt8]()
    data.withUnsafeBytes { pointer.append(contentsOf: $0) }
    var k = 0
    for i in 0..<data.count {
        if pointer[i] == endBytes[k] {
            k += 1          // 当前字节匹配，推进到下一个待匹配字节
            if k == 4 {
                return i + 1 // 4 个字节全部匹配，返回 \r\n\r\n 之后的位置
            }
        } else {
            k = 0            // 不匹配，重置，从头开始找
        }
    }
    return -1                // 没找到，说明 HTTP 头还没收完
}
```

### 算法逐步演示

用变量 `k` 作为"已经连续匹配了几个字节"的计数器：

```
待匹配模式: endBytes = [\r, \n, \r, \n]
                        k=0  k=1  k=2  k=3

示例数据（简化）:
  H  T  T  P  .  .  .  \r  \n  \r  \n  [WebSocket帧...]
  ↑                      ↑   ↑   ↑   ↑
  i=0 k=0 不匹配         i=7 i=8 i=9 i=10
       k 一直是 0          k=1 k=2 k=3 k=4 → 命中！返回 i+1 = 11
```

逐步过程：

| i | pointer[i] | endBytes[k] | 匹配？ | k 变化 | 说明 |
|---|-----------|-------------|--------|--------|------|
| 0 | `H` | `\r` (k=0) | ❌ | k=0 | 不匹配，重置 |
| ... | 普通字符 | `\r` (k=0) | ❌ | k=0 | 一直不匹配 |
| 7 | `\r` | `\r` (k=0) | ✅ | k=1 | 第 1 个匹配 |
| 8 | `\n` | `\n` (k=1) | ✅ | k=2 | 第 2 个匹配 |
| 9 | `\r` | `\r` (k=2) | ✅ | k=3 | 第 3 个匹配 |
| 10 | `\n` | `\n` (k=3) | ✅ | k=4 | 全部匹配！返回 11 |

### 返回值的含义

```
数据:  [H T T P / 1 . 1   1 0 1 \r \n \r \n 0x81 0x05 ...]
索引:   0 1 2 ...                          10     11
                                            ↑      ↑
                                      最后一个\n  返回值 = i+1
                                                  即 HTTP 头之后的第一个字节
```

- **返回正数**：`\r\n\r\n` 之后的第一个字节的 index，也就是 WebSocket 帧数据的起始位置
- **返回 -1**：数据中没有找到 `\r\n\r\n`，HTTP 头还没收完整

### 注意事项

这个匹配算法有一个简化：当遇到不匹配时直接 `k = 0` 重置。对于 `\r\n\r\n` 这个特定模式来说是正确的，因为 `\r` 和 `\n` 交替出现，不会产生"部分回退"的情况（不像通用的 KMP 算法那样需要回退表）。

### 场景二：HTTP 响应分两次收到

```
第 1 次 receive: [HTTP/1.1 101 ... 不完整]
→ findEndOfHTTP 返回 -1（没找到 \r\n\r\n）
→ 整段存入 buffer，parseContent 返回 false（头不完整）
→ 返回 -1，调用方不做额外处理

第 2 次 receive: [剩余 headers\r\n\r\n][WebSocket帧]
→ findEndOfHTTP 返回 offset（正数）
→ buffer 拼上 HTTP 部分，parseContent 解析成功
→ 返回 offset，调用方把后面的 WebSocket 帧送给 framer
```
