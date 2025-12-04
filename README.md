# WebSocket for D

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

RFC 6455 compliant WebSocket library for D. Standalone with optional Aurora framework integration.

## Features

- ✅ **RFC 6455 Compliant** - Full WebSocket protocol implementation
- ✅ **Server Mode** - Accept WebSocket connections from clients
- ✅ **Standalone** - Works with any stream (vibe-d, raw sockets, etc.)
- ✅ **Aurora Integration** - Seamless integration with Aurora framework's `HijackedConnection`
- ✅ **Simple API** - Clean, ergonomic interface for common use cases

## Installation

Add to your `dub.json`:

```json
{
    "dependencies": {
        "websocket": "~>1.0.0"
    }
}
```

## Quick Start

### With Aurora Framework

```d
import aurora;
import websocket;

void main() {
    auto app = Aurora();

    app.get("/ws", (ref ctx) {
        // Validate the WebSocket upgrade request
        auto validation = validateUpgradeRequest("GET", ctx.headers);
        if (!validation.valid) {
            ctx.status(400).send(validation.error);
            return;
        }

        // Hijack the connection and send upgrade response
        auto conn = ctx.hijack();
        conn.write(cast(ubyte[]) buildUpgradeResponse(validation.clientKey));

        // Create WebSocket over the hijacked connection
        auto stream = new VibeTCPAdapter(conn.tcpConnection);
        auto ws = new WebSocketConnection(stream);
        scope(exit) ws.close();

        // Echo server loop
        while (ws.connected) {
            try {
                auto msg = ws.receive();
                if (msg.type == MessageType.Text) {
                    ws.send("Echo: " ~ msg.text);
                }
            } catch (WebSocketClosedException e) {
                break;
            }
        }
    });

    app.listen(8080);
}
```

### Standalone with vibe-core

```d
import websocket;
import vibe.core.net;

void handleConnection(TCPConnection conn) {
    // (HTTP parsing would happen here - simplified for example)
    string[string] headers;
    headers["host"] = "localhost";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto validation = validateUpgradeRequest("GET", headers);
    if (!validation.valid) {
        conn.write(cast(ubyte[]) buildBadRequestResponse(validation.error));
        conn.close();
        return;
    }

    // Send upgrade response
    conn.write(cast(ubyte[]) buildUpgradeResponse(validation.clientKey));

    // Create WebSocket connection
    auto stream = new VibeTCPAdapter(conn);
    auto ws = new WebSocketConnection(stream);
    scope(exit) ws.close();

    // Echo loop
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

## API Overview

### Message Types

```d
enum MessageType { Text, Binary, Close, Ping, Pong }
enum CloseCode : ushort { Normal = 1000, GoingAway = 1001, ... }

struct Message {
    MessageType type;
    ubyte[] data;
    @property string text();      // For Text messages
    @property CloseCode closeCode();  // For Close messages
}
```

### WebSocket Connection

```d
class WebSocketConnection {
    void send(string text);
    void send(const(ubyte)[] binary);
    void ping(const(ubyte)[] data = null);
    void close(CloseCode code = CloseCode.Normal, string reason = "");
    
    Message receive();  // Blocking
    @property bool connected();
}
```

### Handshake Utilities

```d
// Validate upgrade request
auto validation = validateUpgradeRequest("GET", headers);
if (!validation.valid) { /* error */ }

// Compute Sec-WebSocket-Accept
string acceptKey = computeAcceptKey(clientKey);

// Build HTTP 101 response
string response = buildUpgradeResponse(clientKey);
```

## Exception Hierarchy

```d
WebSocketException           // Base for all WS errors
├── WebSocketProtocolException   // Invalid frames, masking errors
├── WebSocketHandshakeException  // Upgrade failures
├── WebSocketClosedException     // Connection closed (has code & reason)
└── WebSocketStreamException     // I/O errors
```

## Configuration

```d
WebSocketConfig config;
config.maxFrameSize = 64 * 1024;      // 64KB
config.maxMessageSize = 16 * 1024 * 1024;  // 16MB
config.autoReplyPing = true;

auto ws = WebSocket.accept(stream, clientKey, config);
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [Aurora](https://github.com/aurora-framework/aurora) - High-performance D web framework
