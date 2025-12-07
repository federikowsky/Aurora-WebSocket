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
module aurora_websocket.handshake;

import std.algorithm : canFind, map, splitter;
import std.array : array;
import std.ascii : toLower;
import std.base64 : Base64;
import std.digest.sha : SHA1;
import std.string : strip, toLower;
import std.uni : toLower;

import aurora_websocket.protocol : WebSocketException;

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
// CLIENT MODE - KEY GENERATION
// ============================================================================

/**
 * Generate a random Sec-WebSocket-Key for client handshake.
 *
 * The key is 16 random bytes, Base64-encoded (24 characters).
 * This is used when initiating a WebSocket connection as a client.
 *
 * Example:
 * ---
 * auto key = generateSecWebSocketKey();
 * // key is something like "dGhlIHNhbXBsZSBub25jZQ=="
 * ---
 *
 * Returns:
 *   Base64-encoded 16-byte random key
 */
string generateSecWebSocketKey() @trusted {
    import std.random : Random, unpredictableSeed, uniform;
    
    // Generate 16 random bytes
    ubyte[16] randomBytes;
    auto rng = Random(unpredictableSeed);
    foreach (ref b; randomBytes) {
        b = uniform!ubyte(rng);
    }
    
    // Base64 encode
    return Base64.encode(randomBytes[]);
}

// ============================================================================
// CLIENT MODE - UPGRADE REQUEST
// ============================================================================

/**
 * Build HTTP upgrade request for WebSocket client handshake.
 *
 * Example request:
 * ---
 * GET /chat HTTP/1.1
 * Host: server.example.com
 * Upgrade: websocket
 * Connection: Upgrade
 * Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
 * Sec-WebSocket-Version: 13
 * ---
 *
 * Params:
 *   host = Server hostname (for Host header)
 *   path = Request path (e.g., "/chat" or "/")
 *   key = Sec-WebSocket-Key (from generateSecWebSocketKey)
 *   protocols = Optional subprotocols to request
 *   extraHeaders = Optional additional headers (e.g., Origin, cookies)
 *
 * Returns:
 *   Complete HTTP request string
 */
string buildUpgradeRequest(
    string host,
    string path,
    string key,
    string[] protocols = null,
    string[string] extraHeaders = null
) pure @safe {
    import std.array : appender;
    
    // Ensure path starts with /
    if (path.length == 0 || path[0] != '/') {
        path = "/" ~ path;
    }
    
    auto request = appender!string();
    
    // Request line
    request ~= "GET ";
    request ~= path;
    request ~= " HTTP/1.1\r\n";
    
    // Required headers
    request ~= "Host: ";
    request ~= host;
    request ~= "\r\n";
    
    request ~= "Upgrade: websocket\r\n";
    request ~= "Connection: Upgrade\r\n";
    
    request ~= "Sec-WebSocket-Key: ";
    request ~= key;
    request ~= "\r\n";
    
    request ~= "Sec-WebSocket-Version: ";
    request ~= WS_VERSION;
    request ~= "\r\n";
    
    // Optional: subprotocols
    if (protocols !is null && protocols.length > 0) {
        request ~= "Sec-WebSocket-Protocol: ";
        foreach (i, p; protocols) {
            if (i > 0) request ~= ", ";
            request ~= p;
        }
        request ~= "\r\n";
    }
    
    // Extra headers
    if (extraHeaders !is null) {
        foreach (name, value; extraHeaders) {
            request ~= name;
            request ~= ": ";
            request ~= value;
            request ~= "\r\n";
        }
    }
    
    // End of headers
    request ~= "\r\n";
    
    return request.data;
}

// ============================================================================
// CLIENT MODE - RESPONSE VALIDATION
// ============================================================================

/**
 * Result of validating server's upgrade response.
 */
struct ClientUpgradeValidation {
    /// Whether the response is a valid WebSocket upgrade
    bool valid;
    
    /// Error message if not valid
    string error;
    
    /// HTTP status code from response
    int statusCode;
    
    /// Selected subprotocol (if any)
    string protocol;
    
    /// Selected extensions (if any)
    string[] extensions;
}

/**
 * Validate server's HTTP upgrade response for WebSocket client.
 *
 * Checks RFC 6455 Section 4.2.2 requirements:
 * - Status code must be 101
 * - Upgrade: websocket
 * - Connection: Upgrade
 * - Sec-WebSocket-Accept matches expected value
 *
 * Params:
 *   response = Complete HTTP response string
 *   expectedKey = The Sec-WebSocket-Key we sent (to verify accept)
 *
 * Returns:
 *   ClientUpgradeValidation with validation result
 */
ClientUpgradeValidation validateUpgradeResponse(string response, string expectedKey) pure @safe {
    import std.algorithm : findSplit, startsWith;
    import std.conv : to, ConvException;
    
    ClientUpgradeValidation result;
    result.valid = false;
    
    // Parse response into lines
    string[string] headers;
    string statusLine;
    
    auto remaining = response;
    
    // First line is status line
    auto statusSplit = remaining.findSplit("\r\n");
    if (statusSplit[1].length == 0) {
        // Try with just \n
        statusSplit = remaining.findSplit("\n");
    }
    statusLine = statusSplit[0];
    remaining = statusSplit[2];
    
    // Parse status line: "HTTP/1.1 101 Switching Protocols"
    if (!statusLine.startsWith("HTTP/1.1 ") && !statusLine.startsWith("HTTP/1.0 ")) {
        result.error = "Invalid HTTP response";
        return result;
    }
    
    auto statusParts = statusLine[9 .. $].findSplit(" ");
    try {
        result.statusCode = statusParts[0].to!int;
    } catch (ConvException) {
        result.error = "Invalid status code";
        return result;
    }
    
    // Check status code
    if (result.statusCode != 101) {
        result.error = "Expected status 101, got " ~ result.statusCode.to!string;
        return result;
    }
    
    // Parse headers
    while (remaining.length > 0) {
        auto lineSplit = remaining.findSplit("\r\n");
        if (lineSplit[1].length == 0) {
            lineSplit = remaining.findSplit("\n");
        }
        
        auto line = lineSplit[0];
        remaining = lineSplit[2];
        
        // Empty line marks end of headers
        if (line.length == 0) break;
        
        // Parse "Header-Name: value"
        auto colonSplit = line.findSplit(":");
        if (colonSplit[1].length == 0) continue;  // Malformed header
        
        auto headerName = colonSplit[0].strip().toLower();
        auto headerValue = colonSplit[2].strip();
        headers[headerName] = headerValue;
    }
    
    // Check Upgrade header
    auto upgradeHeader = "upgrade" in headers;
    if (upgradeHeader is null || (*upgradeHeader).toLower() != "websocket") {
        result.error = "Missing or invalid Upgrade header";
        return result;
    }
    
    // Check Connection header
    auto connectionHeader = "connection" in headers;
    if (connectionHeader is null) {
        result.error = "Missing Connection header";
        return result;
    }
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
    
    // Check Sec-WebSocket-Accept
    auto acceptHeader = "sec-websocket-accept" in headers;
    if (acceptHeader is null) {
        result.error = "Missing Sec-WebSocket-Accept header";
        return result;
    }
    
    auto expectedAccept = computeAcceptKey(expectedKey);
    if (*acceptHeader != expectedAccept) {
        result.error = "Sec-WebSocket-Accept mismatch";
        return result;
    }
    
    // Extract optional subprotocol
    auto protocolHeader = "sec-websocket-protocol" in headers;
    if (protocolHeader !is null) {
        result.protocol = *protocolHeader;
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
// SUBPROTOCOL NEGOTIATION
// ============================================================================

/**
 * Select a subprotocol from client's requested list that the server supports.
 *
 * Subprotocol negotiation (RFC 6455 Section 1.9):
 * - Client sends list of supported protocols in Sec-WebSocket-Protocol header
 * - Server selects one (or none) and echoes it back
 * - Selection should prefer earlier protocols in server's list (server priority)
 *
 * Example:
 * ---
 * // Server supports graphql-ws and json protocols
 * string[] serverProtocols = ["graphql-ws", "json"];
 * 
 * // Client requests json and xml
 * string[] clientProtocols = ["json", "xml"];
 * 
 * auto selected = selectSubprotocol(serverProtocols, clientProtocols);
 * assert(selected == "json");  // First server-supported match
 * ---
 *
 * Params:
 *   serverProtocols = Protocols supported by the server (in order of preference)
 *   clientProtocols = Protocols requested by the client
 *
 * Returns:
 *   Selected protocol string, or null if no match
 */
string selectSubprotocol(const string[] serverProtocols, const string[] clientProtocols) pure @safe nothrow {
    if (serverProtocols.length == 0 || clientProtocols.length == 0) {
        return null;
    }
    
    // Server priority: iterate server's list first
    foreach (serverProto; serverProtocols) {
        foreach (clientProto; clientProtocols) {
            if (serverProto == clientProto) {
                return serverProto;
            }
        }
    }
    
    return null;
}

/**
 * Validate a selected subprotocol against requested protocols.
 *
 * Used by clients to verify the server selected a valid protocol.
 *
 * Params:
 *   selected = Protocol selected by server (from Sec-WebSocket-Protocol response)
 *   requested = Protocols we requested
 *
 * Returns:
 *   true if the selected protocol is valid (was in our request list)
 */
bool validateSelectedSubprotocol(string selected, const string[] requested) pure @safe nothrow {
    if (selected is null || selected.length == 0) {
        return true;  // No protocol selected is valid
    }
    
    foreach (proto; requested) {
        if (proto == selected) {
            return true;
        }
    }
    
    return false;  // Server selected a protocol we didn't request
}

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
