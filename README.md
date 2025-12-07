# Aurora-WebSocket

RFC 6455 WebSocket library for D.

Protocol-only implementation with zero dependencies. Bring your own transport.

[![DUB](https://img.shields.io/dub/v/aurora-websocket)](https://code.dlang.org/packages/aurora-websocket)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![D](https://img.shields.io/badge/D-2.105%2B-red.svg)](https://dlang.org/)

## Overview

Aurora-WebSocket implements the WebSocket protocol without opinions about your transport layer. It provides frame encoding/decoding, masking, fragmentation, and close handshake handling.

**Key characteristics:**

- Zero external dependencies (only druntime/Phobos)
- Transport agnostic via `IWebSocketStream` interface
- Full RFC 6455 compliance
- Both client and server modes
- Optional RFC 7692 per-message deflate compression
- Backpressure support for flow control

**Not included by design:**

- TCP/TLS socket implementation
- Connection pooling
- Auto-reconnect logic

## Installation

Add to your `dub.json`:

```json
"dependencies": {
    "aurora-websocket": "~>1.0.0"
}
```

Or with `dub.sdl`:

```sdl
dependency "aurora-websocket" version="~>1.0.0"
```

## Quick Start

### Step 1: Implement IWebSocketStream

Adapt your transport layer to the stream interface:

```d
import aurora_websocket;

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

### Step 2: Server Mode

```d
import aurora_websocket;

void handleUpgrade(HTTPRequest req, TCPSocket socket) {
    auto validation = validateUpgradeRequest(req.method, req.headers);
    if (!validation.valid) {
        socket.write(cast(ubyte[]) "HTTP/1.1 400 Bad Request\r\n\r\n");
        return;
    }
    
    auto response = buildUpgradeResponse(validation.clientKey);
    socket.write(cast(ubyte[]) response);
    
    auto stream = new MyTCPAdapter(socket);
    auto ws = new WebSocketConnection(stream);
    scope(exit) ws.close();
    
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

### Step 3: Client Mode

```d
import aurora_websocket;

void connectToServer(string host, ushort port) {
    auto socket = new TCPSocket(host, port);
    auto stream = new MyTCPAdapter(socket);
    
    auto url = parseWebSocketUrl("ws://example.com/chat");
    auto ws = WebSocketClient.connect(stream, url);
    scope(exit) ws.close();
    
    ws.send("Hello, server!");
    
    auto msg = ws.receive();
    writeln("Received: ", msg.text);
}
```

## API Reference

### WebSocketConnection

```d
class WebSocketConnection {
    void send(string text);
    void send(const(ubyte)[] binary);
    void ping(const(ubyte)[] payload = null);
    void pong(const(ubyte)[] payload = null);
    
    Message receive();
    
    void close(CloseCode code = CloseCode.Normal, string reason = "");
    @property bool connected();
}
```

### Message

```d
struct Message {
    MessageType type;
    ubyte[] data;
    
    @property string text();
    @property CloseCode closeCode();
    @property string closeReason();
}

enum MessageType {
    Text,
    Binary,
    Close,
    Ping,
    Pong
}
```

### Close Codes

| Code | Name | Description |
|------|------|-------------|
| 1000 | Normal | Normal closure |
| 1001 | GoingAway | Server/client going away |
| 1002 | ProtocolError | Protocol error |
| 1003 | UnsupportedData | Unsupported data type |
| 1008 | PolicyViolation | Policy violation |
| 1009 | MessageTooBig | Message too large |
| 1011 | InternalError | Server error |

### Configuration

```d
WebSocketConfig config;
config.maxFrameSize = 64 * 1024;
config.maxMessageSize = 16 * 1024 * 1024;
config.autoReplyPing = true;
config.mode = ConnectionMode.server;

auto ws = new WebSocketConnection(stream, config);
```

### Backpressure

```d
import aurora_websocket.backpressure;

auto config = BackpressureConfig();
config.maxSendBufferSize = 4 * 1024 * 1024;
config.slowClientTimeout = 30.seconds;

auto bpws = new BackpressureWebSocket(connection, config);
bpws.send("data", MessagePriority.HIGH);
```

## Building

### Requirements

- **D Compiler**: LDC 1.35+ (recommended) or DMD 2.105+

### Make Targets

| Target | Description |
|--------|-------------|
| `make lib` | Build library |
| `dub test` | Run unit tests |
| `make clean` | Clean artifacts |

## Documentation

- [Technical Specifications](docs/specs.md) — Complete API reference
- [RFC 6455](https://tools.ietf.org/html/rfc6455) — WebSocket Protocol
- [RFC 7692](https://tools.ietf.org/html/rfc7692) — Per-Message Deflate

## Contributing

Contributions are welcome. Please ensure:

1. Tests pass (`dub test`)
2. RFC 6455 compliance is maintained
3. No external dependencies added

## License

MIT License — see [LICENSE](LICENSE) for details.
