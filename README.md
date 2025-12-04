# WebSocket for D

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

RFC 6455 compliant WebSocket library for D. Standalone with optional Aurora framework integration.

## Features

- ✅ **RFC 6455 Compliant** - Full WebSocket protocol implementation
- ✅ **Server Mode** - Accept WebSocket connections from clients
- ✅ **Client Mode** - Connect to WebSocket servers
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

### Client Mode

```d
import websocket;

void main() {
    // Connect to a WebSocket server
    auto ws = WebSocketClient.connect("ws://localhost:8080/chat");
    scope(exit) ws.close();
    
    // Send a message
    ws.send("Hello, server!");
    
    // Receive response
    auto msg = ws.receive();
    if (msg.type == MessageType.Text) {
        writeln("Received: ", msg.text);
    }
}
```

### Server Mode - With Aurora Framework

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

### Server Mode - Standalone with vibe-core

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
// Validate upgrade request (server)
auto validation = validateUpgradeRequest("GET", headers);
if (!validation.valid) { /* error */ }

// Compute Sec-WebSocket-Accept
string acceptKey = computeAcceptKey(clientKey);

// Build HTTP 101 response (server)
string response = buildUpgradeResponse(clientKey);
```

### WebSocket Client

```d
// Simple connection
auto ws = WebSocketClient.connect("ws://localhost:8080/chat");

// With custom headers
string[string] headers;
headers["Origin"] = "https://example.com";
auto ws = WebSocketClient.connectWithHeaders(url, headers);

// With subprotocols
auto ws = WebSocketClient.connectWithProtocols(url, ["graphql-ws", "json"]);
if (ws.subprotocol == "graphql-ws") {
    // Use GraphQL protocol
}
```

### Subprotocol Negotiation

WebSocket subprotocols allow client and server to agree on an application-level protocol.

**Client side:**
```d
// Request specific subprotocols
auto ws = WebSocketClient.connectWithProtocols(
    "ws://localhost:8080/api",
    ["graphql-ws", "json", "soap"]  // In order of preference
);

// Check which protocol was selected
if (ws.subprotocol == "graphql-ws") {
    writeln("Using GraphQL WebSocket protocol");
} else if (ws.subprotocol == "json") {
    writeln("Using JSON protocol");
}
```

**Server side:**
```d
// When handling upgrade request
auto validation = validateUpgradeRequest("GET", headers);
if (!validation.valid) { /* error */ }

// Select a subprotocol from client's request
string[] serverSupported = ["graphql-ws", "json"];
string selected = selectSubprotocol(serverSupported, validation.protocols);

// Include selected protocol in response
string response = buildUpgradeResponse(validation.clientKey, selected);

// Create connection with negotiated protocol
auto ws = new WebSocketConnection(stream, config, selected);
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
config.mode = ConnectionMode.server;   // or ConnectionMode.client

// Heartbeat settings
config.pingInterval = 30.seconds;     // Send ping every 30s (0 = disabled)
config.pongTimeout = 10.seconds;      // Close if no pong within 10s

auto ws = new WebSocketConnection(stream, config);
```

### Automatic Heartbeat

The library supports automatic ping/pong heartbeat to detect dead connections:

```d
auto config = WebSocketConfig();
config.pingInterval = 30.seconds;
config.pongTimeout = 10.seconds;

auto ws = new WebSocketConnection(stream, config);

// Start automatic heartbeat
ws.startHeartbeat();

// ... use connection normally ...

// Monitor connection health
if (ws.timeSinceLastPong > 5.seconds) {
    writeln("Connection may be slow");
}

// Stop heartbeat before closing (optional, close() does this automatically)
ws.stopHeartbeat();
ws.close();
```

When heartbeat is active:
- Ping frames are sent at the configured interval
- Pong responses are tracked
- If no pong is received within the timeout, the connection is closed automatically

### Per-Message Deflate Compression (RFC 7692)

The library supports per-message deflate compression to reduce bandwidth:

```d
// Create deflate extension with custom config
auto deflateConfig = PerMessageDeflateConfig();
deflateConfig.compressionLevel = 6;       // 1-9, higher = better compression
deflateConfig.minCompressSize = 64;       // Don't compress small messages
deflateConfig.clientNoContextTakeover = true;  // Reset context each message

auto deflate = new PerMessageDeflate(deflateConfig, true);  // true = client mode

// Server-side: Accept deflate extension during handshake
auto validation = validateUpgradeRequest("GET", headers);
if ("permessage-deflate" in parseExtensionsHeader(validation.extensions[0])) {
    auto deflate = new PerMessageDeflate();
    auto response = deflate.acceptOffer(validation.extensions[0]);
    // Include response in upgrade headers
}

// Client-side: Generate extension offer
auto offer = deflate.generateOffer();
// Include in Sec-WebSocket-Extensions header during handshake

// After negotiation, transform frames
auto compressedFrame = deflate.transformOutgoing(frame);
auto decompressedFrame = deflate.transformIncoming(receivedFrame);
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [Aurora](https://github.com/aurora-framework/aurora) - High-performance D web framework
