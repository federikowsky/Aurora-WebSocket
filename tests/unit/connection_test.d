/**
 * Unit Tests for websocket.connection
 *
 * Tests for WebSocket connection management, UTF-8 validation, etc.
 */
module unit.connection_test;

import websocket.connection;
import websocket.protocol;
import websocket.stream;
import websocket.message;

// ============================================================================
// UTF-8 Validation Tests (via WebSocketConnection)
// ============================================================================

// Note: isValidUtf8 is private, so we test it indirectly through message handling
// These tests verify the optimized ASCII fast-path doesn't break correctness

@("Connection handles pure ASCII text correctly")
unittest {
    auto stream = new MockWebSocketStream();
    auto conn = new WebSocketConnection(stream);

    // Create a masked text frame with ASCII content
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = true;
    frame.maskKey = generateMaskKey();
    frame.payload = cast(ubyte[]) "Hello, World! 123 ABC".dup;

    stream.pushReadData(encodeFrame(frame));

    auto msg = conn.receive();
    assert(msg.type == MessageType.Text);
    assert(msg.text == "Hello, World! 123 ABC");
}

@("Connection handles multi-byte UTF-8 correctly")
unittest {
    auto stream = new MockWebSocketStream();
    auto conn = new WebSocketConnection(stream);

    // UTF-8 with various character lengths
    string utf8Text = "Hello 世界 🌍 café";  // ASCII, 3-byte, 4-byte, 2-byte
    
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = true;
    frame.maskKey = generateMaskKey();
    frame.payload = cast(ubyte[]) utf8Text.dup;

    stream.pushReadData(encodeFrame(frame));

    auto msg = conn.receive();
    assert(msg.type == MessageType.Text);
    assert(msg.text == utf8Text);
}

@("Connection handles long ASCII strings (tests word-at-a-time path)")
unittest {
    auto stream = new MockWebSocketStream();
    auto conn = new WebSocketConnection(stream);

    // Create a long ASCII string (>64 bytes to ensure word-at-a-time kicks in)
    char[] longAscii;
    foreach (i; 0 .. 1000) {
        longAscii ~= cast(char)('A' + (i % 26));
    }
    string text = longAscii.idup;
    
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = true;
    frame.maskKey = generateMaskKey();
    frame.payload = cast(ubyte[]) text.dup;

    stream.pushReadData(encodeFrame(frame));

    auto msg = conn.receive();
    assert(msg.type == MessageType.Text);
    assert(msg.text == text);
    assert(msg.text.length == 1000);
}

@("Connection rejects invalid UTF-8 sequences")
unittest {
    auto stream = new MockWebSocketStream();
    auto conn = new WebSocketConnection(stream);

    // Invalid UTF-8: continuation byte without start byte
    ubyte[] invalidUtf8 = [0x80, 0x81, 0x82];
    
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = true;
    frame.maskKey = generateMaskKey();
    frame.payload = invalidUtf8.dup;

    stream.pushReadData(encodeFrame(frame));

    // Should throw due to invalid UTF-8
    try {
        conn.receive();
        assert(false, "Should have thrown WebSocketClosedException");
    } catch (WebSocketClosedException e) {
        assert(e.code == CloseCode.InvalidPayload);
    }
}

@("Connection rejects overlong UTF-8 encodings")
unittest {
    auto stream = new MockWebSocketStream();
    auto conn = new WebSocketConnection(stream);

    // Overlong encoding of ASCII 'A' (should be 0x41, not C0 C1)
    ubyte[] overlongUtf8 = [0xC0, 0x81];
    
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = true;
    frame.maskKey = generateMaskKey();
    frame.payload = overlongUtf8.dup;

    stream.pushReadData(encodeFrame(frame));

    try {
        conn.receive();
        assert(false, "Should have thrown WebSocketClosedException");
    } catch (WebSocketClosedException e) {
        assert(e.code == CloseCode.InvalidPayload);
    }
}

@("Connection rejects UTF-8 surrogate pairs")
unittest {
    auto stream = new MockWebSocketStream();
    auto conn = new WebSocketConnection(stream);

    // UTF-8 encoding of surrogate U+D800 (invalid in UTF-8)
    ubyte[] surrogateUtf8 = [0xED, 0xA0, 0x80];
    
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = true;
    frame.maskKey = generateMaskKey();
    frame.payload = surrogateUtf8.dup;

    stream.pushReadData(encodeFrame(frame));

    try {
        conn.receive();
        assert(false, "Should have thrown WebSocketClosedException");
    } catch (WebSocketClosedException e) {
        assert(e.code == CloseCode.InvalidPayload);
    }
}

// ============================================================================
// Connection Configuration Tests
// ============================================================================

@("WebSocketConfig has sensible defaults")
unittest {
    WebSocketConfig config;
    assert(config.maxFrameSize == 64 * 1024);
    assert(config.maxMessageSize == 16 * 1024 * 1024);
    assert(config.autoReplyPing == true);
    assert(config.serverMode == true);
}

@("Connection auto-replies to ping when configured")
unittest {
    auto stream = new MockWebSocketStream();
    auto config = WebSocketConfig();
    config.autoReplyPing = true;
    auto conn = new WebSocketConnection(stream, config);

    // Send a ping frame
    Frame pingFrame;
    pingFrame.fin = true;
    pingFrame.opcode = Opcode.Ping;
    pingFrame.masked = true;
    pingFrame.maskKey = generateMaskKey();
    pingFrame.payload = cast(ubyte[]) "ping".dup;

    // Then a text frame so receive() returns
    Frame textFrame;
    textFrame.fin = true;
    textFrame.opcode = Opcode.Text;
    textFrame.masked = true;
    textFrame.maskKey = generateMaskKey();
    textFrame.payload = cast(ubyte[]) "test".dup;

    stream.pushReadData(encodeFrame(pingFrame));
    stream.pushReadData(encodeFrame(textFrame));

    auto msg = conn.receive();
    assert(msg.type == MessageType.Text);
    assert(msg.text == "test");

    // Check that a pong was sent
    auto written = stream.writtenData;
    assert(written.length > 0);
    auto pongResult = decodeFrame(written, false);
    assert(pongResult.success);
    assert(pongResult.frame.opcode == Opcode.Pong);
    assert(pongResult.frame.payload == cast(ubyte[]) "ping");
}
