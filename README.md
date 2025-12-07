<p align="center">
  <h1 align="center">🔌 Aurora-WebSocket</h1>
  <p align="center">
    <strong>RFC 6455 WebSocket library for D</strong>
  </p>
  <p align="center">
    Zero dependencies • Transport agnostic • Protocol-only design
  </p>
</p>

<p align="center">
  <a href="https://code.dlang.org/packages/aurora-websocket"><img src="https://img.shields.io/dub/v/aurora-websocket?style=flat-square&color=blue" alt="DUB Version"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat-square" alt="License: MIT"></a>
  <a href="https://tools.ietf.org/html/rfc6455"><img src="https://img.shields.io/badge/RFC-6455-blue.svg?style=flat-square" alt="RFC 6455"></a>
  <a href="https://dlang.org/"><img src="https://img.shields.io/badge/D-2.105+-red.svg?style=flat-square" alt="D Language"></a>
</p>

---

## Philosophy

> WebSocket libraries should be **protocol-only**. Connection pooling, auto-reconnect, and transport adapters belong in your application framework.

Aurora-WebSocket implements the WebSocket protocol (RFC 6455) without opinions about your transport layer. Bring your own TCP/TLS stream.

## Features

- ✅ **Zero dependencies** — Only druntime/Phobos
- 🔌 **Transport agnostic** — Works with any `IWebSocketStream` implementation
- 📋 **Full RFC 6455** — Frame encoding, masking, fragmentation, close handshake
- 🔄 **Client & Server** — Both modes supported
- 📦 **Per-Message Deflate** — RFC 7692 compression (optional)
- 🚦 **Backpressure** — Flow control for slow clients

### What's NOT included (by design)

- ❌ TCP/TLS socket implementation
- ❌ Connection pooling  
- ❌ Auto-reconnect logic

## Installation

### DUB

```json
"dependencies": {
    "aurora-websocket": "~>1.0.0"
}
```

## Quick Start

### Step 1: Implement IWebSocketStream

Adapt your transport layer to the stream interface:

```d
import websocket;

class MyTCPAdapter : IWebSocketStream {
    private MyTCPSocket socket;
    
    this(MyTCPSocket s) { socket = s; }
    
    ubyte[] read(ubyte[] buffer) @safe {
        return socket.read(buffer);
    }
    
    ubyte[] readExactly(size_t n) @safe {
        auto buf = new ubyte[](n);
        socket.readFully(buf);
        return buf;
    }
    
    void write(const(ubyte)[] data) @safe {
        socket.write(data);
    }
    
    void flush() @safe { socket.flush(); }
    @property bool connected() @safe nothrow { return socket.isOpen; }
    void close() @safe { socket.close(); }
}
```

### Step 2: Server — Handle WebSocket Upgrade

```d
import websocket;

void handleUpgrade(HTTPRequest req, TCPSocket socket) {
    // Validate upgrade request
    auto validation = validateUpgradeRequest(req.method, req.headers);
    if (!validation.valid) {
        socket.write(cast(ubyte[]) "HTTP/1.1 400 Bad Request\r\n\r\n");
        return;
    }
    
    // Send 101 Switching Protocols
    auto response = buildUpgradeResponse(validation.clientKey);
    socket.write(cast(ubyte[]) response);
    
    // Create WebSocket connection
    auto stream = new MyTCPAdapter(socket);
    auto ws = new WebSocketConnection(stream);
    scope(exit) ws.close();
    
    // Echo server
    while (ws.connected) {
        auto msg = ws.receive();
        
        if (msg.type == MessageType.Text) {
            ws.send("Echo: " ~ msg.text);
        } else if (msg.type == MessageType.Close) {
            break;
        }
    }
}
```

### Step 3: Client — Connect to Server

```d
import websocket;

void connectToServer(string host, ushort port) {
    auto socket = new TCPSocket(host, port);
    auto stream = new MyTCPAdapter(socket);
    
    // Parse WebSocket URL
    auto url = parseWebSocketUrl("ws://example.com/chat");
    
    // Perform handshake
    auto ws = WebSocketClient.connect(stream, url);
    scope(exit) ws.close();
    
    // Send message
    ws.send("Hello, server!");
    
    // Receive response
    auto msg = ws.receive();
    writeln("Received: ", msg.text);
}
```

## API Overview

### Message Types

```d
enum MessageType {
    Text,    // UTF-8 text
    Binary,  // Raw bytes
    Close,   // Connection close
    Ping,    // Heartbeat request
    Pong     // Heartbeat response
}
```

### WebSocketConnection

```d
class WebSocketConnection {
    // Send
    void send(string text);
    void send(const(ubyte)[] binary);
    void ping(const(ubyte)[] payload = null);
    void pong(const(ubyte)[] payload = null);
    
    // Receive
    Message receive();
    
    // Control
    void close(CloseCode code = CloseCode.Normal, string reason = "");
    @property bool connected();
}
```

### Message

```d
struct Message {
    MessageType type;
    ubyte[] data;
    
    @property string text();           // For Text messages
    @property CloseCode closeCode();   // For Close messages
    @property string closeReason();    // For Close messages
}
```

### Close Codes (RFC 6455)

| Code | Name | Description |
|------|------|-------------|
| 1000 | Normal | Normal closure |
| 1001 | GoingAway | Server/client going away |
| 1002 | ProtocolError | Protocol error |
| 1003 | UnsupportedData | Unsupported data type |
| 1008 | PolicyViolation | Policy violation |
| 1009 | MessageTooBig | Message too large |
| 1011 | InternalError | Server error |

## Configuration

```d
WebSocketConfig config;
config.maxFrameSize = 64 * 1024;       // 64 KB
config.maxMessageSize = 16 * 1024 * 1024;  // 16 MB
config.autoReplyPing = true;           // Auto pong
config.mode = ConnectionMode.server;   // or .client

auto ws = new WebSocketConnection(stream, config);
```

## Backpressure (Flow Control)

Handle slow clients without memory exhaustion:

```d
import websocket.backpressure;

auto config = BackpressureConfig();
config.maxSendBufferSize = 4 * 1024 * 1024;  // 4 MB buffer
config.slowClientTimeout = 30.seconds;

auto bpws = new BackpressureWebSocket(connection, config);

bpws.onDrain = () => writeln("Buffer drained");
bpws.onSlowClient = () => writeln("Slow client detected");

// Send with priority
bpws.send("important", MessagePriority.HIGH);
bpws.send("normal data", MessagePriority.NORMAL);
```

## Documentation

- [Technical Specifications](docs/specs.md) — Complete API reference
- [RFC 6455](https://tools.ietf.org/html/rfc6455) — WebSocket Protocol
- [RFC 7692](https://tools.ietf.org/html/rfc7692) — Per-Message Deflate

## Building

### Requirements

- **D Compiler**: LDC 1.35+ or DMD 2.105+

### Make Targets

```bash
make lib    # Build library
dub test    # Run unit tests
make clean  # Clean artifacts
```

## Testing

```bash
# Unit tests
dub test

# Autobahn test suite (requires vibe-d)
cd tests/autobahn
./run_tests.sh
```

## Contributing

Contributions welcome! Please ensure:

1. Tests pass (`dub test`)
2. RFC 6455 compliance maintained
3. No external dependencies added

## License

MIT License — see [LICENSE](LICENSE)

---

<p align="center">
  <sub>Built with ❤️ for the D community</sub>
</p>
