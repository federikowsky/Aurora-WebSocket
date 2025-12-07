/**
 * WebSocket Stream Abstraction
 *
 * This module provides a generic stream interface for WebSocket I/O,
 * decoupling the WebSocket implementation from specific transport layers.
 *
 * The interface supports:
 * - Blocking reads (readExactly)
 * - Non-blocking reads (read)
 * - Blocking writes
 * - Connection state tracking
 *
 * This is a pure interface module - adapters for specific transports
 * (vibe-d, Phobos sockets, etc.) should be implemented by the user.
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 */
module aurora_websocket.stream;

import aurora_websocket.protocol : WebSocketException;

// ============================================================================
// EXCEPTIONS
// ============================================================================

/**
 * Exception thrown when stream I/O fails.
 */
class WebSocketStreamException : WebSocketException {
    @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// ============================================================================
// STREAM INTERFACE
// ============================================================================

/**
 * Generic bidirectional stream interface for WebSocket I/O.
 *
 * This interface abstracts the underlying transport (TCP socket, etc.)
 * to allow the WebSocket implementation to work with any stream type.
 *
 * Blocking Semantics:
 * - `read()`: Non-blocking, returns available data or empty slice
 * - `readExactly()`: Blocks until n bytes available or throws
 * - `write()`: Blocks until all data written or throws
 *
 * Timeouts: Not handled at this level. Use WebSocketConfig.readTimeout
 * for application-level timeout handling.
 *
 * Example implementation for vibe-d (in your application):
 * ---
 * class VibeTCPAdapter : IWebSocketStream {
 *     private TCPConnection _conn;
 *     this(TCPConnection conn) { _conn = conn; }
 *     // ... implement interface methods
 * }
 * ---
 */
interface IWebSocketStream {
    /**
     * Read available data into buffer (non-blocking).
     *
     * Returns immediately with whatever data is available.
     * If no data is available, returns an empty slice.
     *
     * Params:
     *   buffer = Buffer to read into
     *
     * Returns:
     *   Slice of buffer containing read data, or empty if no data ready
     *
     * Throws:
     *   WebSocketStreamException on read error or disconnection
     */
    ubyte[] read(ubyte[] buffer) @safe;

    /**
     * Read exactly n bytes (blocking).
     *
     * Blocks until exactly n bytes are available, then returns them.
     * This is the primary method for reading WebSocket frame headers
     * and payloads where exact byte counts are known.
     *
     * Params:
     *   n = Exact number of bytes to read
     *
     * Returns:
     *   Array of exactly n bytes
     *
     * Throws:
     *   WebSocketStreamException on EOF, disconnection, or timeout
     */
    ubyte[] readExactly(size_t n) @safe;

    /**
     * Write all data (blocking).
     *
     * Blocks until all data is written or an error occurs.
     * Partial writes are not visible to the caller.
     *
     * Params:
     *   data = Data to write
     *
     * Throws:
     *   WebSocketStreamException on write failure or disconnection
     */
    void write(const(ubyte)[] data) @safe;

    /**
     * Flush any buffered data to the wire.
     *
     * Ensures all previously written data is actually sent.
     * May be a no-op for unbuffered transports.
     *
     * Throws:
     *   WebSocketStreamException on flush failure
     */
    void flush() @safe;

    /**
     * Check if the stream is still connected.
     *
     * Returns:
     *   true if the connection is open and usable
     */
    @property bool connected() @safe nothrow;

    /**
     * Close the stream gracefully.
     *
     * After calling close(), connected() will return false.
     * Further read/write operations will throw.
     */
    void close() @safe;
}

// ============================================================================
// MOCK STREAM (for testing)
// ============================================================================

/**
 * Mock stream for testing purposes.
 *
 * Allows setting up expected read data and capturing written data.
 */
class MockWebSocketStream : IWebSocketStream {
    private ubyte[] _readBuffer;
    private size_t _readPos;
    private ubyte[] _writeBuffer;
    private bool _connected = true;

    /**
     * Create a mock stream with predefined read data.
     */
    this(const(ubyte)[] readData = null) @safe {
        _readBuffer = readData.dup;
        _readPos = 0;
    }

    /**
     * Add more data to the read buffer.
     */
    void pushReadData(const(ubyte)[] data) @safe {
        _readBuffer ~= data;
    }

    /**
     * Get all data written to the stream.
     */
    @property const(ubyte)[] writtenData() @safe nothrow {
        return _writeBuffer;
    }

    /**
     * Clear written data buffer.
     */
    void clearWrittenData() @safe nothrow {
        _writeBuffer = null;
    }

    override ubyte[] read(ubyte[] buffer) @safe {
        if (!_connected)
            throw new WebSocketStreamException("Stream is closed");

        if (_readPos >= _readBuffer.length) return [];

        auto available = _readBuffer.length - _readPos;
        auto toRead = available < buffer.length ? available : buffer.length;
        buffer[0 .. toRead] = _readBuffer[_readPos .. _readPos + toRead];
        _readPos += toRead;
        return buffer[0 .. toRead];
    }

    override ubyte[] readExactly(size_t n) @safe {
        if (!_connected)
            throw new WebSocketStreamException("Stream is closed");

        if (n == 0) return [];

        if (_readPos + n > _readBuffer.length)
            throw new WebSocketStreamException("End of stream");

        auto result = _readBuffer[_readPos .. _readPos + n].dup;
        _readPos += n;
        return result;
    }

    override void write(const(ubyte)[] data) @safe {
        if (!_connected)
            throw new WebSocketStreamException("Stream is closed");

        _writeBuffer ~= data;
    }

    override void flush() @safe {
        if (!_connected)
            throw new WebSocketStreamException("Stream is closed");
        // No-op for mock
    }

    override @property bool connected() @safe nothrow {
        return _connected;
    }

    override void close() @safe {
        _connected = false;
    }
}
