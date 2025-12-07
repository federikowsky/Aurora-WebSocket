/**
 * Unit tests for WebSocket client functionality.
 */
module tests.unit.client_test;

import aurora_websocket;

// ============================================================================
// URL PARSING TESTS
// ============================================================================

@("parseWebSocketUrl - basic ws URL")
unittest {
    auto url = parseWebSocketUrl("ws://localhost/chat");
    assert(url.valid, url.error);
    assert(url.scheme == "ws");
    assert(url.host == "localhost");
    assert(url.port == 80);
    assert(url.path == "/chat");
}

@("parseWebSocketUrl - with custom port")
unittest {
    auto url = parseWebSocketUrl("ws://example.com:8080/api/ws");
    assert(url.valid, url.error);
    assert(url.host == "example.com");
    assert(url.port == 8080);
    assert(url.path == "/api/ws");
}

@("parseWebSocketUrl - wss scheme")
unittest {
    auto url = parseWebSocketUrl("wss://secure.example.com/");
    assert(url.valid, url.error);
    assert(url.scheme == "wss");
    assert(url.port == 443);
}

@("parseWebSocketUrl - no path defaults to /")
unittest {
    auto url = parseWebSocketUrl("ws://localhost:9000");
    assert(url.valid, url.error);
    assert(url.path == "/");
}

@("parseWebSocketUrl - invalid scheme rejected")
unittest {
    auto url = parseWebSocketUrl("http://localhost/");
    assert(!url.valid);
    assert(url.error == "URL must start with ws:// or wss://");
}

@("parseWebSocketUrl - hostHeader helper")
unittest {
    // Default port omitted
    auto url1 = parseWebSocketUrl("ws://localhost/");
    assert(url1.hostHeader == "localhost");
    
    // Custom port included
    auto url2 = parseWebSocketUrl("ws://localhost:8080/");
    assert(url2.hostHeader == "localhost:8080");
    
    // Default port 80 omitted
    auto url3 = parseWebSocketUrl("ws://localhost:80/");
    assert(url3.hostHeader == "localhost");
    
    // Default port 443 for wss omitted
    auto url4 = parseWebSocketUrl("wss://localhost:443/");
    assert(url4.hostHeader == "localhost");
}

// ============================================================================
// HANDSHAKE TESTS
// ============================================================================

@("generateSecWebSocketKey - produces valid base64")
unittest {
    import std.base64 : Base64;
    
    auto key = generateSecWebSocketKey();
    assert(key.length == 24, "Key should be 24 chars (16 bytes base64)");
    
    // Verify it decodes correctly
    auto decoded = Base64.decode(key);
    assert(decoded.length == 16, "Decoded key should be 16 bytes");
}

@("generateSecWebSocketKey - produces random keys")
unittest {
    auto key1 = generateSecWebSocketKey();
    auto key2 = generateSecWebSocketKey();
    assert(key1 != key2, "Keys should be different");
}

@("buildUpgradeRequest - contains required headers")
unittest {
    import std.algorithm : canFind;
    
    auto request = buildUpgradeRequest(
        "example.com",
        "/chat",
        "dGhlIHNhbXBsZSBub25jZQ=="
    );
    
    assert(request.canFind("GET /chat HTTP/1.1"));
    assert(request.canFind("Host: example.com"));
    assert(request.canFind("Upgrade: websocket"));
    assert(request.canFind("Connection: Upgrade"));
    assert(request.canFind("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="));
    assert(request.canFind("Sec-WebSocket-Version: 13"));
    assert(request[$-4 .. $] == "\r\n\r\n");
}

@("buildUpgradeRequest - includes subprotocols")
unittest {
    import std.algorithm : canFind;
    
    auto request = buildUpgradeRequest(
        "example.com",
        "/",
        "key=====================",
        ["graphql-ws", "chat"]
    );
    
    assert(request.canFind("Sec-WebSocket-Protocol: graphql-ws, chat"));
}

@("buildUpgradeRequest - includes extra headers")
unittest {
    import std.algorithm : canFind;
    
    string[string] headers;
    headers["Origin"] = "https://example.com";
    headers["Cookie"] = "session=abc";
    
    auto request = buildUpgradeRequest(
        "example.com",
        "/",
        "key=====================",
        null,
        headers
    );
    
    assert(request.canFind("Origin: https://example.com"));
    assert(request.canFind("Cookie: session=abc"));
}

@("validateUpgradeResponse - accepts valid response")
unittest {
    auto response = 
        "HTTP/1.1 101 Switching Protocols\r\n" ~
        "Upgrade: websocket\r\n" ~
        "Connection: Upgrade\r\n" ~
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ~
        "\r\n";
    
    auto result = validateUpgradeResponse(response, "dGhlIHNhbXBsZSBub25jZQ==");
    assert(result.valid, result.error);
    assert(result.statusCode == 101);
}

@("validateUpgradeResponse - rejects wrong status code")
unittest {
    auto response = 
        "HTTP/1.1 200 OK\r\n" ~
        "Content-Type: text/html\r\n" ~
        "\r\n";
    
    auto result = validateUpgradeResponse(response, "dGhlIHNhbXBsZSBub25jZQ==");
    assert(!result.valid);
    assert(result.statusCode == 200);
}

@("validateUpgradeResponse - rejects wrong accept key")
unittest {
    auto response = 
        "HTTP/1.1 101 Switching Protocols\r\n" ~
        "Upgrade: websocket\r\n" ~
        "Connection: Upgrade\r\n" ~
        "Sec-WebSocket-Accept: INVALID_KEY\r\n" ~
        "\r\n";
    
    auto result = validateUpgradeResponse(response, "dGhlIHNhbXBsZSBub25jZQ==");
    assert(!result.valid);
    assert(result.error == "Sec-WebSocket-Accept mismatch");
}

@("validateUpgradeResponse - extracts subprotocol")
unittest {
    auto response = 
        "HTTP/1.1 101 Switching Protocols\r\n" ~
        "Upgrade: websocket\r\n" ~
        "Connection: Upgrade\r\n" ~
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ~
        "Sec-WebSocket-Protocol: graphql-ws\r\n" ~
        "\r\n";
    
    auto result = validateUpgradeResponse(response, "dGhlIHNhbXBsZSBub25jZQ==");
    assert(result.valid, result.error);
    assert(result.protocol == "graphql-ws");
}

// ============================================================================
// CONNECTION MODE TESTS
// ============================================================================

@("ConnectionMode - server vs client")
unittest {
    WebSocketConfig serverConfig;
    serverConfig.mode = ConnectionMode.server;
    assert(serverConfig.serverMode == true);
    
    WebSocketConfig clientConfig;
    clientConfig.mode = ConnectionMode.client;
    assert(clientConfig.serverMode == false);
}

@("Client mode - sends masked frames")
unittest {
    auto stream = new MockWebSocketStream();
    auto config = WebSocketConfig();
    config.mode = ConnectionMode.client;
    auto conn = new WebSocketConnection(stream, config);
    
    conn.send("Hello");
    
    auto written = stream.writtenData;
    auto result = decodeFrame(written, false);
    assert(result.success);
    assert(result.frame.masked == true, "Client should send masked frames");
}

@("Client mode - receives unmasked frames")
unittest {
    auto stream = new MockWebSocketStream();
    auto config = WebSocketConfig();
    config.mode = ConnectionMode.client;
    auto conn = new WebSocketConnection(stream, config);
    
    // Server sends unmasked
    Frame serverFrame;
    serverFrame.fin = true;
    serverFrame.opcode = Opcode.Text;
    serverFrame.masked = false;
    serverFrame.payload = cast(ubyte[]) "Hello".dup;
    
    stream.pushReadData(encodeFrame(serverFrame));
    
    auto msg = conn.receive();
    assert(msg.type == MessageType.Text);
    assert(msg.text == "Hello");
}
