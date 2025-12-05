/**
 * WebSocket Connection - High-level Connection Management
 *
 * This module provides the main user-facing API for WebSocket communication:
 * - WebSocketConnection class for server-side connections
 * - Message sending (text, binary, ping, pong, close)
 * - Message receiving with automatic fragment reassembly
 * - Automatic ping/pong handling
 * - Clean close handshake
 *
 * Example:
 * ---
 * // In an Aurora handler
 * void handleWebSocket(Request req, HijackedConnection conn) {
 *     auto stream = new VibeTCPAdapter(conn.tcpConnection);
 *     auto validation = validateUpgradeRequest(req.method, req.headers);
 *
 *     if (!validation.valid) {
 *         conn.write(buildBadRequestResponse(validation.error));
 *         return;
 *     }
 *
 *     conn.write(buildUpgradeResponse(validation.clientKey));
 *
 *     auto ws = new WebSocketConnection(stream);
 *     scope(exit) ws.close();
 *
 *     while (ws.connected) {
 *         auto msg = ws.receive();
 *         if (msg.type == MessageType.Text) {
 *             ws.send("Echo: " ~ msg.text);
 *         }
 *     }
 * }
 * ---
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 * Standards: RFC 6455
 */
module websocket.connection;

import core.time : Duration, seconds, MonoTime;

import websocket.message;
import websocket.protocol : Opcode, Frame, encodeFrame, decodeFrame, decodeFrameZeroCopy,
    applyMask, generateMaskKey, isControlOpcode, WebSocketException, WebSocketProtocolException;
import websocket.stream;

// ============================================================================
// EXCEPTIONS
// ============================================================================

/**
 * Exception thrown when operating on a closed WebSocket connection.
 */
class WebSocketClosedException : WebSocketException {
    /// Close code from the close frame
    CloseCode code;

    /// Close reason from the close frame
    string reason;

    @safe pure nothrow this(
        CloseCode code,
        string reason,
        string file = __FILE__,
        size_t line = __LINE__
    ) {
        this.code = code;
        this.reason = reason;
        super("WebSocket connection closed: " ~ reasonText(code, reason), file, line);
    }

    private static string reasonText(CloseCode code, string reason) pure nothrow @safe {
        import std.conv : to;
        if (reason.length > 0)
            return reason;
        return "code " ~ (cast(int) code).to!string;
    }
}

// ============================================================================
// CONFIGURATION
// ============================================================================

/**
 * Connection mode for WebSocket.
 *
 * Determines masking behavior:
 * - Server mode: send unmasked, receive masked
 * - Client mode: send masked, receive unmasked
 */
enum ConnectionMode {
    /// Server mode (default): expect masked frames, send unmasked
    server,
    /// Client mode: expect unmasked frames, send masked
    client
}

/**
 * Configuration options for WebSocket connections.
 */
struct WebSocketConfig {
    /// Maximum size of a single frame payload (default: 64KB)
    size_t maxFrameSize = 64 * 1024;

    /// Maximum size of a reassembled message (default: 16MB)
    size_t maxMessageSize = 16 * 1024 * 1024;

    /// Timeout for read operations (0 = no timeout)
    Duration readTimeout = Duration.zero;

    /// Automatically reply to ping frames with matching pong
    bool autoReplyPing = true;

    /// Connection mode: server (default) or client
    ConnectionMode mode = ConnectionMode.server;
    
    /// Subprotocols supported (server) or requested (client)
    string[] subprotocols;
    
    /// Helper property for backward compatibility and internal use
    @property bool serverMode() const pure @safe nothrow {
        return mode == ConnectionMode.server;
    }
}

// ============================================================================
// CONNECTION CLASS
// ============================================================================

/**
 * A WebSocket connection.
 *
 * This class manages a single WebSocket connection, providing high-level
 * methods for sending and receiving messages. It handles:
 *
 * - Frame encoding/decoding
 * - Message fragmentation/reassembly
 * - Automatic ping/pong responses
 * - Close handshake
 *
 * Thread Safety: NOT thread-safe. Use external synchronization if
 * accessing from multiple threads, or use one connection per thread.
 */
class WebSocketConnection {
    private IWebSocketStream _stream;
    private WebSocketConfig _config;
    private bool _connected;
    private bool _closeSent;
    private bool _closeReceived;
    private string _subprotocol;  // Negotiated subprotocol (null if none)

    // Fragment reassembly state
    private Opcode _fragmentOpcode;
    private ubyte[] _fragmentBuffer;

    // Read buffer for streaming frame reads
    private ubyte[] _readBuffer;
    private size_t _readBufferPos;
    
    // Reusable frame buffer (reduces allocations in receiveFrame)
    private ubyte[] _frameBuffer;

    // Heartbeat tracking (manual - no timer)
    private MonoTime _lastPongTime;
    private bool _awaitingPong;
    private uint _pingSequence;  // Sequence number for ping payloads

    /**
     * Create a WebSocket connection from a stream.
     *
     * The stream should already be connected and the HTTP upgrade
     * handshake should already be complete.
     *
     * Params:
     *   stream = Connected stream (e.g., VibeTCPAdapter)
     *   config = Connection configuration
     *   negotiatedSubprotocol = Subprotocol agreed during handshake (null if none)
     */
    this(IWebSocketStream stream, WebSocketConfig config = WebSocketConfig.init, string negotiatedSubprotocol = null) @safe {
        _stream = stream;
        _config = config;
        _connected = stream.connected;
        _closeSent = false;
        _closeReceived = false;
        _subprotocol = negotiatedSubprotocol;
        _readBuffer = new ubyte[](4096);  // Initial read buffer
        _readBufferPos = 0;
        
        // Heartbeat initialization
        _awaitingPong = false;
        _pingSequence = 0;
        _lastPongTime = MonoTime.currTime;
    }

    // ─────────────────────────────────────────────
    // Connection State
    // ─────────────────────────────────────────────

    /**
     * Check if the connection is still open.
     *
     * Returns false after close handshake completes or on error.
     */
    @property bool connected() @safe nothrow {
        return _connected && !_closeReceived && _stream.connected;
    }

    /**
     * Get the underlying stream.
     *
     * For advanced use cases only.
     */
    @property IWebSocketStream stream() @safe nothrow {
        return _stream;
    }

    /**
     * Get the negotiated subprotocol.
     *
     * Returns the subprotocol agreed upon during the WebSocket handshake,
     * or null if no subprotocol was negotiated.
     *
     * Example:
     * ---
     * auto ws = WebSocketClient.connectWithProtocols("ws://localhost/", ["graphql-ws", "json"]);
     * if (ws.subprotocol == "graphql-ws") {
     *     // Use GraphQL over WebSocket protocol
     * }
     * ---
     */
    @property string subprotocol() const @safe nothrow {
        return _subprotocol;
    }

    // ─────────────────────────────────────────────
    // Heartbeat Management (Manual)
    // ─────────────────────────────────────────────

    /**
     * Check if we're waiting for a pong response.
     *
     * Useful for implementing your own heartbeat mechanism.
     */
    @property bool awaitingPong() const @safe nothrow {
        return _awaitingPong;
    }

    /**
     * Get time since last pong was received.
     *
     * Useful for monitoring connection health and implementing
     * your own heartbeat timeout logic.
     *
     * Returns:
     *   Duration since last pong was received
     */
    @property Duration timeSinceLastPong() const @safe nothrow {
        return MonoTime.currTime - _lastPongTime;
    }

    /**
     * Reset pong tracking.
     *
     * Call this after receiving a pong or when starting fresh.
     */
    void resetPongTracking() @safe nothrow {
        _lastPongTime = MonoTime.currTime;
        _awaitingPong = false;
    }

    // ─────────────────────────────────────────────
    // Sending Messages
    // ─────────────────────────────────────────────

    /**
     * Send a text message.
     *
     * Params:
     *   text = UTF-8 text to send
     *
     * Throws:
     *   WebSocketClosedException if connection is closed
     *   WebSocketStreamException on I/O error
     */
    void send(string text) @safe {
        sendMessage(MessageType.Text, cast(const(ubyte)[]) text);
    }

    /**
     * Send a binary message.
     *
     * Params:
     *   data = Binary data to send
     *
     * Throws:
     *   WebSocketClosedException if connection is closed
     *   WebSocketStreamException on I/O error
     */
    void send(const(ubyte)[] data) @safe {
        sendMessage(MessageType.Binary, data);
    }

    /**
     * Send a ping frame.
     *
     * The remote end should respond with a pong containing the same payload.
     * Use this for implementing keep-alive/heartbeat mechanisms.
     *
     * Params:
     *   data = Optional payload (max 125 bytes)
     *
     * Throws:
     *   WebSocketProtocolException if payload > 125 bytes
     */
    void ping(const(ubyte)[] data = null) @safe {
        enforceConnected();

        Frame frame;
        frame.fin = true;
        frame.opcode = Opcode.Ping;
        frame.masked = !_config.serverMode;
        if (frame.masked) frame.maskKey = generateMaskKey();
        frame.payload = data.dup;

        sendFrameInternal(frame);
        _awaitingPong = true;
        _pingSequence++;
    }

    /**
     * Send a pong frame.
     *
     * Usually sent automatically in response to ping (if autoReplyPing is true).
     *
     * Params:
     *   data = Payload (should match received ping)
     */
    void pong(const(ubyte)[] data = null) @safe {
        enforceConnected();

        Frame frame;
        frame.fin = true;
        frame.opcode = Opcode.Pong;
        frame.masked = !_config.serverMode;
        if (frame.masked) frame.maskKey = generateMaskKey();
        frame.payload = data.dup;

        sendFrameInternal(frame);
    }

    /**
     * Initiate connection close.
     *
     * Sends a close frame and waits for the close response.
     * After this method returns, connected() will be false.
     *
     * Params:
     *   code = Close status code
     *   reason = Optional close reason (max ~123 bytes)
     */
    void close(CloseCode code = CloseCode.Normal, string reason = "") @trusted {
        if (_closeSent) return;  // Already closing

        // Build close payload
        ubyte[] payload;
        if (code != CloseCode.NoStatus) {
            payload = new ubyte[](2 + reason.length);
            payload[0] = cast(ubyte)(code >> 8);
            payload[1] = cast(ubyte)(code & 0xFF);
            if (reason.length > 0) {
                payload[2 .. $] = cast(ubyte[]) reason;
            }
        }

        // Send close frame
        Frame frame;
        frame.fin = true;
        frame.opcode = Opcode.Close;
        frame.masked = !_config.serverMode;
        if (frame.masked) frame.maskKey = generateMaskKey();
        frame.payload = payload;

        try {
            sendFrameInternal(frame);
            _closeSent = true;

            // Wait for close response (with timeout)
            if (!_closeReceived) {
                waitForCloseResponse();
            }
        } catch (Exception) {
            // Ignore errors during close
        }

        _connected = false;
        _stream.close();
    }

    // ─────────────────────────────────────────────
    // Receiving Messages
    // ─────────────────────────────────────────────

    /**
     * Receive the next message (blocking).
     *
     * Blocks until a complete message is received or the connection closes.
     * Handles:
     * - Fragment reassembly (multiple frames → single message)
     * - Automatic pong response to ping (if autoReplyPing is true)
     * - Close handshake
     *
     * Returns:
     *   The received message
     *
     * Throws:
     *   WebSocketClosedException if connection closed
     *   WebSocketProtocolException on protocol error
     *   WebSocketStreamException on I/O error
     */
    Message receive() @safe {
        enforceConnected();

        while (true) {
            auto frame = receiveFrame();

            // Handle control frames
            if (isControlOpcode(frame.opcode)) {
                if (handleControlFrame(frame)) {
                    // Close frame received
                    throw new WebSocketClosedException(
                        parseCloseCode(frame.payload),
                        parseCloseReason(frame.payload)
                    );
                }
                continue;  // Control frames don't produce messages
            }

            // Handle data frames
            return handleDataFrame(frame);
        }
    }

    /**
     * Receive the next frame (low-level).
     *
     * For advanced use cases. Most users should use receive().
     *
     * Returns:
     *   The received frame
     *
     * Throws:
     *   WebSocketStreamException on I/O error
     *   WebSocketProtocolException on invalid frame
     */
    Frame receiveFrame() @safe {
        enforceConnected();

        // Read frame from stream
        // First, read minimum header (2 bytes)
        auto header = _stream.readExactly(2);

        // Parse initial header to determine full header size
        bool masked = (header[1] & 0x80) != 0;
        ubyte lenByte = header[1] & 0x7F;

        size_t extendedLen = 0;
        if (lenByte == 126) {
            extendedLen = 2;
        } else if (lenByte == 127) {
            extendedLen = 8;
        }

        size_t maskKeyLen = masked ? 4 : 0;

        // Read extended header if needed
        ubyte[] extHeader;
        if (extendedLen + maskKeyLen > 0) {
            extHeader = _stream.readExactly(extendedLen + maskKeyLen);
        }

        // Calculate payload length
        size_t payloadLen;
        if (lenByte <= 125) {
            payloadLen = lenByte;
        } else if (lenByte == 126) {
            payloadLen = (cast(size_t) extHeader[0] << 8) | extHeader[1];
        } else {
            payloadLen = 0;
            foreach (i; 0 .. 8) {
                payloadLen = (payloadLen << 8) | extHeader[i];
            }
        }

        // Enforce size limits
        if (payloadLen > _config.maxFrameSize) {
            throw new WebSocketProtocolException("Frame payload too large");
        }

        // Read payload
        ubyte[] payload;
        if (payloadLen > 0) {
            payload = _stream.readExactly(payloadLen);
        }

        // Build complete frame data for decoding
        // Use internal buffer to reduce allocations
        size_t frameSize = 2 + extendedLen + maskKeyLen + payloadLen;
        if (_frameBuffer.length < frameSize) {
            _frameBuffer = new ubyte[](frameSize * 2);  // Grow with headroom
        }
        
        _frameBuffer[0 .. 2] = header[];
        if (extHeader.length > 0) {
            _frameBuffer[2 .. 2 + extHeader.length] = extHeader[];
        }
        if (payload.length > 0) {
            _frameBuffer[2 + extendedLen + maskKeyLen .. 2 + extendedLen + maskKeyLen + payloadLen] = payload[];
        }

        // Use zero-copy decode (unmasks in-place, returns slice)
        auto result = decodeFrameZeroCopy(_frameBuffer[0 .. frameSize], _config.serverMode);
        if (!result.success) {
            throw new WebSocketProtocolException("Incomplete frame");
        }

        // Copy payload since buffer will be reused
        // This is still faster than decodeFrame because we avoid one allocation
        if (result.frame.payload.length > 0) {
            result.frame.payload = result.frame.payload.dup;
        }

        return result.frame;
    }

    // ─────────────────────────────────────────────
    // Private Implementation
    // ─────────────────────────────────────────────

    private void enforceConnected() @safe {
        if (!connected) {
            throw new WebSocketClosedException(CloseCode.AbnormalClosure, "Connection closed");
        }
    }

    private void sendMessage(MessageType type, const(ubyte)[] data) @safe {
        enforceConnected();

        // For now, send as single frame (no fragmentation)
        // TODO: Implement fragmentation for large messages
        Frame frame;
        frame.fin = true;
        frame.opcode = (type == MessageType.Text) ? Opcode.Text : Opcode.Binary;
        frame.masked = !_config.serverMode;
        if (frame.masked) frame.maskKey = generateMaskKey();
        frame.payload = data.dup;

        sendFrameInternal(frame);
    }

    private void sendFrameInternal(Frame frame) @safe {
        auto encoded = encodeFrame(frame);
        _stream.write(encoded);
        _stream.flush();
    }

    /**
     * Handle a control frame.
     *
     * Returns: true if Close frame was received
     */
    private bool handleControlFrame(Frame frame) @safe {
        switch (frame.opcode) {
            case Opcode.Ping:
                if (_config.autoReplyPing) {
                    pong(frame.payload);
                }
                return false;

            case Opcode.Pong:
                // Track pong for heartbeat mechanism
                _lastPongTime = MonoTime.currTime;
                _awaitingPong = false;
                return false;

            case Opcode.Close:
                _closeReceived = true;

                // If we haven't sent close yet, echo it back
                if (!_closeSent) {
                    Frame closeFrame;
                    closeFrame.fin = true;
                    closeFrame.opcode = Opcode.Close;
                    closeFrame.masked = !_config.serverMode;
                    if (closeFrame.masked) closeFrame.maskKey = generateMaskKey();
                    closeFrame.payload = frame.payload.dup;

                    try {
                        sendFrameInternal(closeFrame);
                    } catch (Exception) {
                        // Ignore errors during close response
                    }
                    _closeSent = true;
                }

                _connected = false;
                return true;

            default:
                return false;
        }
    }

    /**
     * Handle a data frame, performing fragment reassembly.
     *
     * Returns: Complete message, or continues waiting for more fragments
     */
    private Message handleDataFrame(Frame frame) @safe {
        // Check for message size limits
        if (_fragmentBuffer.length + frame.payload.length > _config.maxMessageSize) {
            throw new WebSocketProtocolException("Message too large");
        }

        // Track if we're in a fragmented message using _fragmentOpcode
        // _fragmentOpcode == Continuation means "not in a fragmented message"
        bool inFragmentedMessage = (_fragmentOpcode != Opcode.Continuation);

        if (frame.opcode == Opcode.Continuation) {
            // Continuation frame - must be in a fragmented message
            if (!inFragmentedMessage) {
                throw new WebSocketProtocolException("Unexpected continuation frame");
            }
            _fragmentBuffer ~= frame.payload;
        } else {
            // New message (Text or Binary) - must NOT be in a fragmented message
            if (inFragmentedMessage) {
                throw new WebSocketProtocolException("Expected continuation frame");
            }
            _fragmentOpcode = frame.opcode;
            _fragmentBuffer = frame.payload.dup;
        }

        // Check if message is complete
        if (frame.fin) {
            auto msgType = (_fragmentOpcode == Opcode.Text)
                ? MessageType.Text
                : MessageType.Binary;

            // RFC 6455 §5.6: Text frames must contain valid UTF-8
            if (msgType == MessageType.Text) {
                if (!isValidUtf8(_fragmentBuffer)) {
                    // Close with 1007 (Invalid Frame Payload Data)
                    closeWithCode(CloseCode.InvalidPayload, "Invalid UTF-8");
                    throw new WebSocketClosedException(CloseCode.InvalidPayload, "Invalid UTF-8 in text message");
                }
            }

            auto msg = Message(msgType, _fragmentBuffer);

            // Reset fragment state
            _fragmentBuffer = null;
            _fragmentOpcode = Opcode.Continuation;

            return msg;
        }

        // Need more fragments - recurse
        return receive();
    }

    /**
     * Validate UTF-8 encoding.
     *
     * RFC 6455 requires text frames to contain valid UTF-8.
     *
     * Performance: Uses word-at-a-time ASCII fast-path. For pure ASCII data
     * (common in JSON, protocols), this is ~8x faster than byte-by-byte.
     *
     * Returns: true if data is valid UTF-8, false otherwise
     */
    private static bool isValidUtf8(const(ubyte)[] data) pure nothrow @trusted @nogc {
        if (data.length == 0) return true;

        size_t i = 0;
        
        // Fast-path: check 8 bytes at a time for pure ASCII
        // ASCII bytes have high bit = 0, so OR of 8 bytes with 0x80808080_80808080
        // will be non-zero if any byte is non-ASCII
        enum ulong ASCII_MASK = 0x8080808080808080UL;
        
        auto data64 = cast(const(ulong)[]) data[0 .. data.length - (data.length & 7)];
        foreach (chunk; data64) {
            if ((chunk & ASCII_MASK) != 0) {
                // Non-ASCII found, switch to byte-by-byte validation
                break;
            }
            i += 8;
        }
        
        // Validate remaining bytes (or all if non-ASCII was found)
        while (i < data.length) {
            ubyte b = data[i];
            size_t seqLen;

            if ((b & 0x80) == 0) {
                // ASCII (0xxxxxxx) - single byte, skip quickly
                i++;
                continue;
            } else if ((b & 0xE0) == 0xC0) {
                // 2-byte sequence (110xxxxx)
                seqLen = 2;
                // Reject overlong encodings (< 0x80)
                if (b < 0xC2) return false;
            } else if ((b & 0xF0) == 0xE0) {
                // 3-byte sequence (1110xxxx)
                seqLen = 3;
            } else if ((b & 0xF8) == 0xF0) {
                // 4-byte sequence (11110xxx)
                seqLen = 4;
                // Reject values > 0x10FFFF
                if (b > 0xF4) return false;
            } else {
                // Invalid leading byte (continuation byte without start, or 5+ byte sequence)
                return false;
            }

            // Check we have enough bytes
            if (i + seqLen > data.length) return false;

            // Validate continuation bytes (10xxxxxx)
            for (size_t j = 1; j < seqLen; j++) {
                if ((data[i + j] & 0xC0) != 0x80) return false;
            }

            // Check for overlong encodings and surrogate pairs
            if (seqLen == 3) {
                uint cp = ((b & 0x0F) << 12) |
                         ((data[i + 1] & 0x3F) << 6) |
                         (data[i + 2] & 0x3F);
                // Reject overlong (< 0x800) and surrogates (0xD800-0xDFFF)
                if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
            } else if (seqLen == 4) {
                uint cp = ((b & 0x07) << 18) |
                         ((data[i + 1] & 0x3F) << 12) |
                         ((data[i + 2] & 0x3F) << 6) |
                         (data[i + 3] & 0x3F);
                // Reject overlong (< 0x10000) and > 0x10FFFF
                if (cp < 0x10000 || cp > 0x10FFFF) return false;
            }

            i += seqLen;
        }
        return true;
    }

    /**
     * Close the connection with a specific close code (internal).
     */
    private void closeWithCode(CloseCode code, string reason = "") @safe {
        if (_closeSent) return;

        Frame frame;
        frame.fin = true;
        frame.opcode = Opcode.Close;
        frame.masked = !_config.serverMode;
        if (frame.masked) frame.maskKey = generateMaskKey();

        // Build close payload: 2-byte code + optional reason
        auto reasonBytes = cast(const(ubyte)[]) reason;
        frame.payload = new ubyte[](2 + reasonBytes.length);
        frame.payload[0] = cast(ubyte)(cast(ushort) code >> 8);
        frame.payload[1] = cast(ubyte)(cast(ushort) code & 0xFF);
        if (reasonBytes.length > 0) {
            frame.payload[2 .. $] = reasonBytes[];
        }

        try {
            sendFrameInternal(frame);
        } catch (Exception) {
            // Ignore errors during close
        }
        _closeSent = true;
        _connected = false;
    }

    private void waitForCloseResponse() @safe {
        // Simple timeout-based wait for close response
        // In production, this should use proper timeout handling
        try {
            for (int i = 0; i < 100 && !_closeReceived; i++) {
                auto frame = receiveFrame();
                if (frame.opcode == Opcode.Close) {
                    _closeReceived = true;
                    break;
                }
            }
        } catch (Exception) {
            // Timeout or error - just close
        }
    }

    private static CloseCode parseCloseCode(const(ubyte)[] payload) pure nothrow @safe @nogc {
        if (payload.length < 2) return CloseCode.NoStatus;
        ushort code = (cast(ushort) payload[0] << 8) | payload[1];
        return cast(CloseCode) code;
    }

    private static string parseCloseReason(const(ubyte)[] payload) pure nothrow @trusted {
        if (payload.length <= 2) return "";
        return cast(string) payload[2 .. $];
    }
}
