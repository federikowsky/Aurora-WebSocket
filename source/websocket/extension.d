/**
 * WebSocket Extensions - RFC 6455 Section 9 & RFC 7692
 *
 * This module provides support for WebSocket extensions:
 * - IWebSocketExtension interface for implementing extensions
 * - PerMessageDeflate implementation (RFC 7692)
 * - Extension negotiation helpers
 *
 * Example:
 * ---
 * // Enable permessage-deflate compression
 * auto deflate = new PerMessageDeflate();
 * 
 * // During handshake negotiation
 * auto offered = deflate.negotiateOffer(clientExtensions);
 * 
 * // Create connection with extension
 * auto config = WebSocketConfig();
 * config.extensions ~= deflate;
 * auto ws = new WebSocketConnection(stream, config);
 * ---
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 * Standards: RFC 6455 Section 9, RFC 7692
 */
module websocket.extension;

import std.algorithm : canFind, map, splitter, startsWith;
import std.array : array, appender;
import std.conv : to, ConvException;
import std.string : strip;
import std.zlib : Compress, UnCompress, HeaderFormat;

import websocket.protocol : Frame, Opcode, WebSocketException;

// ============================================================================
// EXCEPTIONS
// ============================================================================

/**
 * Exception thrown when WebSocket extension processing fails.
 */
class WebSocketExtensionException : WebSocketException {
    @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// ============================================================================
// EXTENSION INTERFACE
// ============================================================================

/**
 * Interface for WebSocket extensions.
 *
 * Extensions can transform frames before sending and after receiving.
 * They participate in the handshake negotiation process.
 */
interface IWebSocketExtension {
    /**
     * Extension name (e.g., "permessage-deflate").
     */
    @property string name() const @safe nothrow;

    /**
     * Transform a frame before sending.
     *
     * Params:
     *   frame = Frame to transform (may be modified in place)
     *
     * Returns:
     *   Transformed frame (may be same reference)
     */
    Frame transformOutgoing(Frame frame) @safe;

    /**
     * Transform a frame after receiving.
     *
     * Params:
     *   frame = Frame to transform (may be modified in place)
     *
     * Returns:
     *   Transformed frame (may be same reference)
     */
    Frame transformIncoming(Frame frame) @safe;

    /**
     * Generate extension offer for client handshake.
     *
     * Returns:
     *   Extension offer string (e.g., "permessage-deflate; client_max_window_bits")
     */
    string generateOffer() const @safe;

    /**
     * Parse and accept an extension offer during server handshake.
     *
     * Params:
     *   offer = Extension offer string from client
     *
     * Returns:
     *   Response string if accepted, null if rejected
     */
    string acceptOffer(string offer) @safe;

    /**
     * Process server's extension response during client handshake.
     *
     * Params:
     *   response = Extension response from server
     *
     * Returns:
     *   true if response is acceptable, false otherwise
     */
    bool processResponse(string response) @safe;

    /**
     * Reset extension state (e.g., between messages).
     */
    void reset() @safe;
}

// ============================================================================
// PERMESSAGE-DEFLATE EXTENSION (RFC 7692)
// ============================================================================

/**
 * Configuration for permessage-deflate extension.
 */
struct PerMessageDeflateConfig {
    /// Server's LZ77 sliding window size (8-15, 0 = use default 15)
    ubyte serverMaxWindowBits = 15;

    /// Client's LZ77 sliding window size (8-15, 0 = use default 15)
    ubyte clientMaxWindowBits = 15;

    /// Server takes over context (reuse compression context between messages)
    bool serverNoContextTakeover = false;

    /// Client takes over context (reuse compression context between messages)
    bool clientNoContextTakeover = false;

    /// Compression level (1-9, 0 = default)
    int compressionLevel = 6;

    /// Minimum payload size to compress (bytes)
    size_t minCompressSize = 64;
}

/**
 * Per-Message Deflate Extension (RFC 7692).
 *
 * Compresses WebSocket message payloads using the DEFLATE algorithm.
 * Supports:
 * - Per-message compression
 * - Configurable window bits
 * - Context takeover control
 *
 * Example:
 * ---
 * auto config = PerMessageDeflateConfig();
 * config.compressionLevel = 9;  // Maximum compression
 * config.clientNoContextTakeover = true;  // Reset context each message
 *
 * auto deflate = new PerMessageDeflate(config);
 * ---
 */
class PerMessageDeflate : IWebSocketExtension {
    private PerMessageDeflateConfig _config;
    private Compress _compressor;
    private UnCompress _decompressor;
    private bool _negotiated;
    private bool _isClient;

    /// DEFLATE flush marker (0x00 0x00 0xFF 0xFF)
    private static immutable ubyte[] DEFLATE_TAIL = [0x00, 0x00, 0xFF, 0xFF];

    /**
     * Create a new PerMessageDeflate extension.
     *
     * Params:
     *   config = Extension configuration
     *   isClient = Whether this is for client-side (affects window bits usage)
     */
    this(PerMessageDeflateConfig config = PerMessageDeflateConfig.init, bool isClient = false) @safe {
        _config = config;
        _isClient = isClient;
        _negotiated = false;
        initializeCompression();
    }

    @property string name() const @safe nothrow {
        return "permessage-deflate";
    }

    /**
     * Check if extension has been successfully negotiated.
     */
    @property bool negotiated() const @safe nothrow {
        return _negotiated;
    }

    Frame transformOutgoing(Frame frame) @trusted {
        if (!_negotiated) return frame;

        // Only compress data frames
        if (frame.opcode != Opcode.Text && frame.opcode != Opcode.Binary) {
            return frame;
        }

        // Don't compress small payloads
        if (frame.payload.length < _config.minCompressSize) {
            return frame;
        }

        // Compress payload
        auto compressed = compressPayload(frame.payload);

        // Only use compression if it actually reduces size
        if (compressed.length < frame.payload.length) {
            frame.payload = compressed;
            frame.rsv1 = true;  // RSV1 indicates compression
        }

        // Reset context if configured
        if ((_isClient && _config.clientNoContextTakeover) ||
            (!_isClient && _config.serverNoContextTakeover)) {
            resetCompressor();
        }

        return frame;
    }

    Frame transformIncoming(Frame frame) @trusted {
        if (!_negotiated) return frame;

        // Only decompress data frames with RSV1 set
        if (!frame.rsv1) return frame;
        if (frame.opcode != Opcode.Text && frame.opcode != Opcode.Binary &&
            frame.opcode != Opcode.Continuation) {
            return frame;
        }

        // Decompress payload
        frame.payload = decompressPayload(frame.payload);
        frame.rsv1 = false;  // Clear RSV1 after decompression

        // Reset context if configured
        if ((_isClient && _config.serverNoContextTakeover) ||
            (!_isClient && _config.clientNoContextTakeover)) {
            resetDecompressor();
        }

        return frame;
    }

    string generateOffer() const @safe {
        auto offer = appender!string();
        offer ~= "permessage-deflate";

        if (_config.serverMaxWindowBits != 15 && _config.serverMaxWindowBits >= 8) {
            offer ~= "; server_max_window_bits=";
            offer ~= _config.serverMaxWindowBits.to!string;
        }

        if (_config.clientMaxWindowBits != 15 && _config.clientMaxWindowBits >= 8) {
            offer ~= "; client_max_window_bits=";
            offer ~= _config.clientMaxWindowBits.to!string;
        }

        if (_config.serverNoContextTakeover) {
            offer ~= "; server_no_context_takeover";
        }

        if (_config.clientNoContextTakeover) {
            offer ~= "; client_no_context_takeover";
        }

        return offer.data;
    }

    string acceptOffer(string offer) @safe {
        if (!offer.startsWith("permessage-deflate")) {
            return null;  // Not for us
        }

        // Parse offer parameters
        auto params = parseExtensionParams(offer);

        // Build response
        auto response = appender!string();
        response ~= "permessage-deflate";

        // Handle server_max_window_bits
        if ("server_max_window_bits" in params) {
            auto bits = parseWindowBits(params["server_max_window_bits"]);
            if (bits == 0) return null;  // Invalid
            response ~= "; server_max_window_bits=";
            response ~= bits.to!string;
        }

        // Handle client_max_window_bits
        if ("client_max_window_bits" in params) {
            auto val = params["client_max_window_bits"];
            if (val.length == 0) {
                // Client advertises support, we can set a value
                response ~= "; client_max_window_bits=";
                response ~= _config.clientMaxWindowBits.to!string;
            } else {
                auto bits = parseWindowBits(val);
                if (bits == 0) return null;  // Invalid
                response ~= "; client_max_window_bits=";
                response ~= bits.to!string;
            }
        }

        // Handle context takeover
        if ("server_no_context_takeover" in params) {
            response ~= "; server_no_context_takeover";
            _config.serverNoContextTakeover = true;
        }

        if ("client_no_context_takeover" in params) {
            response ~= "; client_no_context_takeover";
            _config.clientNoContextTakeover = true;
        }

        _negotiated = true;
        initializeCompression();
        return response.data;
    }

    bool processResponse(string response) @safe {
        if (!response.startsWith("permessage-deflate")) {
            return false;
        }

        auto params = parseExtensionParams(response);

        // Process server_max_window_bits
        if ("server_max_window_bits" in params) {
            auto bits = parseWindowBits(params["server_max_window_bits"]);
            if (bits == 0) return false;
            _config.serverMaxWindowBits = bits;
        }

        // Process client_max_window_bits
        if ("client_max_window_bits" in params) {
            auto bits = parseWindowBits(params["client_max_window_bits"]);
            if (bits == 0) return false;
            _config.clientMaxWindowBits = bits;
        }

        // Process context takeover
        if ("server_no_context_takeover" in params) {
            _config.serverNoContextTakeover = true;
        }

        if ("client_no_context_takeover" in params) {
            _config.clientNoContextTakeover = true;
        }

        _negotiated = true;
        initializeCompression();
        return true;
    }

    void reset() @safe {
        // Called between messages if needed
    }

    // ────────────────────────────────────────────────────────
    // Private Implementation
    // ────────────────────────────────────────────────────────

    private void initializeCompression() @trusted {
        // Use raw deflate format (no zlib header) per RFC 7692
        _compressor = new Compress(_config.compressionLevel, HeaderFormat.deflate);
        _decompressor = new UnCompress(HeaderFormat.deflate);
    }

    private void resetCompressor() @trusted {
        _compressor = new Compress(_config.compressionLevel, HeaderFormat.deflate);
    }

    private void resetDecompressor() @trusted {
        _decompressor = new UnCompress(HeaderFormat.deflate);
    }

    private ubyte[] compressPayload(const(ubyte)[] data) @trusted {
        // Compress data
        auto compressed = cast(ubyte[]) _compressor.compress(data);
        compressed ~= cast(ubyte[]) _compressor.flush();

        // Remove DEFLATE tail (0x00 0x00 0xFF 0xFF) per RFC 7692
        if (compressed.length >= 4 && compressed[$ - 4 .. $] == DEFLATE_TAIL) {
            compressed = compressed[0 .. $ - 4];
        }

        return compressed;
    }

    private ubyte[] decompressPayload(const(ubyte)[] data) @trusted {
        // Add DEFLATE tail back for decompression
        ubyte[] withTail = data.dup ~ DEFLATE_TAIL;

        // Decompress
        auto decompressed = cast(ubyte[]) _decompressor.uncompress(withTail);
        decompressed ~= cast(ubyte[]) _decompressor.flush();

        return decompressed;
    }
}

// ============================================================================
// EXTENSION NEGOTIATION HELPERS
// ============================================================================

/**
 * Parse extension parameters from header value.
 *
 * Example input: "permessage-deflate; server_max_window_bits=10; client_no_context_takeover"
 *
 * Params:
 *   extension = Extension header value
 *
 * Returns:
 *   Associative array of parameter name -> value (empty string for flags)
 */
string[string] parseExtensionParams(string extension) pure @safe {
    string[string] params;

    // Split by semicolon
    foreach (part; extension.splitter(';')) {
        auto trimmed = part.strip();
        if (trimmed.length == 0) continue;

        // Check for key=value
        auto eqPos = trimmed.canFind('=');
        if (eqPos) {
            auto kv = trimmed.splitter('=');
            auto key = kv.front.strip();
            kv.popFront();
            auto value = kv.empty ? "" : kv.front.strip();
            params[key] = value;
        } else {
            // Flag parameter (no value)
            params[trimmed] = "";
        }
    }

    return params;
}

/**
 * Parse window bits value (8-15).
 *
 * Returns:
 *   Window bits value, or 0 if invalid
 */
ubyte parseWindowBits(string value) pure @safe {
    if (value.length == 0) return 15;  // Default

    try {
        auto bits = value.to!int;
        if (bits >= 8 && bits <= 15) {
            return cast(ubyte) bits;
        }
    } catch (Exception) {
        // Invalid
    }

    return 0;
}

/**
 * Parse Sec-WebSocket-Extensions header into individual extensions.
 *
 * Params:
 *   header = Full Sec-WebSocket-Extensions header value
 *
 * Returns:
 *   Array of individual extension offers
 */
string[] parseExtensionsHeader(string header) pure @safe {
    // Extensions are comma-separated
    return header.splitter(',').map!(e => e.strip()).array();
}

/**
 * Build Sec-WebSocket-Extensions header from extension list.
 *
 * Params:
 *   extensions = Array of extension response strings
 *
 * Returns:
 *   Complete header value
 */
string buildExtensionsHeader(string[] extensions) pure @safe {
    import std.algorithm : joiner;
    import std.conv : to;
    return extensions.joiner(", ").to!string;
}

// ============================================================================
// UNIT TESTS
// ============================================================================

unittest {
    // Test parseExtensionParams
    auto params = parseExtensionParams("permessage-deflate; server_max_window_bits=10; client_no_context_takeover");

    assert("permessage-deflate" in params);
    assert(params["server_max_window_bits"] == "10");
    assert("client_no_context_takeover" in params);
    assert(params["client_no_context_takeover"] == "");
}

unittest {
    // Test parseWindowBits
    assert(parseWindowBits("") == 15);
    assert(parseWindowBits("8") == 8);
    assert(parseWindowBits("15") == 15);
    assert(parseWindowBits("12") == 12);
    assert(parseWindowBits("7") == 0);   // Too small
    assert(parseWindowBits("16") == 0);  // Too large
    assert(parseWindowBits("abc") == 0); // Invalid
}

unittest {
    // Test parseExtensionsHeader
    auto extensions = parseExtensionsHeader("permessage-deflate, x-custom-ext");
    assert(extensions.length == 2);
    assert(extensions[0] == "permessage-deflate");
    assert(extensions[1] == "x-custom-ext");
}

unittest {
    // Test buildExtensionsHeader
    auto header = buildExtensionsHeader(["permessage-deflate", "x-custom"]);
    assert(header == "permessage-deflate, x-custom");
}

unittest {
    // Test PerMessageDeflate creation
    auto config = PerMessageDeflateConfig();
    config.compressionLevel = 6;
    config.minCompressSize = 100;

    auto deflate = new PerMessageDeflate(config, true);
    assert(deflate.name == "permessage-deflate");
    assert(!deflate.negotiated);
}

unittest {
    // Test PerMessageDeflate offer generation
    auto config = PerMessageDeflateConfig();
    config.serverMaxWindowBits = 12;
    config.clientNoContextTakeover = true;

    auto deflate = new PerMessageDeflate(config);
    auto offer = deflate.generateOffer();

    assert(offer.canFind("permessage-deflate"));
    assert(offer.canFind("server_max_window_bits=12"));
    assert(offer.canFind("client_no_context_takeover"));
}

unittest {
    // Test PerMessageDeflate accept offer
    auto deflate = new PerMessageDeflate();
    auto response = deflate.acceptOffer("permessage-deflate; client_max_window_bits");

    assert(response !is null);
    assert(response.canFind("permessage-deflate"));
    assert(deflate.negotiated);
}

unittest {
    // Test PerMessageDeflate reject invalid offer
    auto deflate = new PerMessageDeflate();
    auto response = deflate.acceptOffer("x-custom-extension");

    assert(response is null);
    assert(!deflate.negotiated);
}

unittest {
    // Test PerMessageDeflate process response
    auto deflate = new PerMessageDeflate(PerMessageDeflateConfig.init, true);
    auto accepted = deflate.processResponse("permessage-deflate; server_max_window_bits=12");

    assert(accepted);
    assert(deflate.negotiated);
}

unittest {
    // Test compression/decompression roundtrip
    auto deflate = new PerMessageDeflate();
    deflate.processResponse("permessage-deflate");  // Force negotiated state

    // Create a test frame with compressible data
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.rsv1 = false;
    // Large repetitive data compresses well
    frame.payload = cast(ubyte[]) ("Hello World! " ~ "Hello World! ".dup.replicate(100));

    // Compress
    auto compressed = deflate.transformOutgoing(frame);
    assert(compressed.rsv1 == true, "RSV1 should be set after compression");
    assert(compressed.payload.length < frame.payload.length, "Compressed should be smaller");

    // Decompress
    auto decompressed = deflate.transformIncoming(compressed);
    assert(decompressed.rsv1 == false, "RSV1 should be cleared after decompression");
}

private string replicate(string s, size_t times) pure @safe {
    auto result = appender!string();
    foreach (_; 0 .. times) {
        result ~= s;
    }
    return result.data;
}
