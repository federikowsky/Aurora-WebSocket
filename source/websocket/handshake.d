/**
 * WebSocket Handshake - RFC 6455 Section 4
 *
 * This module implements the WebSocket opening handshake:
 * - Validating HTTP upgrade requests
 * - Computing Sec-WebSocket-Accept key
 * - Building HTTP 101 Switching Protocols responses
 *
 * Example Server Usage:
 * ---
 * // Aurora handler callback
 * void handleWebSocket(Request req, HijackedConnection conn) {
 *     auto validation = validateUpgradeRequest(req.method, req.headers);
 *     if (!validation.valid) {
 *         // Send 400 Bad Request
 *         return;
 *     }
 *
 *     // Send upgrade response
 *     auto response = buildUpgradeResponse(validation.clientKey);
 *     conn.write(cast(ubyte[]) response);
 *
 *     // Now use WebSocket framing...
 * }
 * ---
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 * Standards: RFC 6455 Section 4
 */
module websocket.handshake;

import std.algorithm : canFind, map, splitter;
import std.array : array;
import std.ascii : toLower;
import std.base64 : Base64;
import std.digest.sha : SHA1;
import std.string : strip, toLower;
import std.uni : toLower;

import websocket.protocol : WebSocketException;

// ============================================================================
// EXCEPTIONS
// ============================================================================

/**
 * Exception thrown when WebSocket handshake fails.
 */
class WebSocketHandshakeException : WebSocketException {
    @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// ============================================================================
// CONSTANTS
// ============================================================================

/**
 * WebSocket magic GUID (RFC 6455 Section 1.3).
 *
 * This constant is concatenated with the client's Sec-WebSocket-Key
 * to compute the Sec-WebSocket-Accept response header.
 */
enum WS_MAGIC_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/**
 * Required WebSocket protocol version.
 */
enum WS_VERSION = "13";

// ============================================================================
// ACCEPT KEY COMPUTATION
// ============================================================================

/**
 * Compute Sec-WebSocket-Accept from client's Sec-WebSocket-Key.
 *
 * Algorithm (RFC 6455 Section 4.2.2):
 * 1. Concatenate clientKey with magic GUID
 * 2. SHA-1 hash the concatenation
 * 3. Base64 encode the hash
 *
 * Example:
 * ---
 * // RFC 6455 test vector
 * auto accept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
 * assert(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
 * ---
 *
 * Params:
 *   clientKey = The value of Sec-WebSocket-Key header from client
 *
 * Returns:
 *   Base64-encoded accept key for Sec-WebSocket-Accept header
 */
string computeAcceptKey(string clientKey) pure @safe {
    // Concatenate with magic GUID
    auto combined = clientKey ~ WS_MAGIC_GUID;

    // SHA-1 hash
    SHA1 sha;
    sha.put(cast(const(ubyte)[]) combined);
    auto hash = sha.finish();

    // Base64 encode
    return Base64.encode(hash[]);
}

// ============================================================================
// UPGRADE VALIDATION
// ============================================================================

/**
 * Result of validating a WebSocket upgrade request.
 */
struct UpgradeValidation {
    /// Whether the request is a valid WebSocket upgrade
    bool valid;

    /// Error message if not valid
    string error;

    /// Client's Sec-WebSocket-Key (for computing accept key)
    string clientKey;

    /// Requested subprotocols (Sec-WebSocket-Protocol header)
    string[] protocols;

    /// Requested extensions (Sec-WebSocket-Extensions header)
    string[] extensions;
}

/**
 * Validate an HTTP request as a WebSocket upgrade request.
 *
 * Checks RFC 6455 Section 4.2.1 requirements:
 * - Method must be GET
 * - Host header present
 * - Upgrade: websocket (case-insensitive)
 * - Connection contains "upgrade" (case-insensitive)
 * - Sec-WebSocket-Key present and valid
 * - Sec-WebSocket-Version: 13
 *
 * Params:
 *   method = HTTP method (should be "GET")
 *   headers = HTTP headers (keys should be lowercase)
 *
 * Returns:
 *   UpgradeValidation with validation result and extracted info
 */
UpgradeValidation validateUpgradeRequest(string method, const string[string] headers) pure @safe {
    UpgradeValidation result;
    result.valid = false;

    // Check method
    if (method != "GET") {
        result.error = "Method must be GET";
        return result;
    }

    // Check Host header (required)
    if ("host" !in headers) {
        result.error = "Missing Host header";
        return result;
    }

    // Check Upgrade header (must contain "websocket", case-insensitive)
    auto upgradeHeader = "upgrade" in headers;
    if (upgradeHeader is null) {
        result.error = "Missing Upgrade header";
        return result;
    }
    if ((*upgradeHeader).toLower() != "websocket") {
        result.error = "Upgrade header must be 'websocket'";
        return result;
    }

    // Check Connection header (must contain "upgrade", case-insensitive)
    auto connectionHeader = "connection" in headers;
    if (connectionHeader is null) {
        result.error = "Missing Connection header";
        return result;
    }
    // Connection may be "Upgrade" or "keep-alive, Upgrade" etc.
    bool hasUpgrade = false;
    foreach (part; (*connectionHeader).splitter(',')) {
        if (part.strip().toLower() == "upgrade") {
            hasUpgrade = true;
            break;
        }
    }
    if (!hasUpgrade) {
        result.error = "Connection header must contain 'Upgrade'";
        return result;
    }

    // Check Sec-WebSocket-Key (must be present, 16 bytes base64 = 24 chars)
    auto keyHeader = "sec-websocket-key" in headers;
    if (keyHeader is null) {
        result.error = "Missing Sec-WebSocket-Key header";
        return result;
    }
    result.clientKey = *keyHeader;
    // Basic validation: should be base64, approximately 24 chars for 16 bytes
    if (result.clientKey.length < 20 || result.clientKey.length > 30) {
        result.error = "Invalid Sec-WebSocket-Key length";
        return result;
    }

    // Check Sec-WebSocket-Version (must be 13)
    auto versionHeader = "sec-websocket-version" in headers;
    if (versionHeader is null) {
        result.error = "Missing Sec-WebSocket-Version header";
        return result;
    }
    if (*versionHeader != WS_VERSION) {
        result.error = "Unsupported WebSocket version (must be 13)";
        return result;
    }

    // Extract optional subprotocols
    auto protocolHeader = "sec-websocket-protocol" in headers;
    if (protocolHeader !is null) {
        result.protocols = (*protocolHeader)
            .splitter(',')
            .map!(p => p.strip())
            .array();
    }

    // Extract optional extensions
    auto extensionsHeader = "sec-websocket-extensions" in headers;
    if (extensionsHeader !is null) {
        result.extensions = (*extensionsHeader)
            .splitter(',')
            .map!(e => e.strip())
            .array();
    }

    result.valid = true;
    return result;
}

// ============================================================================
// UPGRADE RESPONSE
// ============================================================================

/**
 * Build HTTP 101 Switching Protocols response for WebSocket upgrade.
 *
 * Example response:
 * ---
 * HTTP/1.1 101 Switching Protocols
 * Upgrade: websocket
 * Connection: Upgrade
 * Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
 * ---
 *
 * Params:
 *   clientKey = Client's Sec-WebSocket-Key (from UpgradeValidation)
 *   protocol = Selected subprotocol (optional)
 *   extensions = Selected extensions (optional)
 *
 * Returns:
 *   Complete HTTP response string (including trailing CRLF)
 */
string buildUpgradeResponse(
    string clientKey,
    string protocol = null,
    string[] extensions = null
) pure @safe {
    import std.array : appender;

    auto response = appender!string();

    // Status line
    response ~= "HTTP/1.1 101 Switching Protocols\r\n";

    // Required headers
    response ~= "Upgrade: websocket\r\n";
    response ~= "Connection: Upgrade\r\n";
    response ~= "Sec-WebSocket-Accept: ";
    response ~= computeAcceptKey(clientKey);
    response ~= "\r\n";

    // Optional: selected subprotocol
    if (protocol !is null && protocol.length > 0) {
        response ~= "Sec-WebSocket-Protocol: ";
        response ~= protocol;
        response ~= "\r\n";
    }

    // Optional: selected extensions
    if (extensions !is null && extensions.length > 0) {
        import std.algorithm : joiner;
        response ~= "Sec-WebSocket-Extensions: ";
        foreach (i, ext; extensions) {
            if (i > 0) response ~= ", ";
            response ~= ext;
        }
        response ~= "\r\n";
    }

    // End of headers
    response ~= "\r\n";

    return response.data;
}

/**
 * Build HTTP 400 Bad Request response for failed handshake.
 *
 * Params:
 *   reason = Error message to include in response body
 *
 * Returns:
 *   Complete HTTP response string
 */
string buildBadRequestResponse(string reason = "Bad Request") pure @safe {
    import std.conv : to;

    auto body_ = "WebSocket handshake failed: " ~ reason;
    return "HTTP/1.1 400 Bad Request\r\n"
         ~ "Content-Type: text/plain\r\n"
         ~ "Content-Length: " ~ body_.length.to!string ~ "\r\n"
         ~ "Connection: close\r\n"
         ~ "\r\n"
         ~ body_;
}

// ============================================================================
// UNIT TESTS
// ============================================================================

unittest {
    // RFC 6455 Section 1.3 test vector
    auto accept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    assert(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
           "computeAcceptKey must match RFC 6455 test vector");
}

unittest {
    // Valid upgrade request
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);
    assert(result.valid, result.error);
    assert(result.clientKey == "dGhlIHNhbXBsZSBub25jZQ==");
}

unittest {
    // Invalid method
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("POST", headers);
    assert(!result.valid);
    assert(result.error == "Method must be GET");
}

unittest {
    // Missing Sec-WebSocket-Version
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";

    auto result = validateUpgradeRequest("GET", headers);
    assert(!result.valid);
    assert(result.error == "Missing Sec-WebSocket-Version header");
}

unittest {
    // Connection header with multiple values
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "keep-alive, Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);
    assert(result.valid, result.error);
}

unittest {
    // Extract subprotocols
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";
    headers["sec-websocket-protocol"] = "chat, superchat";

    auto result = validateUpgradeRequest("GET", headers);
    assert(result.valid);
    assert(result.protocols == ["chat", "superchat"]);
}

unittest {
    // Build basic upgrade response
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==");

    assert(response.canFind("HTTP/1.1 101 Switching Protocols"));
    assert(response.canFind("Upgrade: websocket"));
    assert(response.canFind("Connection: Upgrade"));
    assert(response.canFind("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
    assert(response[$-4 .. $] == "\r\n\r\n");  // Ends with double CRLF
}

unittest {
    // Build response with subprotocol
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==", "chat");

    assert(response.canFind("Sec-WebSocket-Protocol: chat"));
}

unittest {
    // Build response with extensions
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==", null,
                                         ["permessage-deflate", "x-custom"]);

    assert(response.canFind("Sec-WebSocket-Extensions: permessage-deflate, x-custom"));
}
