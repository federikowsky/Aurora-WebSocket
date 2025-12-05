/**
 * WebSocket Client - High-level Client API
 *
 * This module provides a high-level API for initiating WebSocket connections.
 * 
 * The library is transport-agnostic: you must provide your own IWebSocketStream
 * implementation (e.g., wrapping vibe-d TCP/TLS connections).
 *
 * Example:
 * ---
 * import websocket;
 * import your_app.adapters : VibeTCPAdapter;
 * import vibe.core.net : connectTCP;
 *
 * void main() {
 *     // Create TCP connection and wrap it
 *     auto tcp = connectTCP("localhost", 8080);
 *     auto stream = new VibeTCPAdapter(tcp);
 *
 *     // Connect WebSocket using the stream
 *     auto ws = WebSocketClient.connect(stream, "ws://localhost:8080/chat");
 *     scope(exit) ws.close();
 *
 *     // Send a message
 *     ws.send("Hello, server!");
 *
 *     // Receive response
 *     auto msg = ws.receive();
 *     writeln("Received: ", msg.text);
 * }
 * ---
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 * Standards: RFC 6455
 */
module websocket.client;

import std.algorithm : findSplit, startsWith;
import std.conv : to, ConvException;
import std.exception : enforce;
import std.string : strip;

import websocket.connection;
import websocket.handshake : generateSecWebSocketKey, buildUpgradeRequest, 
                             validateUpgradeResponse, validateSelectedSubprotocol,
                             WebSocketHandshakeException;
import websocket.protocol : WebSocketException;
import websocket.stream;
import websocket.tls : TlsConfig;

// ============================================================================
// EXCEPTIONS
// ============================================================================

/**
 * Exception thrown when WebSocket client connection fails.
 */
class WebSocketClientException : WebSocketException {
    @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// ============================================================================
// URL PARSING
// ============================================================================

/**
 * Parsed WebSocket URL components.
 */
struct WebSocketUrl {
    /// Protocol: "ws" or "wss"
    string scheme;
    
    /// Hostname
    string host;
    
    /// Port number (default: 80 for ws, 443 for wss)
    ushort port;
    
    /// Request path (default: "/")
    string path;
    
    /// Whether the URL is valid
    bool valid;
    
    /// Error message if invalid
    string error;
    
    /// Returns host:port for Host header
    string hostHeader() const pure @safe {
        if ((scheme == "ws" && port == 80) || (scheme == "wss" && port == 443)) {
            return host;
        }
        return host ~ ":" ~ port.to!string;
    }
    
    /// Check if this is a secure WebSocket URL
    bool isSecure() const pure @safe nothrow {
        return scheme == "wss";
    }
}

/**
 * Parse a WebSocket URL.
 *
 * Supports formats:
 * - ws://host/path
 * - ws://host:port/path
 * - wss://host/path (secure)
 * - wss://host:port/path
 *
 * Params:
 *   url = WebSocket URL string
 *
 * Returns:
 *   Parsed URL components
 */
WebSocketUrl parseWebSocketUrl(string url) pure @safe {
    WebSocketUrl result;
    result.valid = false;
    
    // Check scheme
    if (url.startsWith("ws://")) {
        result.scheme = "ws";
        url = url[5 .. $];
        result.port = 80;
    } else if (url.startsWith("wss://")) {
        result.scheme = "wss";
        url = url[6 .. $];
        result.port = 443;
    } else {
        result.error = "URL must start with ws:// or wss://";
        return result;
    }
    
    // Split host:port from path
    auto pathSplit = url.findSplit("/");
    string hostPort = pathSplit[0];
    result.path = "/" ~ pathSplit[2];
    if (result.path == "/") result.path = "/";
    
    // Parse host:port
    auto portSplit = hostPort.findSplit(":");
    result.host = portSplit[0];
    
    if (result.host.length == 0) {
        result.error = "Missing hostname";
        return result;
    }
    
    if (portSplit[1].length > 0) {
        // Custom port specified
        try {
            result.port = portSplit[2].to!ushort;
        } catch (ConvException) {
            result.error = "Invalid port number";
            return result;
        }
    }
    
    result.valid = true;
    return result;
}

// ============================================================================
// WEBSOCKET CLIENT
// ============================================================================

/**
 * High-level WebSocket client.
 *
 * Provides static methods to connect to WebSocket servers using
 * a user-provided IWebSocketStream.
 */
struct WebSocketClient {
    
    /**
     * Connect to a WebSocket server using an existing stream.
     *
     * Performs WebSocket handshake over the provided stream.
     * The caller is responsible for establishing the TCP/TLS connection.
     *
     * Params:
     *   stream = Connected stream (TCP or TLS wrapped)
     *   url = WebSocket URL (used for Host header and path)
     *   config = Connection configuration (mode is automatically set to client)
     *
     * Returns:
     *   Connected WebSocketConnection
     *
     * Throws:
     *   WebSocketClientException on connection failure
     *   WebSocketHandshakeException on handshake failure
     *
     * Example:
     * ---
     * // Using your TCP adapter
     * auto tcp = connectTCP("localhost", 8080);
     * auto stream = new VibeTCPAdapter(tcp);
     * auto ws = WebSocketClient.connect(stream, "ws://localhost:8080/chat");
     * ws.send("Hello!");
     * ws.close();
     * ---
     */
    static WebSocketConnection connect(
        IWebSocketStream stream,
        string url,
        WebSocketConfig config = WebSocketConfig.init
    ) @trusted {
        string[string] noHeaders;
        return connectWithHeaders(stream, url, noHeaders, null, config);
    }
    
    /**
     * Connect to a WebSocket server with custom headers.
     *
     * Params:
     *   stream = Connected stream (TCP or TLS wrapped)
     *   url = WebSocket URL (ws://host:port/path or wss://host:port/path)
     *   extraHeaders = Additional HTTP headers (e.g., Origin, Cookie)
     *   protocols = Subprotocols to negotiate
     *   config = Connection configuration
     *
     * Returns:
     *   Connected WebSocketConnection
     */
    static WebSocketConnection connectWithHeaders(
        IWebSocketStream stream,
        string url,
        string[string] extraHeaders,
        string[] protocols = null,
        WebSocketConfig config = WebSocketConfig.init
    ) @trusted {
        // Parse URL
        auto parsedUrl = parseWebSocketUrl(url);
        if (!parsedUrl.valid) {
            throw new WebSocketClientException("Invalid URL: " ~ parsedUrl.error);
        }
        
        // Force client mode
        config.mode = ConnectionMode.client;
        
        // Generate key for handshake
        string wsKey = generateSecWebSocketKey();
        
        // Build and send upgrade request
        string request = buildUpgradeRequest(
            parsedUrl.hostHeader,
            parsedUrl.path,
            wsKey,
            protocols,
            extraHeaders
        );
        
        try {
            stream.write(cast(const(ubyte)[]) request);
        } catch (Exception e) {
            stream.close();
            throw new WebSocketClientException("Failed to send handshake: " ~ e.msg);
        }
        
        // Read response
        string response = readHttpResponseFromStream(stream);
        
        // Validate response
        auto validation = validateUpgradeResponse(response, wsKey);
        if (!validation.valid) {
            stream.close();
            throw new WebSocketHandshakeException("Handshake failed: " ~ validation.error);
        }
        
        // Validate subprotocol selection
        if (protocols !is null && protocols.length > 0) {
            if (!validateSelectedSubprotocol(validation.protocol, protocols)) {
                stream.close();
                throw new WebSocketHandshakeException(
                    "Server selected invalid subprotocol: " ~ 
                    (validation.protocol is null ? "(none)" : validation.protocol)
                );
            }
        }
        
        // Create WebSocket connection with negotiated subprotocol
        return new WebSocketConnection(stream, config, validation.protocol);
    }
    
    /**
     * Connect with subprotocol negotiation.
     *
     * Params:
     *   stream = Connected stream
     *   url = WebSocket URL
     *   protocols = List of subprotocols to request
     *   config = Connection configuration
     *
     * Returns:
     *   Connected WebSocketConnection
     */
    static WebSocketConnection connectWithProtocols(
        IWebSocketStream stream,
        string url,
        string[] protocols,
        WebSocketConfig config = WebSocketConfig.init
    ) @trusted {
        string[string] noHeaders;
        return connectWithHeaders(stream, url, noHeaders, protocols, config);
    }
}

// ============================================================================
// INTERNAL HELPERS
// ============================================================================

/**
 * Read complete HTTP response from IWebSocketStream.
 *
 * Reads until \r\n\r\n (end of headers).
 */
private string readHttpResponseFromStream(IWebSocketStream stream) @trusted {
    import std.array : appender;
    
    auto response = appender!string();
    int crlfCount = 0;
    
    // Read until we see \r\n\r\n
    while (crlfCount < 4) {
        ubyte[] buf;
        try {
            buf = stream.readExactly(1);
        } catch (Exception e) {
            throw new WebSocketClientException("Connection closed during handshake: " ~ e.msg);
        }
        
        response ~= cast(char) buf[0];
        
        // Track \r\n\r\n sequence
        if ((crlfCount == 0 || crlfCount == 2) && buf[0] == '\r') {
            crlfCount++;
        } else if ((crlfCount == 1 || crlfCount == 3) && buf[0] == '\n') {
            crlfCount++;
        } else {
            crlfCount = 0;
        }
    }
    
    return response.data;
}

// ============================================================================
// UNIT TESTS
// ============================================================================

unittest {
    // Test URL parsing - basic
    auto url = parseWebSocketUrl("ws://localhost/chat");
    assert(url.valid, url.error);
    assert(url.scheme == "ws");
    assert(url.host == "localhost");
    assert(url.port == 80);
    assert(url.path == "/chat");
    assert(!url.isSecure);
}

unittest {
    // Test URL parsing - with port
    auto url = parseWebSocketUrl("ws://localhost:8080/api/ws");
    assert(url.valid, url.error);
    assert(url.host == "localhost");
    assert(url.port == 8080);
    assert(url.path == "/api/ws");
}

unittest {
    // Test URL parsing - wss
    auto url = parseWebSocketUrl("wss://secure.example.com/");
    assert(url.valid, url.error);
    assert(url.scheme == "wss");
    assert(url.host == "secure.example.com");
    assert(url.port == 443);
    assert(url.isSecure);
}

unittest {
    // Test URL parsing - no path
    auto url = parseWebSocketUrl("ws://localhost:9000");
    assert(url.valid, url.error);
    assert(url.path == "/");
}

unittest {
    // Test URL parsing - invalid scheme
    auto url = parseWebSocketUrl("http://localhost/");
    assert(!url.valid);
    assert(url.error == "URL must start with ws:// or wss://");
}

unittest {
    // Test hostHeader
    auto url1 = parseWebSocketUrl("ws://localhost/");
    assert(url1.hostHeader == "localhost");
    
    auto url2 = parseWebSocketUrl("ws://localhost:8080/");
    assert(url2.hostHeader == "localhost:8080");
    
    auto url3 = parseWebSocketUrl("ws://localhost:80/");
    assert(url3.hostHeader == "localhost");  // Default port, omitted
}
