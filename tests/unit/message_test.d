/**
 * Unit Tests for websocket.message
 *
 * Comprehensive tests for MessageType, CloseCode, and Message struct.
 */
module unit.message_test;

import websocket.message;

// ============================================================================
// MessageType Tests
// ============================================================================

@("MessageType enum has correct values")
unittest {
    // Verify all expected types exist
    auto _ = MessageType.Text;
    _ = MessageType.Binary;
    _ = MessageType.Close;
    _ = MessageType.Ping;
    _ = MessageType.Pong;
}

// ============================================================================
// CloseCode Tests
// ============================================================================

@("CloseCode enum matches RFC 6455 Section 7.4")
unittest {
    assert(CloseCode.Normal == 1000);
    assert(CloseCode.GoingAway == 1001);
    assert(CloseCode.ProtocolError == 1002);
    assert(CloseCode.UnsupportedData == 1003);
    assert(CloseCode.NoStatus == 1005);
    assert(CloseCode.AbnormalClosure == 1006);
    assert(CloseCode.InvalidPayload == 1007);
    assert(CloseCode.PolicyViolation == 1008);
    assert(CloseCode.MessageTooBig == 1009);
    assert(CloseCode.MandatoryExtension == 1010);
    assert(CloseCode.InternalError == 1011);
    assert(CloseCode.TLSHandshake == 1015);
}

@("isValidCloseCode accepts valid codes")
unittest {
    // Standard codes (sendable)
    assert(isValidCloseCode(cast(ushort) 1000));
    assert(isValidCloseCode(cast(ushort) 1001));
    assert(isValidCloseCode(cast(ushort) 1002));
    assert(isValidCloseCode(cast(ushort) 1003));
    assert(isValidCloseCode(cast(ushort) 1007));
    assert(isValidCloseCode(cast(ushort) 1008));
    assert(isValidCloseCode(cast(ushort) 1009));
    assert(isValidCloseCode(cast(ushort) 1010));
    assert(isValidCloseCode(cast(ushort) 1011));

    // Application-specific (3000-3999)
    assert(isValidCloseCode(cast(ushort) 3000));
    assert(isValidCloseCode(cast(ushort) 3500));
    assert(isValidCloseCode(cast(ushort) 3999));

    // Private use (4000-4999)
    assert(isValidCloseCode(cast(ushort) 4000));
    assert(isValidCloseCode(cast(ushort) 4500));
    assert(isValidCloseCode(cast(ushort) 4999));
}

@("isValidCloseCode rejects invalid codes")
unittest {
    // Reserved codes (must not be sent)
    assert(!isValidCloseCode(cast(ushort) 1005));  // NoStatus
    assert(!isValidCloseCode(cast(ushort) 1006));  // AbnormalClosure
    assert(!isValidCloseCode(cast(ushort) 1015));  // TLSHandshake

    // Gap in valid range
    assert(!isValidCloseCode(cast(ushort) 1004));
    assert(!isValidCloseCode(cast(ushort) 1012));
    assert(!isValidCloseCode(cast(ushort) 1013));
    assert(!isValidCloseCode(cast(ushort) 1014));

    // Out of bounds
    assert(!isValidCloseCode(cast(ushort) 0));
    assert(!isValidCloseCode(cast(ushort) 999));
    assert(!isValidCloseCode(cast(ushort) 2999));
    assert(!isValidCloseCode(cast(ushort) 5000));
    assert(!isValidCloseCode(cast(ushort) 65535));
}

// ============================================================================
// Message Factory Tests
// ============================================================================

@("Message.fromText creates correct message")
unittest {
    auto msg = Message.fromText("Hello, World!");

    assert(msg.type == MessageType.Text);
    assert(msg.text == "Hello, World!");
    assert(msg.data == cast(ubyte[]) "Hello, World!");
    assert(msg.isData);
    assert(!msg.isControl);
}

@("Message.fromText handles empty string")
unittest {
    auto msg = Message.fromText("");

    assert(msg.type == MessageType.Text);
    assert(msg.text == "");
    assert(msg.data.length == 0);
}

@("Message.fromText handles unicode")
unittest {
    auto msg = Message.fromText("Hello, 世界! 🌍");

    assert(msg.type == MessageType.Text);
    assert(msg.text == "Hello, 世界! 🌍");
}

@("Message.fromBinary creates correct message")
unittest {
    ubyte[] data = [0x00, 0x01, 0x7F, 0x80, 0xFF];
    auto msg = Message.fromBinary(data);

    assert(msg.type == MessageType.Binary);
    assert(msg.data == data);
    assert(msg.isData);
    assert(!msg.isControl);
}

@("Message.fromBinary handles empty data")
unittest {
    auto msg = Message.fromBinary(null);

    assert(msg.type == MessageType.Binary);
    assert(msg.data is null || msg.data.length == 0);
}

@("Message.fromClose creates correct message with code and reason")
unittest {
    auto msg = Message.fromClose(CloseCode.Normal, "Goodbye!");

    assert(msg.type == MessageType.Close);
    assert(msg.closeCode == CloseCode.Normal);
    assert(msg.closeReason == "Goodbye!");
    assert(msg.isControl);
    assert(!msg.isData);

    // Verify payload structure (big-endian code + reason)
    assert(msg.data.length == 2 + "Goodbye!".length);
    assert(msg.data[0] == 0x03);  // 1000 >> 8
    assert(msg.data[1] == 0xE8);  // 1000 & 0xFF
}

@("Message.fromClose creates correct message without reason")
unittest {
    auto msg = Message.fromClose(CloseCode.GoingAway);

    assert(msg.closeCode == CloseCode.GoingAway);
    assert(msg.closeReason == "");
    assert(msg.data.length == 2);
}

@("Message.fromClose creates correct message with default code")
unittest {
    auto msg = Message.fromClose();

    assert(msg.closeCode == CloseCode.Normal);
    assert(msg.closeReason == "");
}

@("Message.fromPing creates correct message")
unittest {
    ubyte[] payload = [0x01, 0x02, 0x03, 0x04];
    auto msg = Message.fromPing(payload);

    assert(msg.type == MessageType.Ping);
    assert(msg.data == payload);
    assert(msg.isControl);
}

@("Message.fromPing handles empty payload")
unittest {
    auto msg = Message.fromPing();

    assert(msg.type == MessageType.Ping);
    assert(msg.data is null || msg.data.length == 0);
}

@("Message.fromPong creates correct message")
unittest {
    ubyte[] payload = [0xAA, 0xBB, 0xCC];
    auto msg = Message.fromPong(payload);

    assert(msg.type == MessageType.Pong);
    assert(msg.data == payload);
    assert(msg.isControl);
}

// ============================================================================
// Message Property Tests
// ============================================================================

@("Message.text property returns empty for non-Text types")
unittest {
    auto binary = Message.fromBinary([0x01, 0x02]);
    assert(binary.text == "");

    auto ping = Message.fromPing([0x01]);
    assert(ping.text == "");

    auto close = Message.fromClose();
    assert(close.text == "");
}

@("Message.closeCode returns NoStatus for non-Close types")
unittest {
    auto text = Message.fromText("hello");
    assert(text.closeCode == CloseCode.NoStatus);

    auto binary = Message.fromBinary([0x01]);
    assert(binary.closeCode == CloseCode.NoStatus);
}

@("Message.closeCode returns NoStatus for short Close payload")
unittest {
    // Close with only 1 byte (invalid, but handle gracefully)
    auto msg = Message(MessageType.Close, [0x03]);
    assert(msg.closeCode == CloseCode.NoStatus);

    // Empty close
    auto empty = Message(MessageType.Close, null);
    assert(empty.closeCode == CloseCode.NoStatus);
}

@("Message.closeReason returns empty for short Close payload")
unittest {
    // Close with only code, no reason
    auto msg = Message(MessageType.Close, [0x03, 0xE8]);
    assert(msg.closeReason == "");
}

@("Message.isControl and isData are mutually exclusive")
unittest {
    auto text = Message.fromText("hi");
    assert(text.isData && !text.isControl);

    auto binary = Message.fromBinary([0x01]);
    assert(binary.isData && !binary.isControl);

    auto close = Message.fromClose();
    assert(close.isControl && !close.isData);

    auto ping = Message.fromPing();
    assert(ping.isControl && !ping.isData);

    auto pong = Message.fromPong();
    assert(pong.isControl && !pong.isData);
}

// ============================================================================
// Edge Cases
// ============================================================================

@("Message factories create independent copies")
unittest {
    ubyte[] original = [0x01, 0x02, 0x03];
    auto msg = Message.fromBinary(original);

    // Modify original
    original[0] = 0xFF;

    // Message should be unaffected
    assert(msg.data[0] == 0x01);
}

@("Close code parsing handles all valid codes")
unittest {
    // Test a few representative codes
    void testCode(CloseCode expected) {
        auto msg = Message.fromClose(expected, "test");
        assert(msg.closeCode == expected, "Failed for code " ~ (cast(int) expected).stringof);
    }

    testCode(CloseCode.Normal);
    testCode(CloseCode.GoingAway);
    testCode(CloseCode.ProtocolError);
    testCode(CloseCode.InternalError);
}
