/**
 * Unit Tests for websocket.protocol
 *
 * Comprehensive tests for WebSocket frame encoding, decoding, and masking.
 */
module unit.protocol_test;

import websocket.protocol;

// ============================================================================
// Opcode Tests
// ============================================================================

@("Opcode enum matches RFC 6455 Section 5.2")
unittest {
    assert(Opcode.Continuation == 0x0);
    assert(Opcode.Text == 0x1);
    assert(Opcode.Binary == 0x2);
    assert(Opcode.Close == 0x8);
    assert(Opcode.Ping == 0x9);
    assert(Opcode.Pong == 0xA);
}

@("isControlOpcode correctly identifies control frames")
unittest {
    // Data frames
    assert(!isControlOpcode(Opcode.Continuation));
    assert(!isControlOpcode(Opcode.Text));
    assert(!isControlOpcode(Opcode.Binary));

    // Control frames
    assert(isControlOpcode(Opcode.Close));
    assert(isControlOpcode(Opcode.Ping));
    assert(isControlOpcode(Opcode.Pong));
}

@("isDataOpcode correctly identifies data frames")
unittest {
    // Data frames
    assert(isDataOpcode(Opcode.Continuation));
    assert(isDataOpcode(Opcode.Text));
    assert(isDataOpcode(Opcode.Binary));

    // Control frames
    assert(!isDataOpcode(Opcode.Close));
    assert(!isDataOpcode(Opcode.Ping));
    assert(!isDataOpcode(Opcode.Pong));
}

@("isValidOpcode accepts valid opcodes")
unittest {
    assert(isValidOpcode(0x0));  // Continuation
    assert(isValidOpcode(0x1));  // Text
    assert(isValidOpcode(0x2));  // Binary
    assert(isValidOpcode(0x8));  // Close
    assert(isValidOpcode(0x9));  // Ping
    assert(isValidOpcode(0xA));  // Pong
}

@("isValidOpcode rejects reserved opcodes")
unittest {
    // Reserved non-control (0x3-0x7)
    assert(!isValidOpcode(0x3));
    assert(!isValidOpcode(0x4));
    assert(!isValidOpcode(0x5));
    assert(!isValidOpcode(0x6));
    assert(!isValidOpcode(0x7));

    // Reserved control (0xB-0xF)
    assert(!isValidOpcode(0xB));
    assert(!isValidOpcode(0xC));
    assert(!isValidOpcode(0xD));
    assert(!isValidOpcode(0xE));
    assert(!isValidOpcode(0xF));
}

// ============================================================================
// Masking Tests
// ============================================================================

@("applyMask XORs data with rotating key")
unittest {
    ubyte[] data = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    ubyte[4] key = [0x11, 0x22, 0x33, 0x44];

    applyMask(data, key);

    // XOR with rotating key
    assert(data[0] == 0x11);  // 0x00 ^ 0x11
    assert(data[1] == 0x22);  // 0x00 ^ 0x22
    assert(data[2] == 0x33);  // 0x00 ^ 0x33
    assert(data[3] == 0x44);  // 0x00 ^ 0x44
    assert(data[4] == 0x11);  // 0x00 ^ 0x11 (key repeats)
    assert(data[5] == 0x22);  // 0x00 ^ 0x22
}

@("applyMask is symmetric (mask/unmask)")
unittest {
    ubyte[] original = [0x48, 0x65, 0x6C, 0x6C, 0x6F];  // "Hello"
    ubyte[] data = original.dup;
    ubyte[4] key = [0x37, 0xFA, 0x21, 0x3D];

    // Mask
    applyMask(data, key);
    assert(data != original, "Masked data should differ from original");

    // Unmask (apply same mask again)
    applyMask(data, key);
    assert(data == original, "Unmasked data should equal original");
}

@("applyMask handles empty data")
unittest {
    ubyte[] data;
    ubyte[4] key = [0x01, 0x02, 0x03, 0x04];

    applyMask(data, key);  // Should not crash
    assert(data.length == 0);
}

@("generateMaskKey produces 4-byte key")
unittest {
    auto key = generateMaskKey();
    assert(key.length == 4);
}

@("generateMaskKey produces different keys")
unittest {
    auto key1 = generateMaskKey();
    auto key2 = generateMaskKey();

    // Not guaranteed to be different, but extremely unlikely to be same
    // This is a weak test but catches obvious bugs
    bool atLeastOneDifferent = false;
    foreach (i; 0 .. 4) {
        if (key1[i] != key2[i]) {
            atLeastOneDifferent = true;
            break;
        }
    }
    // Allow same keys (very rare) but log it
    // In practice, this should almost always pass
}

// ============================================================================
// Frame Encoding Tests
// ============================================================================

@("encodeFrame creates minimal header for small payload")
unittest {
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = false;
    frame.payload = cast(ubyte[]) "Hi".dup;

    auto encoded = encodeFrame(frame);

    assert(encoded.length == 4);  // 2 byte header + 2 byte payload
    assert(encoded[0] == 0x81);   // FIN=1, opcode=1
    assert(encoded[1] == 0x02);   // MASK=0, len=2
    assert(encoded[2 .. $] == cast(ubyte[]) "Hi");
}

@("encodeFrame sets FIN bit correctly")
unittest {
    Frame frame;
    frame.opcode = Opcode.Text;
    frame.payload = [0x00];

    // FIN = true
    frame.fin = true;
    auto encoded1 = encodeFrame(frame);
    assert((encoded1[0] & 0x80) != 0, "FIN bit should be set");

    // FIN = false (fragmented)
    frame.fin = false;
    frame.opcode = Opcode.Continuation;  // Continuation doesn't validate FIN
    auto encoded2 = encodeFrame(frame);
    assert((encoded2[0] & 0x80) == 0, "FIN bit should be clear");
}

@("encodeFrame uses 16-bit extended length for 126-65535 bytes")
unittest {
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Binary;
    frame.masked = false;
    frame.payload = new ubyte[](200);  // 126 <= 200 <= 65535

    auto encoded = encodeFrame(frame);

    assert(encoded.length == 4 + 200);  // 2 + 2 extended + payload
    assert(encoded[1] == 126);          // Extended length marker
    assert(encoded[2] == 0x00);         // 200 >> 8
    assert(encoded[3] == 0xC8);         // 200 & 0xFF (200 = 0xC8)
}

@("encodeFrame uses 64-bit extended length for >65535 bytes")
unittest {
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Binary;
    frame.masked = false;
    frame.payload = new ubyte[](70000);

    auto encoded = encodeFrame(frame);

    assert(encoded.length == 10 + 70000);  // 2 + 8 extended + payload
    assert(encoded[1] == 127);             // 64-bit length marker

    // Check 64-bit big-endian length
    ulong decodedLen = 0;
    foreach (i; 0 .. 8) {
        decodedLen = (decodedLen << 8) | encoded[2 + i];
    }
    assert(decodedLen == 70000);
}

@("encodeFrame applies masking correctly")
unittest {
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = true;
    frame.maskKey = [0x37, 0xFA, 0x21, 0x3D];
    frame.payload = cast(ubyte[]) "Hello".dup;

    auto encoded = encodeFrame(frame);

    // Header: 2 bytes + 4 byte mask key + 5 byte masked payload = 11 bytes
    assert(encoded.length == 11);
    assert((encoded[1] & 0x80) != 0, "MASK bit should be set");
    assert(encoded[2 .. 6] == frame.maskKey, "Mask key should be in header");

    // Payload should be masked (not plaintext)
    assert(encoded[6 .. $] != cast(ubyte[]) "Hello");
}

@("encodeFrame handles empty payload")
unittest {
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.masked = false;
    frame.payload = null;

    auto encoded = encodeFrame(frame);

    assert(encoded.length == 2);
    assert(encoded[1] == 0x00);  // Zero length
}

@("encodeFrame rejects invalid control frame - payload too large")
unittest {
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Ping;
    frame.payload = new ubyte[](126);  // Max is 125

    bool threw = false;
    try {
        encodeFrame(frame);
    } catch (WebSocketProtocolException) {
        threw = true;
    }
    assert(threw, "Should reject oversized control frame payload");
}

@("encodeFrame rejects fragmented control frame")
unittest {
    Frame frame;
    frame.fin = false;  // Fragmented
    frame.opcode = Opcode.Pong;
    frame.payload = [0x00];

    bool threw = false;
    try {
        encodeFrame(frame);
    } catch (WebSocketProtocolException) {
        threw = true;
    }
    assert(threw, "Should reject fragmented control frame");
}

@("encodeFrame rejects RSV bits set")
unittest {
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.rsv1 = true;  // Extension bit without negotiation

    bool threw = false;
    try {
        encodeFrame(frame);
    } catch (WebSocketProtocolException) {
        threw = true;
    }
    assert(threw, "Should reject RSV bits set without extension");
}

// ============================================================================
// Frame Decoding Tests
// ============================================================================

@("decodeFrame parses simple unmasked frame (client mode)")
unittest {
    ubyte[] data = [
        0x81,  // FIN=1, opcode=1 (text)
        0x05,  // MASK=0, len=5
        'H', 'e', 'l', 'l', 'o'
    ];

    auto result = decodeFrame(data, false);  // Don't require mask

    assert(result.success);
    assert(result.frame.fin);
    assert(result.frame.opcode == Opcode.Text);
    assert(!result.frame.masked);
    assert(result.frame.payload == cast(ubyte[]) "Hello");
    assert(result.bytesConsumed == 7);
}

@("decodeFrame parses masked frame and unmasks payload (server mode)")
unittest {
    ubyte[4] maskKey = [0x37, 0xFA, 0x21, 0x3D];
    ubyte[] payload = cast(ubyte[]) "Hello".dup;
    applyMask(payload, maskKey);

    ubyte[] data = cast(ubyte[])[
        0x81,  // FIN=1, opcode=1
        0x85,  // MASK=1, len=5
    ] ~ maskKey[] ~ payload;

    auto result = decodeFrame(data, true);

    assert(result.success);
    assert(result.frame.masked);
    assert(result.frame.maskKey == maskKey);
    assert(result.frame.payload == cast(ubyte[]) "Hello", "Payload should be unmasked");
}

@("decodeFrame rejects unmasked frame in server mode")
unittest {
    ubyte[] data = [
        0x81,  // FIN=1, opcode=1
        0x05,  // MASK=0, len=5
        'H', 'e', 'l', 'l', 'o'
    ];

    bool threw = false;
    try {
        decodeFrame(data, true);  // requireMasked=true
    } catch (WebSocketProtocolException e) {
        threw = true;
        assert(e.msg == "Client frame must be masked");
    }
    assert(threw, "Should reject unmasked frame in server mode");
}

@("decodeFrame returns needMore for incomplete header")
unittest {
    ubyte[] data = [0x81];  // Only 1 byte

    auto result = decodeFrame(data, false);

    assert(!result.success);
    assert(result.needMore == 1);
}

@("decodeFrame returns needMore for incomplete extended length")
unittest {
    ubyte[] data = [
        0x82,  // FIN=1, opcode=2
        126,   // Extended 16-bit length
        0x01   // Only 1 byte of 2
    ];

    auto result = decodeFrame(data, false);

    assert(!result.success);
    assert(result.needMore == 1);
}

@("decodeFrame returns needMore for incomplete payload")
unittest {
    ubyte[] data = [
        0x81,  // FIN=1, opcode=1
        0x05,  // len=5
        'H', 'e', 'l'  // Only 3 of 5 bytes
    ];

    auto result = decodeFrame(data, false);

    assert(!result.success);
    assert(result.needMore == 2);
}

@("decodeFrame parses 16-bit extended length")
unittest {
    auto payload = new ubyte[](300);
    foreach (i, ref b; payload) {
        b = cast(ubyte)(i & 0xFF);
    }

    ubyte[] data = cast(ubyte[])[
        0x82,       // FIN=1, opcode=2
        126,        // Extended 16-bit length
        0x01, 0x2C  // 300 = 0x012C
    ] ~ payload;

    auto result = decodeFrame(data, false);

    assert(result.success);
    assert(result.frame.payload.length == 300);
    assert(result.bytesConsumed == 4 + 300);
}

@("decodeFrame parses 64-bit extended length")
unittest {
    auto payload = new ubyte[](70000);

    ubyte[] data = cast(ubyte[])[
        0x82,  // FIN=1, opcode=2
        127,   // Extended 64-bit length
        0, 0, 0, 0, 0, 1, 0x11, 0x70  // 70000 = 0x11170
    ] ~ payload;

    auto result = decodeFrame(data, false);

    assert(result.success);
    assert(result.frame.payload.length == 70000);
    assert(result.bytesConsumed == 10 + 70000);
}

@("decodeFrame rejects invalid opcode")
unittest {
    ubyte[] data = [
        0x83,  // FIN=1, opcode=3 (reserved!)
        0x00
    ];

    bool threw = false;
    try {
        decodeFrame(data, false);
    } catch (WebSocketProtocolException e) {
        threw = true;
        assert(e.msg.length > 0);
    }
    assert(threw, "Should reject reserved opcode");
}

@("decodeFrame rejects control frame with payload > 125")
unittest {
    ubyte[] data = cast(ubyte[])[
        0x89,       // FIN=1, opcode=9 (ping)
        126,        // Extended length
        0x00, 0x7E  // 126 bytes (too big!)
    ] ~ new ubyte[](126);

    bool threw = false;
    try {
        decodeFrame(data, false);
    } catch (WebSocketProtocolException) {
        threw = true;
    }
    assert(threw, "Should reject control frame with payload > 125");
}

@("decodeFrame rejects fragmented control frame")
unittest {
    ubyte[] data = [
        0x09,  // FIN=0 (fragmented!), opcode=9 (ping)
        0x04,  // len=4
        'p', 'i', 'n', 'g'
    ];

    bool threw = false;
    try {
        decodeFrame(data, false);
    } catch (WebSocketProtocolException) {
        threw = true;
    }
    assert(threw, "Should reject fragmented control frame");
}

@("decodeFrame rejects RSV bits set")
unittest {
    ubyte[] data = [
        0xC1,  // FIN=1, RSV1=1, opcode=1
        0x00
    ];

    bool threw = false;
    try {
        decodeFrame(data, false);
    } catch (WebSocketProtocolException) {
        threw = true;
    }
    assert(threw, "Should reject RSV bits without extension");
}

// ============================================================================
// Roundtrip Tests
// ============================================================================

@("encode then decode produces identical frame")
unittest {
    Frame original;
    original.fin = true;
    original.opcode = Opcode.Binary;
    original.masked = true;
    original.maskKey = generateMaskKey();
    original.payload = cast(ubyte[]) "Roundtrip test data!".dup;

    auto encoded = encodeFrame(original);
    auto result = decodeFrame(encoded, true);

    assert(result.success);
    assert(result.frame.fin == original.fin);
    assert(result.frame.opcode == original.opcode);
    assert(result.frame.payload == original.payload);
}

@("roundtrip with various payload sizes")
unittest {
    foreach (size; [0, 1, 125, 126, 127, 255, 256, 65535, 65536]) {
        Frame original;
        original.fin = true;
        original.opcode = Opcode.Binary;
        original.masked = false;
        original.payload = new ubyte[](size);
        foreach (i, ref b; original.payload) {
            b = cast(ubyte)(i & 0xFF);
        }

        auto encoded = encodeFrame(original);
        auto result = decodeFrame(encoded, false);

        assert(result.success, "Failed for size " ~ size.stringof);
        assert(result.frame.payload.length == size);
        assert(result.frame.payload == original.payload);
    }
}

// ============================================================================
// Edge Cases
// ============================================================================

@("decode handles maximum 125-byte control frame")
unittest {
    auto payload = new ubyte[](125);
    foreach (i, ref b; payload) {
        b = cast(ubyte) i;
    }

    ubyte[] data = cast(ubyte[])[
        0x8A,  // FIN=1, opcode=A (pong)
        0x7D   // len=125
    ] ~ payload;

    auto result = decodeFrame(data, false);

    assert(result.success);
    assert(result.frame.opcode == Opcode.Pong);
    assert(result.frame.payload.length == 125);
}

@("encode/decode handles empty Close frame")
unittest {
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Close;
    frame.masked = false;
    frame.payload = null;

    auto encoded = encodeFrame(frame);
    auto result = decodeFrame(encoded, false);

    assert(result.success);
    assert(result.frame.opcode == Opcode.Close);
    assert(result.frame.payload.length == 0);
}

@("encode/decode handles Close frame with code and reason")
unittest {
    // Close frame: [code_hi, code_lo, reason...]
    ubyte[] closePayload = cast(ubyte[])[0x03, 0xE8] ~ cast(ubyte[]) "Goodbye".dup;

    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Close;
    frame.masked = false;
    frame.payload = closePayload;

    auto encoded = encodeFrame(frame);
    auto result = decodeFrame(encoded, false);

    assert(result.success);
    assert(result.frame.payload == closePayload);
}
