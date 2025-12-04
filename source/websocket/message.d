/**
 * WebSocket Message Types & Close Codes
 *
 * Module: websocket.message
 *
 * Defines high-level message types for WebSocket communication.
 * Maps RFC 6455 opcodes to semantic types and provides convenience
 * factories for creating messages.
 *
 * Standards: RFC 6455 - The WebSocket Protocol
 */
module websocket.message;

// ============================================================================
// MESSAGE TYPES
// ============================================================================

/**
 * WebSocket message types (RFC 6455 opcodes mapped to semantic types).
 *
 * Note: Continuation frames are handled internally during message reassembly
 * and are not exposed as a message type.
 */
enum MessageType {
    /// Text message (UTF-8 encoded) - Opcode 0x1
    Text,
    /// Binary message (raw bytes) - Opcode 0x2
    Binary,
    /// Connection close - Opcode 0x8
    Close,
    /// Ping (keep-alive request) - Opcode 0x9
    Ping,
    /// Pong (keep-alive response) - Opcode 0xA
    Pong
}

// ============================================================================
// CLOSE CODES (RFC 6455 Section 7.4)
// ============================================================================

/**
 * WebSocket close status codes as defined in RFC 6455 Section 7.4.
 *
 * These codes indicate the reason for closing the connection and are
 * sent in the Close frame payload.
 */
enum CloseCode : ushort {
    /// 1000 - Normal closure; the connection successfully completed.
    Normal = 1000,

    /// 1001 - Endpoint is going away (server shutdown, browser navigating away).
    GoingAway = 1001,

    /// 1002 - Protocol error encountered.
    ProtocolError = 1002,

    /// 1003 - Received data type that cannot be accepted (e.g., text-only endpoint got binary).
    UnsupportedData = 1003,

    /// 1005 - Reserved. No status code was present. (Must not be sent in a Close frame)
    NoStatus = 1005,

    /// 1006 - Reserved. Connection closed abnormally. (Must not be sent in a Close frame)
    AbnormalClosure = 1006,

    /// 1007 - Invalid payload data (e.g., non-UTF-8 in text message).
    InvalidPayload = 1007,

    /// 1008 - Policy violation.
    PolicyViolation = 1008,

    /// 1009 - Message too big to process.
    MessageTooBig = 1009,

    /// 1010 - Client expected server to negotiate extension(s).
    MandatoryExtension = 1010,

    /// 1011 - Server encountered an unexpected condition.
    InternalError = 1011,

    /// 1015 - Reserved. TLS handshake failure. (Must not be sent in a Close frame)
    TLSHandshake = 1015
}

/**
 * Check if a close code is valid for sending in a Close frame.
 *
 * Codes 1005, 1006, and 1015 are reserved and must not be sent.
 */
bool isValidCloseCode(ushort code) pure nothrow @safe @nogc {
    // Valid ranges: 1000-1003, 1007-1011, 3000-3999, 4000-4999
    if (code >= 1000 && code <= 1003) return true;
    if (code >= 1007 && code <= 1011) return true;
    if (code >= 3000 && code <= 4999) return true;  // Application/private use
    return false;
}

/// ditto
bool isValidCloseCode(CloseCode code) pure nothrow @safe @nogc {
    return isValidCloseCode(cast(ushort) code);
}

// ============================================================================
// MESSAGE STRUCT
// ============================================================================

/**
 * A WebSocket message.
 *
 * Represents a complete message (possibly reassembled from multiple frames).
 * Provides convenience properties for accessing text content and close information.
 *
 * Example:
 * ---
 * auto msg = ws.receive();
 * if (msg.type == MessageType.Text) {
 *     writeln("Received: ", msg.text);
 * } else if (msg.type == MessageType.Close) {
 *     writeln("Close code: ", msg.closeCode, " reason: ", msg.closeReason);
 * }
 * ---
 */
struct Message {
    /// The type of this message
    MessageType type;

    /// Raw payload data
    ubyte[] data;

    // ─────────────────────────────────────────────
    // Convenience Properties
    // ─────────────────────────────────────────────

    /**
     * Get the message payload as a UTF-8 string.
     *
     * Only valid for Text messages. For other types, returns empty string.
     * Note: Does not validate UTF-8 encoding.
     */
    @property string text() const pure nothrow @trusted {
        if (type != MessageType.Text || data.length == 0)
            return "";
        return cast(string) data;
    }

    /**
     * Get the close code from a Close message.
     *
     * Close frame payload: [2 bytes close code] [optional reason string]
     * Returns CloseCode.NoStatus if payload is too short.
     */
    @property CloseCode closeCode() const pure nothrow @safe @nogc {
        if (type != MessageType.Close || data.length < 2)
            return CloseCode.NoStatus;
        // Close code is big-endian
        ushort code = (cast(ushort) data[0] << 8) | data[1];
        return cast(CloseCode) code;
    }

    /**
     * Get the close reason string from a Close message.
     *
     * Returns empty string if no reason was provided.
     */
    @property string closeReason() const pure nothrow @trusted {
        if (type != MessageType.Close || data.length <= 2)
            return "";
        return cast(string) data[2 .. $];
    }

    /**
     * Check if this is a control message (Close, Ping, or Pong).
     */
    @property bool isControl() const pure nothrow @safe @nogc {
        return type == MessageType.Close ||
               type == MessageType.Ping ||
               type == MessageType.Pong;
    }

    /**
     * Check if this is a data message (Text or Binary).
     */
    @property bool isData() const pure nothrow @safe @nogc {
        return type == MessageType.Text || type == MessageType.Binary;
    }

    // ─────────────────────────────────────────────
    // Factory Methods
    // ─────────────────────────────────────────────

    /**
     * Create a Text message.
     */
    static Message fromText(string s) pure nothrow @trusted {
        return Message(MessageType.Text, cast(ubyte[]) s.dup);
    }

    /**
     * Create a Binary message.
     */
    static Message fromBinary(const(ubyte)[] d) pure nothrow @safe {
        return Message(MessageType.Binary, d.dup);
    }

    /**
     * Create a Close message with optional code and reason.
     *
     * Params:
     *   code = Close status code (default: Normal)
     *   reason = Optional UTF-8 reason string (max ~123 bytes for control frame limit)
     */
    static Message fromClose(CloseCode code = CloseCode.Normal, string reason = "") pure nothrow @trusted {
        // Close payload: [2-byte code big-endian] [optional reason]
        auto payload = new ubyte[](2 + reason.length);
        payload[0] = cast(ubyte)(code >> 8);
        payload[1] = cast(ubyte)(code & 0xFF);
        if (reason.length > 0) {
            payload[2 .. $] = cast(ubyte[]) reason;
        }
        return Message(MessageType.Close, payload);
    }

    /**
     * Create a Ping message with optional payload.
     *
     * Note: Control frame payloads must be <= 125 bytes.
     */
    static Message fromPing(const(ubyte)[] d = null) pure nothrow @safe {
        return Message(MessageType.Ping, d ? d.dup : null);
    }

    /**
     * Create a Pong message with optional payload.
     *
     * Note: Pong payload should match the Ping payload it responds to.
     */
    static Message fromPong(const(ubyte)[] d = null) pure nothrow @safe {
        return Message(MessageType.Pong, d ? d.dup : null);
    }
}

// ============================================================================
// UNIT TESTS
// ============================================================================

unittest {
    // Test MessageType enum values
    assert(MessageType.Text != MessageType.Binary);
    assert(MessageType.Close != MessageType.Ping);
}

unittest {
    // Test CloseCode values (RFC 6455 Section 7.4)
    assert(CloseCode.Normal == 1000);
    assert(CloseCode.GoingAway == 1001);
    assert(CloseCode.ProtocolError == 1002);
    assert(CloseCode.InternalError == 1011);
}

unittest {
    // Test isValidCloseCode
    assert(isValidCloseCode(CloseCode.Normal));
    assert(isValidCloseCode(CloseCode.GoingAway));
    assert(isValidCloseCode(cast(ushort) 3000));  // Application use
    assert(isValidCloseCode(cast(ushort) 4999));  // Private use

    // Invalid codes
    assert(!isValidCloseCode(CloseCode.NoStatus));       // 1005 reserved
    assert(!isValidCloseCode(CloseCode.AbnormalClosure)); // 1006 reserved
    assert(!isValidCloseCode(CloseCode.TLSHandshake));   // 1015 reserved
    assert(!isValidCloseCode(cast(ushort) 999));          // Below range
    assert(!isValidCloseCode(cast(ushort) 5000));         // Above range
}

unittest {
    // Test Message.fromText factory
    auto msg = Message.fromText("Hello, WebSocket!");
    assert(msg.type == MessageType.Text);
    assert(msg.text == "Hello, WebSocket!");
    assert(msg.isData);
    assert(!msg.isControl);
}

unittest {
    // Test Message.fromBinary factory
    ubyte[] d = [0x00, 0x01, 0x02, 0xFF];
    auto msg = Message.fromBinary(d);
    assert(msg.type == MessageType.Binary);
    assert(msg.data == d);
    assert(msg.isData);
}

unittest {
    // Test Message.fromClose factory
    auto msg = Message.fromClose(CloseCode.Normal, "Goodbye");
    assert(msg.type == MessageType.Close);
    assert(msg.closeCode == CloseCode.Normal);
    assert(msg.closeReason == "Goodbye");
    assert(msg.isControl);

    // Close without reason
    auto msg2 = Message.fromClose(CloseCode.GoingAway);
    assert(msg2.closeCode == CloseCode.GoingAway);
    assert(msg2.closeReason == "");
}

unittest {
    // Test Message.fromPing and fromPong
    ubyte[] payload = [0x01, 0x02, 0x03];
    auto p1 = Message.fromPing(payload);
    assert(p1.type == MessageType.Ping);
    assert(p1.data == payload);
    assert(p1.isControl);

    auto p2 = Message.fromPong(payload);
    assert(p2.type == MessageType.Pong);
    assert(p2.data == payload);
}

unittest {
    // Test empty message properties
    Message empty;
    assert(empty.text == "");
    assert(empty.closeCode == CloseCode.NoStatus);
    assert(empty.closeReason == "");
}

unittest {
    // Test close code extraction (big-endian)
    // 1001 = 0x03E9
    ubyte[] closePayload = [0x03, 0xE9, 'B', 'y', 'e'];
    auto msg = Message(MessageType.Close, closePayload);
    assert(msg.closeCode == CloseCode.GoingAway);
    assert(msg.closeReason == "Bye");
}
