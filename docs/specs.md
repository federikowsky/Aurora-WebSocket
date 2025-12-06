# Aurora-WebSocket Technical Specifications

> **Version**: 1.0.0  
> **Standard**: RFC 6455 (WebSocket Protocol)  
> **License**: MIT  
> **Repository**: [github.com/federikowsky/aurora-websocket](https://github.com/federikowsky/aurora-websocket)  
> **Last Updated**: 2025-12-06

---

## 1. Overview

Aurora-WebSocket is a **pure protocol implementation** of RFC 6455 for the D programming language. It provides:

- Zero external dependencies (only druntime/Phobos)
- Transport-agnostic design via `IWebSocketStream` interface
- Full protocol compliance (frame encoding, masking, fragmentation)
- Client and server modes
- Extension support (per-message deflate)

---

## 2. Architecture

### 2.1 Module Structure

```
source/websocket/
├── package.d       # Public API exports
├── protocol.d      # Low-level frame encode/decode
├── message.d       # Message types and structures
├── handshake.d     # HTTP upgrade handshake
├── connection.d    # WebSocketConnection class
├── client.d        # Client mode utilities
├── stream.d        # Stream interface
├── tls.d           # TLS configuration
└── extension.d     # Extension support
```

### 2.2 Dependency Graph

```
                    +-------------+
                    |  package.d  |
                    +------+------+
                           |
    +----------+----------+----------+-----------+
    |          |          |          |           |
    v          v          v          v           v
protocol.d  message.d  handshake.d  stream.d  extension.d
    |                      |          |
    +----------------------+----------+
                           |
                           v
                     connection.d
                           |
                           v
                       client.d
```

---

## 3. Protocol Implementation

### 3.1 Frame Format (RFC 6455 Section 5.2)

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-------+-+-------------+-------------------------------+
|F|R|R|R| opcode|M| Payload len |    Extended payload length    |
|I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
|N|V|V|V|       |S|             |   (if payload len==126/127)   |
| |1|2|3|       |K|             |                               |
+-+-+-+-+-------+-+-------------+-------------------------------+
|     Extended payload length continued, if payload len == 127  |
+-------------------------------+-------------------------------+
|                               |Masking-key, if MASK set to 1  |
+-------------------------------+-------------------------------+
| Masking-key (continued)       |          Payload Data         |
+-------------------------------+-------------------------------+
|                     Payload Data continued ...                |
+---------------------------------------------------------------+
```

### 3.2 Opcodes

| Opcode | Name | Description |
|--------|------|-------------|
| 0x0 | Continuation | Fragment continuation |
| 0x1 | Text | UTF-8 text frame |
| 0x2 | Binary | Binary data frame |
| 0x8 | Close | Connection close |
| 0x9 | Ping | Heartbeat ping |
| 0xA | Pong | Heartbeat pong |

### 3.3 Close Codes (RFC 6455 Section 7.4)

| Code | Name | Description |
|------|------|-------------|
| 1000 | Normal | Normal closure |
| 1001 | GoingAway | Endpoint going away |
| 1002 | ProtocolError | Protocol error |
| 1003 | UnsupportedData | Unsupported data type |
| 1005 | NoStatus | No status (reserved) |
| 1006 | AbnormalClosure | Abnormal (reserved) |
| 1007 | InvalidPayload | Invalid payload data |
| 1008 | PolicyViolation | Policy violation |
| 1009 | MessageTooBig | Message too big |
| 1010 | MandatoryExtension | Extension required |
| 1011 | InternalError | Internal error |
| 1015 | TLSHandshake | TLS handshake (reserved) |
| 3000-3999 | | Registered applications |
| 4000-4999 | | Private use |

---

## 4. Handshake Protocol

### 4.1 Client Request

```http
GET /chat HTTP/1.1
Host: server.example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
Sec-WebSocket-Protocol: chat, superchat
```

### 4.2 Server Response

```http
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
Sec-WebSocket-Protocol: chat
```

### 4.3 Accept Key Computation

```
Base64(SHA-1(Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
```

---

## 5. Stream Interface

### 5.1 IWebSocketStream

```d
interface IWebSocketStream {
    /// Non-blocking read into buffer
    ubyte[] read(ubyte[] buffer) @safe;
    
    /// Blocking read of exactly n bytes
    ubyte[] readExactly(size_t n) @safe;
    
    /// Blocking write
    void write(const(ubyte)[] data) @safe;
    
    /// Flush buffered data
    void flush() @safe;
    
    /// Connection status
    @property bool connected() @safe nothrow;
    
    /// Close connection
    void close() @safe;
}
```

### 5.2 Implementation Requirements

| Method | Semantics |
|--------|-----------|
| `read()` | Returns immediately with available data or empty slice |
| `readExactly()` | Blocks until n bytes available, throws on EOF |
| `write()` | Blocks until all data written, throws on error |
| `flush()` | Ensures data is sent on wire |
| `connected` | Returns true if connection is usable |
| `close()` | Graceful shutdown |

---

## 6. Configuration

### 6.1 ConnectionMode

```d
enum ConnectionMode {
    /// Server mode (default): expect masked frames, send unmasked
    server,
    /// Client mode: expect unmasked frames, send masked
    client
}
```

### 6.2 WebSocketConfig

```d
struct WebSocketConfig {
    /// Maximum size of a single frame payload (default: 64KB)
    size_t maxFrameSize = 64 * 1024;
    
    /// Maximum size of a reassembled message (default: 16MB)
    size_t maxMessageSize = 16 * 1024 * 1024;
    
    /// Timeout for read operations (0 = no timeout)
    Duration readTimeout = Duration.zero;
    
    /// Automatically reply to ping frames with matching pong
    bool autoReplyPing = true;
    
    /// Connection mode: server (default) or client
    ConnectionMode mode = ConnectionMode.server;
    
    /// Subprotocols supported (server) or requested (client)
    string[] subprotocols;
    
    /// Helper property for backward compatibility
    @property bool serverMode() const pure @safe nothrow;
}
```

### 6.3 TlsPeerValidation

```d
enum TlsPeerValidation {
    /// Validate certificate against trusted CAs (recommended for production)
    trustedCert,
    
    /// Validate certificate and peer name but don't require trusted CA
    validCert,
    
    /// Only require certificate exists, no validation
    requireCert,
    
    /// Skip all certificate validation (INSECURE - for testing only!)
    none
}
```

### 6.4 TlsConfig

```d
struct TlsConfig {
    /// How to validate the server's certificate
    TlsPeerValidation peerValidation = TlsPeerValidation.trustedCert;
    
    /// Custom CA certificate file path (PEM format)
    string caCertFile = null;
    
    /// Client certificate file path (PEM format) for mutual TLS
    string clientCertFile = null;
    
    /// Client private key file path (PEM format) for mutual TLS
    string clientKeyFile = null;
    
    /// Override SNI hostname (null = use connection hostname)
    string sniHost = null;
    
    /// Allow specific TLS versions (null = use library defaults)
    string minVersion = null;
    
    /// Create a TlsConfig that skips certificate validation (INSECURE!)
    static TlsConfig insecure() pure @safe nothrow;
}
```

---

## 7. Masking Rules

### 7.1 Direction-based Masking

| Direction | Sender | Masked |
|-----------|--------|--------|
| Client → Server | Client | YES |
| Server → Client | Server | NO |

### 7.2 Implementation

```d
// Client mode: mask outgoing frames
void sendInClientMode(Frame frame) {
    frame.masked = true;
    frame.maskKey = generateMaskKey();  // Random 4 bytes
    applyMask(frame.payload, frame.maskKey);
    // ... send frame
}

// Server mode: verify incoming frames are masked
void receiveInServerMode(Frame frame) {
    if (!frame.masked) {
        throw new WebSocketProtocolException("Client frames must be masked");
    }
    // ... unmask and process
}
```

---

## 8. Extension: Per-Message Deflate (RFC 7692)

### 8.1 Negotiation

**Client offer:**
```
Sec-WebSocket-Extensions: permessage-deflate; 
    client_max_window_bits; 
    server_max_window_bits=15
```

**Server response:**
```
Sec-WebSocket-Extensions: permessage-deflate; 
    server_max_window_bits=15; 
    client_max_window_bits=15
```

### 8.2 Configuration

```d
struct PerMessageDeflateConfig {
    int compressionLevel = 6;              // zlib 1-9
    int serverMaxWindowBits = 15;          // 8-15
    int clientMaxWindowBits = 15;          // 8-15
    bool serverNoContextTakeover = false;  // Reset context each msg
    bool clientNoContextTakeover = false;
    size_t minCompressSize = 64;           // Skip small messages
}
```

---

## 9. Exception Hierarchy

```d
WebSocketException
├── WebSocketProtocolException   // Frame/protocol errors
├── WebSocketHandshakeException  // Upgrade failures
├── WebSocketClosedException     // Connection closed
│       .closeCode: CloseCode
│       .closeReason: string
├── WebSocketStreamException     // I/O errors
└── WebSocketExtensionException  // Extension errors
```

---

## 10. Thread Safety

| Component | Thread Safe |
|-----------|-------------|
| Frame encode/decode | Yes (pure functions) |
| Handshake functions | Yes (pure functions) |
| WebSocketConnection | No (single-threaded use) |
| PerMessageDeflate | No (single-threaded use) |
| MockWebSocketStream | No |

**Recommendation**: Use one `WebSocketConnection` per fiber/thread.

---

## 11. Memory Management

### 11.1 Allocation Strategy

- Frame payloads: GC-allocated `ubyte[]`
- Messages: GC-allocated
- Internal buffers: Reused where possible

### 11.2 Limits

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `maxFrameSize` | 64KB | Reject oversized frames |
| `maxMessageSize` | 16MB | Reject oversized messages |
| Control frame | 125 bytes | RFC 6455 limit |

---

## 12. Compliance

### 12.1 RFC 6455 Compliance

| Feature | Status |
|---------|--------|
| Frame format | ✅ Full |
| Masking | ✅ Full |
| Fragmentation | ✅ Full |
| Close handshake | ✅ Full |
| Ping/Pong | ✅ Full |
| Status codes | ✅ Full |
| UTF-8 validation | ⚠️ Partial (relies on D string) |

### 12.2 RFC 7692 Compliance (Per-Message Deflate)

| Feature | Status |
|---------|--------|
| Window bits negotiation | ✅ Full |
| Context takeover | ✅ Full |
| Compression | ✅ Full |

---

## 13. Testing

### 13.1 Unit Tests

```bash
# Run all unit tests
dub test

# Expected output
9 modules passed unittests
```

### 13.2 Test Coverage

| Module | Tests |
|--------|-------|
| protocol | Frame encode/decode, masking |
| message | Types, close codes |
| handshake | Server/client validation |
| stream | MockStream behavior |
| tls | Config defaults |
| client | URL parsing |

### 13.3 Integration Testing

Autobahn test suite available in `tests/autobahn/` (requires vibe-d).

---

## 14. API Quick Reference

```d
// Server mode
auto validation = validateUpgradeRequest("GET", headers);
string response = buildUpgradeResponse(validation.clientKey);
auto ws = new WebSocketConnection(stream);
auto msg = ws.receive();
ws.send("Hello");
ws.close();

// Client mode
auto url = parseWebSocketUrl("ws://localhost:8080/chat");
auto ws = WebSocketClient.connect(stream, url);
ws.send("Hello");
auto msg = ws.receive();
ws.close();
```

---

## 15. Backpressure & Flow Control

**Module**: `websocket.backpressure`

Flow control mechanism to handle slow WebSocket clients, preventing memory exhaustion and improving server stability.

### 15.1 Problem Statement

When a WebSocket server sends data faster than a client can receive it:
- Send buffers grow unbounded
- Memory usage spikes
- Server becomes unstable
- Other connections suffer

The backpressure module addresses this with:
- **Send buffer tracking** (`bufferedAmount`)
- **High/low water marks** with hysteresis
- **Slow client detection** and automatic disconnection
- **Message priority queues**

### 15.2 Configuration

```d
struct BackpressureConfig {
    /// Maximum size of send buffer in bytes (default: 16MB)
    size_t maxSendBufferSize = 16 * 1024 * 1024;
    
    /// High water mark as ratio of maxSendBufferSize (default: 0.75)
    double highWaterRatio = 0.75;
    
    /// Low water mark as ratio of maxSendBufferSize (default: 0.25)
    double lowWaterRatio = 0.25;
    
    /// Timeout for slow client detection (default: 30 seconds)
    Duration slowClientTimeout = 30.seconds;
    
    /// Action to take when slow client is detected
    SlowClientAction slowClientAction = SlowClientAction.DISCONNECT;
    
    /// Maximum number of pending messages (default: 10000)
    size_t maxPendingMessages = 10_000;
    
    /// Interval for drain attempts when paused (default: 10ms)
    Duration drainInterval = 10.msecs;
    
    /// Enable message priority queue (default: true)
    bool enablePriorityQueue = true;
    
    /// Drop low priority messages when buffer is full (default: true)
    bool dropLowPriorityOnFull = true;
    
    /// Computed: absolute high water mark in bytes
    @property size_t highWaterMark() const;
    
    /// Computed: absolute low water mark in bytes
    @property size_t lowWaterMark() const;
}
```

### 15.3 States

| State | Description |
|-------|-------------|
| `FLOWING` | Buffer below low water mark - normal operation |
| `PAUSED` | Buffer above high water mark - should stop sending |
| `CRITICAL` | Buffer full - may disconnect slow client |

### 15.4 Message Priority

| Priority | Usage |
|----------|-------|
| `CONTROL` | Ping, pong, close frames - always sent first |
| `HIGH` | Important messages - sent before normal |
| `NORMAL` | Default for user messages |
| `LOW` | Background data - may be dropped when buffer full |

### 15.5 Usage

```d
auto config = BackpressureConfig();
auto bpws = new BackpressureWebSocket(connection, config);

// Set callbacks
bpws.onDrain = () { log.info("Buffer drained, can send more"); };
bpws.onSlowClient = () { log.warn("Slow client detected!"); };
bpws.onStateChange = (old, new_) { log.info("State: ", old, " → ", new_); };

// Send with priority
bpws.send("critical update", MessagePriority.HIGH);
bpws.send("normal data");  // NORMAL priority
bpws.send(binaryData, MessagePriority.LOW);

// Check buffer state
if (bpws.isPaused) {
    // Wait for drain event
}

// Get statistics
auto stats = bpws.getStats();
log.info("Buffered: ", stats.bufferedAmount, " bytes");
log.info("Dropped: ", stats.messagesDropped, " messages");
```

### 15.6 Slow Client Actions

| Action | Behavior |
|--------|----------|
| `DISCONNECT` | Close connection with CloseCode.PolicyViolation |
| `DROP_MESSAGES` | Clear buffer but keep connection |
| `LOG_ONLY` | Just log, don't take action |
| `CUSTOM` | Call `onSlowClient` callback for custom handling |

---

## 16. Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.1.0 | 2025-12-05 | Added backpressure module for flow control |
| 1.0.0 | 2025-12-05 | Initial stable release - zero dependencies, protocol-only |
