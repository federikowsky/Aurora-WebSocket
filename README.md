# Aurora-WebSocket

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![D](https://img.shields.io/badge/D-red.svg)](https://dlang.org/)
[![RFC 6455](https://img.shields.io/badge/RFC-6455-blue.svg)](https://tools.ietf.org/html/rfc6455)

**RFC 6455 compliant WebSocket library for D - Zero dependencies, protocol-only implementation.**

## Features

- ✅ **Zero dependencies** - Only druntime/Phobos required
- ✅ **Transport agnostic** - Works with any stream via `IWebSocketStream`
- ✅ **Full RFC 6455 compliance** - Frame encoding/decoding, masking, fragmentation
- ✅ **Client & Server modes** - Both directions supported
- ✅ **TLS configuration** - `TlsConfig` struct for secure connections
- ✅ **Per-Message Deflate** - RFC 7692 compression extension support

### What's NOT included (by design)

- ❌ Connection pooling (implement in your application/framework)
- ❌ Auto-reconnect (implement in your application/framework)  
- ❌ TCP/TLS adapters (implement `IWebSocketStream` for your transport)

> **Philosophy**: WebSocket libraries should be "protocol-only". Higher-level features like pooling and reconnection belong in the application framework, not the protocol library.

## Installation

```json
{
    "dependencies": {
        "websocket": "~>1.0.0"
    }
}
```

## Quick Start

### 1. Implement IWebSocketStream for your transport

```d
import websocket;

// Example: Adapter for vibe-d TCPConnection
class VibeTCPAdapter : IWebSocketStream {
    private TCPConnection conn;
    
    this(TCPConnection conn) { this.conn = conn; }
    
    ubyte[] read(ubyte[] buffer) @safe {
        auto available = conn.peek();
        auto toRead = min(available, buffer.length);
        conn.read(buffer[0..toRead]);
        return buffer[0..toRead];
    }
    
    ubyte[] readExactly(size_t n) @safe {
        auto buf = new ubyte[](n);
        conn.read(buf);
        return buf;
    }
    
    void write(const(ubyte)[] data) @safe {
        conn.write(data);
    }
    
    void flush() @safe { conn.flush(); }
    @property bool connected() @safe nothrow { return conn.connected; }
    void close() @safe { conn.close(); }
}
```

### 2. Server Mode - Handle WebSocket Upgrade

```d
import websocket;

void handleWebSocketUpgrade(Request req, TCPConnection conn) {
    // Validate HTTP upgrade request
    auto validation = validateUpgradeRequest(req.method, req.headers);
    if (!validation.valid) {
        conn.write(cast(ubyte[]) buildBadRequestResponse(validation.error));
        conn.close();
        return;
    }
    
    // Send HTTP 101 Switching Protocols
    conn.write(cast(ubyte[]) buildUpgradeResponse(validation.clientKey));
    
    // Create WebSocket connection with your adapter
    auto stream = new VibeTCPAdapter(conn);
    auto ws = new WebSocketConnection(stream);
    scope(exit) ws.close();
    
    // Echo server loop
    while (ws.connected) {
        try {
            auto msg = ws.receive();
            if (msg.type == MessageType.Text) {
                ws.send("Echo: " ~ msg.text);
            } else if (msg.type == MessageType.Binary) {
                ws.send(msg.data);
            }
        } catch (WebSocketClosedException e) {
            break;
        }
    }
}
```

### 3. Client Mode

```d
import websocket;

void connectToServer() {
    // Parse WebSocket URL
    auto url = parseWebSocketUrl("ws://localhost:8080/chat");
    
    // Create TCP connection (using your networking library)
    auto tcpConn = connectTCP(url.host, url.port);
    auto stream = new VibeTCPAdapter(tcpConn);
    
    // Perform WebSocket handshake
    auto ws = WebSocketClient.connect(stream, url);
    scope(exit) ws.close();
    
    // Send and receive
    ws.send("Hello, server!");
    auto response = ws.receive();
    writeln("Received: ", response.text);
}
```

## API Reference

### Core Types

```d
// Message types
enum MessageType { Text, Binary, Close, Ping, Pong }

// Close codes (RFC 6455 Section 7.4)
enum CloseCode : ushort {
    Normal = 1000,
    GoingAway = 1001,
    ProtocolError = 1002,
    UnsupportedData = 1003,
    InvalidPayload = 1007,
    PolicyViolation = 1008,
    MessageTooBig = 1009,
    MandatoryExtension = 1010,
    InternalError = 1011
}

// WebSocket message
struct Message {
    MessageType type;
    ubyte[] data;
    @property string text();           // For Text messages
    @property CloseCode closeCode();   // For Close messages
    @property string closeReason();    // For Close messages
}
```

### WebSocketConnection

```d
class WebSocketConnection {
    // Send data
    void send(string text);
    void send(const(ubyte)[] binary);
    void ping(const(ubyte)[] data = null);
    void pong(const(ubyte)[] data = null);
    void close(CloseCode code = CloseCode.Normal, string reason = "");
    
    // Receive data (blocking)
    Message receive();
    
    // Connection state
    @property bool connected();
}
```

### Stream Interface

```d
interface IWebSocketStream {
    ubyte[] read(ubyte[] buffer) @safe;       // Non-blocking
    ubyte[] readExactly(size_t n) @safe;      // Blocking
    void write(const(ubyte)[] data) @safe;    // Blocking
    void flush() @safe;
    @property bool connected() @safe nothrow;
    void close() @safe;
}
```

### Handshake Utilities

```d
// Server: Validate upgrade request
auto validation = validateUpgradeRequest("GET", headers);
if (!validation.valid) {
    // validation.error contains reason
}

// Server: Build 101 response
string response = buildUpgradeResponse(validation.clientKey);
string response = buildUpgradeResponse(clientKey, "graphql-ws");  // with subprotocol

// Server: Build 400 response
string error = buildBadRequestResponse("Invalid key");

// Client: Generate random key
string key = generateSecWebSocketKey();

// Client: Build upgrade request
string request = buildUpgradeRequest(host, path, key);

// Client: Validate server response
auto result = validateUpgradeResponse(responseStr, sentKey);
```

### TLS Configuration

```d
// TLS validation modes
enum TlsPeerValidation {
    trustedCert,   // Full validation (recommended)
    validCert,     // Validate cert, allow untrusted CA
    requireCert,   // Only check cert exists
    none           // Skip validation (INSECURE!)
}

// Configuration struct (pass to your TLS adapter)
struct TlsConfig {
    TlsPeerValidation peerValidation = TlsPeerValidation.trustedCert;
    string caCertFile = null;
    string clientCertFile = null;  // For mutual TLS
    string clientKeyFile = null;
    string sniHost = null;
    string minVersion = null;
    
    static TlsConfig insecure();   // For testing only!
}
```

### Configuration

```d
struct WebSocketConfig {
    size_t maxFrameSize = 64 * 1024;           // 64KB
    size_t maxMessageSize = 16 * 1024 * 1024;  // 16MB
    bool autoReplyPing = true;
    ConnectionMode mode = ConnectionMode.server;
}

auto config = WebSocketConfig();
config.mode = ConnectionMode.client;  // For client connections
auto ws = new WebSocketConnection(stream, config);
```

### Per-Message Deflate (RFC 7692)

```d
// Configure compression
auto deflateConfig = PerMessageDeflateConfig();
deflateConfig.compressionLevel = 6;
deflateConfig.minCompressSize = 64;

auto deflate = new PerMessageDeflate(deflateConfig, true);  // isClient=true

// Generate extension offer for handshake
string offer = deflate.generateOffer();

// Accept offer (server-side)
string response = deflate.acceptOffer(clientOffer);

// Transform frames
auto compressed = deflate.transformOutgoing(frame);
auto decompressed = deflate.transformIncoming(frame);
```

## Exception Hierarchy

```d
WebSocketException                    // Base class
├── WebSocketProtocolException        // Invalid frames, masking errors
├── WebSocketHandshakeException       // Upgrade failures  
├── WebSocketClosedException          // Connection closed (code + reason)
├── WebSocketStreamException          // I/O errors
└── WebSocketExtensionException       // Extension negotiation errors
```

## Architecture

```
aurora-websocket/
├── source/websocket/
│   ├── package.d      # Public API re-exports
│   ├── protocol.d     # Frame encode/decode, masking
│   ├── message.d      # Message types, CloseCode
│   ├── handshake.d    # HTTP upgrade validation
│   ├── connection.d   # WebSocketConnection class
│   ├── client.d       # WebSocketClient, URL parsing
│   ├── stream.d       # IWebSocketStream interface
│   ├── tls.d          # TlsConfig struct
│   └── extension.d    # Per-message deflate
└── tests/
    └── unit/          # Unit tests
```

## Testing

```bash
# Run unit tests
dub test

# Build library
dub build
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [Aurora Framework](https://github.com/federikowsky/Aurora) - High-performance D web framework
