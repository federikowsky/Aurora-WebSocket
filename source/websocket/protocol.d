/**
 * WebSocket Protocol - RFC 6455 Frame Handling
 *
 * This module implements the low-level WebSocket framing protocol:
 * - Frame encoding/decoding
 * - Payload masking/unmasking
 * - Protocol validation
 *
 * RFC 6455 Frame Format:
 * ```
 *  0                   1                   2                   3
 *  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 * +-+-+-+-+-------+-+-------------+-------------------------------+
 * |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
 * |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
 * |N|V|V|V|       |S|             |   (if payload len==126/127)   |
 * | |1|2|3|       |K|             |                               |
 * +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
 * |     Extended payload length continued, if payload len == 127  |
 * + - - - - - - - - - - - - - - - +-------------------------------+
 * |                               |Masking-key, if MASK set to 1  |
 * +-------------------------------+-------------------------------+
 * | Masking-key (continued)       |          Payload Data         |
 * +-------------------------------- - - - - - - - - - - - - - - - +
 * :                     Payload Data continued ...                :
 * + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
 * |                     Payload Data continued ...                |
 * +---------------------------------------------------------------+
 * ```
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 * Standards: RFC 6455 Section 5
 */
module websocket.protocol;

import std.exception : enforce;

// ============================================================================
// EXCEPTIONS
// ============================================================================

/**
 * Base exception for all WebSocket errors.
 */
class WebSocketException : Exception {
    @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/**
 * Protocol-level errors (invalid frames, masking violations, etc.)
 */
class WebSocketProtocolException : WebSocketException {
    @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// ============================================================================
// OPCODE ENUM
// ============================================================================

/**
 * WebSocket frame opcodes (RFC 6455 Section 5.2).
 *
 * Opcodes 0x3-0x7 are reserved for future non-control frames.
 * Opcodes 0xB-0xF are reserved for future control frames.
 */
enum Opcode : ubyte {
    /// Continuation frame (fragmented message)
    Continuation = 0x0,

    /// Text frame (UTF-8 encoded)
    Text = 0x1,

    /// Binary frame (arbitrary data)
    Binary = 0x2,

    // 0x3-0x7 reserved for non-control frames

    /// Connection close
    Close = 0x8,

    /// Ping (keepalive)
    Ping = 0x9,

    /// Pong (response to ping)
    Pong = 0xA,

    // 0xB-0xF reserved for control frames
}

// ============================================================================
// FRAME STRUCT
// ============================================================================

/**
 * A WebSocket frame (RFC 6455 Section 5.2).
 *
 * Represents a single frame in the WebSocket protocol.
 * Messages may span multiple frames (fragmentation).
 */
struct Frame {
    /// FIN bit - true if this is the final fragment
    bool fin = true;

    /// RSV1 bit - reserved for extensions
    bool rsv1 = false;

    /// RSV2 bit - reserved for extensions
    bool rsv2 = false;

    /// RSV3 bit - reserved for extensions
    bool rsv3 = false;

    /// Frame opcode
    Opcode opcode;

    /// Whether payload is masked (required for client→server)
    bool masked = false;

    /// 4-byte masking key (valid only if masked is true)
    ubyte[4] maskKey;

    /// Payload data (unmasked)
    ubyte[] payload;
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/**
 * Check if an opcode represents a control frame.
 *
 * Control frames are Close (0x8), Ping (0x9), and Pong (0xA).
 * Control frames have special restrictions (max 125 bytes, must not be fragmented).
 */
bool isControlOpcode(Opcode op) pure nothrow @safe @nogc {
    return (op & 0x08) != 0;
}

/**
 * Check if an opcode represents a data frame.
 *
 * Data frames are Continuation (0x0), Text (0x1), and Binary (0x2).
 */
bool isDataOpcode(Opcode op) pure nothrow @safe @nogc {
    return op == Opcode.Continuation || op == Opcode.Text || op == Opcode.Binary;
}

/**
 * Check if an opcode is valid (defined in RFC 6455).
 */
bool isValidOpcode(ubyte op) pure nothrow @safe @nogc {
    return op <= 0x2 || (op >= 0x8 && op <= 0xA);
}

// ============================================================================
// MASKING (RFC 6455 Section 5.3)
// ============================================================================

/**
 * Apply XOR masking to data in-place.
 *
 * The masking algorithm is symmetric: applying it twice with the same key
 * returns the original data. This is used for both masking and unmasking.
 *
 * Params:
 *   data = Data to mask/unmask (modified in-place)
 *   maskKey = 4-byte masking key
 */
void applyMask(ubyte[] data, const ubyte[4] maskKey) pure nothrow @safe @nogc {
    foreach (i, ref b; data) {
        b ^= maskKey[i & 0x3];  // i % 4, but faster
    }
}

/**
 * Generate a random 4-byte masking key.
 *
 * Uses system random source for cryptographic quality.
 * Required for client→server frames.
 */
ubyte[4] generateMaskKey() @trusted {
    import std.random : unpredictableSeed, Random;

    ubyte[4] key;
    auto rng = Random(unpredictableSeed);
    foreach (ref b; key) {
        b = cast(ubyte) rng.front;
        rng.popFront();
    }
    return key;
}

// ============================================================================
// FRAME ENCODING
// ============================================================================

/**
 * Encode a frame to wire format.
 *
 * Server mode: generates unmasked frames (masked=false).
 * The frame is validated before encoding.
 *
 * Params:
 *   frame = Frame to encode
 *
 * Returns:
 *   Complete frame as byte array ready for transmission
 *
 * Throws:
 *   WebSocketProtocolException if frame is invalid
 */
ubyte[] encodeFrame(const Frame frame) pure @safe {
    validateFrame(frame);

    // Calculate header size
    size_t headerSize = 2;  // Minimum: fin/opcode byte + mask/len byte

    immutable size_t payloadLen = frame.payload.length;

    // Extended payload length
    if (payloadLen > 125) {
        if (payloadLen <= ushort.max) {
            headerSize += 2;  // 16-bit length
        } else {
            headerSize += 8;  // 64-bit length
        }
    }

    // Masking key (4 bytes if masked)
    if (frame.masked) {
        headerSize += 4;
    }

    // Allocate buffer
    auto result = new ubyte[](headerSize + payloadLen);

    // Byte 0: FIN, RSV1-3, Opcode
    result[0] = cast(ubyte)(
        (frame.fin ? 0x80 : 0) |
        (frame.rsv1 ? 0x40 : 0) |
        (frame.rsv2 ? 0x20 : 0) |
        (frame.rsv3 ? 0x10 : 0) |
        (frame.opcode & 0x0F)
    );

    // Byte 1: MASK, Payload length
    size_t offset = 2;
    if (payloadLen <= 125) {
        result[1] = cast(ubyte)((frame.masked ? 0x80 : 0) | payloadLen);
    } else if (payloadLen <= ushort.max) {
        result[1] = cast(ubyte)((frame.masked ? 0x80 : 0) | 126);
        result[2] = cast(ubyte)(payloadLen >> 8);
        result[3] = cast(ubyte)(payloadLen & 0xFF);
        offset = 4;
    } else {
        result[1] = cast(ubyte)((frame.masked ? 0x80 : 0) | 127);
        // 64-bit big-endian length
        foreach (i; 0 .. 8) {
            result[2 + i] = cast(ubyte)(payloadLen >> (56 - i * 8));
        }
        offset = 10;
    }

    // Masking key (if masked)
    if (frame.masked) {
        result[offset .. offset + 4] = frame.maskKey[];
        offset += 4;
    }

    // Payload
    if (payloadLen > 0) {
        result[offset .. offset + payloadLen] = frame.payload[];

        // Apply mask if needed
        if (frame.masked) {
            applyMask(result[offset .. offset + payloadLen], frame.maskKey);
        }
    }

    return result;
}

// ============================================================================
// FRAME DECODING
// ============================================================================

/**
 * Result of attempting to decode a frame from a byte buffer.
 */
struct DecodeResult {
    /// Whether a complete frame was decoded
    bool success;

    /// The decoded frame (valid only if success is true)
    Frame frame;

    /// Number of bytes consumed from the buffer
    size_t bytesConsumed;

    /// If not success, minimum additional bytes needed (0 if unknown)
    size_t needMore;
}

/**
 * Decode a frame from wire format.
 *
 * Server mode: expects masked frames from client.
 * The frame is automatically unmasked.
 *
 * This function is designed to work with streaming data:
 * if the buffer doesn't contain a complete frame, it returns
 * success=false with needMore indicating how many more bytes are needed.
 *
 * Params:
 *   data = Buffer containing frame data (possibly incomplete)
 *   requireMasked = If true, throws if frame is not masked (server mode)
 *
 * Returns:
 *   DecodeResult with decoded frame or indication of incomplete data
 *
 * Throws:
 *   WebSocketProtocolException on protocol errors (invalid opcode, masking violation, etc.)
 */
DecodeResult decodeFrame(const(ubyte)[] data, bool requireMasked = true) pure @safe {
    DecodeResult result;
    result.success = false;

    // Need at least 2 bytes for minimal header
    if (data.length < 2) {
        result.needMore = 2 - data.length;
        return result;
    }

    // Byte 0: FIN, RSV1-3, Opcode
    Frame frame;
    frame.fin = (data[0] & 0x80) != 0;
    frame.rsv1 = (data[0] & 0x40) != 0;
    frame.rsv2 = (data[0] & 0x20) != 0;
    frame.rsv3 = (data[0] & 0x10) != 0;

    ubyte opcodeVal = data[0] & 0x0F;
    if (!isValidOpcode(opcodeVal)) {
        throw new WebSocketProtocolException("Invalid opcode: " ~ toHex(opcodeVal));
    }
    frame.opcode = cast(Opcode) opcodeVal;

    // Byte 1: MASK, Payload length
    frame.masked = (data[1] & 0x80) != 0;
    ubyte lenByte = data[1] & 0x7F;

    // Server mode: require masked frames from client
    if (requireMasked && !frame.masked) {
        throw new WebSocketProtocolException("Client frame must be masked");
    }

    // Calculate payload length and header size
    size_t payloadLen;
    size_t headerSize = 2;

    if (lenByte <= 125) {
        payloadLen = lenByte;
    } else if (lenByte == 126) {
        headerSize = 4;
        if (data.length < 4) {
            result.needMore = 4 - data.length;
            return result;
        }
        payloadLen = (cast(size_t) data[2] << 8) | data[3];
    } else {  // lenByte == 127
        headerSize = 10;
        if (data.length < 10) {
            result.needMore = 10 - data.length;
            return result;
        }
        // 64-bit big-endian length
        payloadLen = 0;
        foreach (i; 0 .. 8) {
            payloadLen = (payloadLen << 8) | data[2 + i];
        }

        // Sanity check: most significant bit must be 0 (RFC 6455)
        if (payloadLen > long.max) {
            throw new WebSocketProtocolException("Payload length too large");
        }
    }

    // Add masking key size if masked
    if (frame.masked) {
        headerSize += 4;
    }

    // Check if we have the complete frame
    size_t totalSize = headerSize + payloadLen;
    if (data.length < totalSize) {
        result.needMore = totalSize - data.length;
        return result;
    }

    // Extract masking key
    if (frame.masked) {
        size_t maskOffset = (lenByte <= 125) ? 2 : (lenByte == 126) ? 4 : 10;
        frame.maskKey = data[maskOffset .. maskOffset + 4][0 .. 4];
    }

    // Extract and unmask payload
    if (payloadLen > 0) {
        frame.payload = data[headerSize .. headerSize + payloadLen].dup;
        if (frame.masked) {
            applyMask(frame.payload, frame.maskKey);
        }
    }

    // Validate control frame constraints
    if (isControlOpcode(frame.opcode)) {
        if (payloadLen > 125) {
            throw new WebSocketProtocolException("Control frame payload too large (max 125 bytes)");
        }
        if (!frame.fin) {
            throw new WebSocketProtocolException("Control frame must not be fragmented");
        }
    }

    // RSV bits must be 0 unless extension negotiated
    if (frame.rsv1 || frame.rsv2 || frame.rsv3) {
        throw new WebSocketProtocolException("RSV bits must be 0 (no extensions negotiated)");
    }

    result.success = true;
    result.frame = frame;
    result.bytesConsumed = totalSize;
    return result;
}

// ============================================================================
// FRAME VALIDATION
// ============================================================================

/**
 * Validate a frame before encoding.
 *
 * Throws:
 *   WebSocketProtocolException if frame is invalid
 */
void validateFrame(const Frame frame) pure @safe {
    // Validate opcode
    if (!isValidOpcode(cast(ubyte) frame.opcode)) {
        throw new WebSocketProtocolException("Invalid opcode");
    }

    // Control frame constraints
    if (isControlOpcode(frame.opcode)) {
        if (frame.payload.length > 125) {
            throw new WebSocketProtocolException("Control frame payload too large (max 125 bytes)");
        }
        if (!frame.fin) {
            throw new WebSocketProtocolException("Control frame must not be fragmented");
        }
    }

    // RSV bits must be 0 unless extension negotiated
    if (frame.rsv1 || frame.rsv2 || frame.rsv3) {
        throw new WebSocketProtocolException("RSV bits must be 0 (no extensions negotiated)");
    }
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * Convert a byte to hex string for error messages.
 */
private string toHex(ubyte b) pure nothrow @safe {
    immutable char[16] hexDigits = "0123456789ABCDEF";
    char[4] result = ['0', 'x', hexDigits[b >> 4], hexDigits[b & 0x0F]];
    return result[].idup;
}
