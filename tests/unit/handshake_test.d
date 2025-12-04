/**
 * Unit Tests for websocket.handshake
 *
 * Comprehensive tests for WebSocket handshake validation and response generation.
 */
module unit.handshake_test;

import websocket.handshake;
import std.algorithm : canFind;

// ============================================================================
// computeAcceptKey Tests
// ============================================================================

@("computeAcceptKey matches RFC 6455 Section 1.3 test vector")
unittest {
    // This is the official test vector from RFC 6455
    auto accept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    assert(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

@("computeAcceptKey produces different results for different keys")
unittest {
    auto accept1 = computeAcceptKey("x3JJHMbDL1EzLkh9GBhXDw==");
    auto accept2 = computeAcceptKey("HSmrc0sMlYUkAGmm5OPpG2Hg==");

    assert(accept1 != accept2);
    assert(accept1.length > 0);
    assert(accept2.length > 0);
}

@("computeAcceptKey handles empty key")
unittest {
    // Not valid per spec, but should not crash
    auto accept = computeAcceptKey("");
    assert(accept.length > 0);
}

// ============================================================================
// validateUpgradeRequest Tests - Valid Requests
// ============================================================================

@("validateUpgradeRequest accepts minimal valid request")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);

    assert(result.valid, "Expected valid, got: " ~ result.error);
    assert(result.clientKey == "dGhlIHNhbXBsZSBub25jZQ==");
    assert(result.error == "");
}

@("validateUpgradeRequest accepts case-insensitive Upgrade header")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "WebSocket";  // Mixed case
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);
    assert(result.valid, result.error);
}

@("validateUpgradeRequest accepts Connection header with multiple tokens")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "keep-alive, Upgrade";  // Multiple tokens
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);
    assert(result.valid, result.error);
}

@("validateUpgradeRequest accepts Connection: upgrade (lowercase)")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "upgrade";  // Lowercase
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);
    assert(result.valid, result.error);
}

@("validateUpgradeRequest extracts subprotocols")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";
    headers["sec-websocket-protocol"] = "chat, superchat, json";

    auto result = validateUpgradeRequest("GET", headers);

    assert(result.valid);
    assert(result.protocols.length == 3);
    assert(result.protocols[0] == "chat");
    assert(result.protocols[1] == "superchat");
    assert(result.protocols[2] == "json");
}

@("validateUpgradeRequest extracts extensions")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";
    headers["sec-websocket-extensions"] = "permessage-deflate, x-webkit-deflate-frame";

    auto result = validateUpgradeRequest("GET", headers);

    assert(result.valid);
    assert(result.extensions.length == 2);
    assert(result.extensions[0] == "permessage-deflate");
}

// ============================================================================
// validateUpgradeRequest Tests - Invalid Requests
// ============================================================================

@("validateUpgradeRequest rejects non-GET method")
unittest {
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

@("validateUpgradeRequest rejects missing Host header")
unittest {
    string[string] headers;
    // No host header
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Missing Host header");
}

@("validateUpgradeRequest rejects missing Upgrade header")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    // No upgrade header
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Missing Upgrade header");
}

@("validateUpgradeRequest rejects wrong Upgrade value")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "http/2";  // Wrong value
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Upgrade header must be 'websocket'");
}

@("validateUpgradeRequest rejects missing Connection header")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    // No connection header
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Missing Connection header");
}

@("validateUpgradeRequest rejects Connection without Upgrade")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "keep-alive";  // No Upgrade token
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Connection header must contain 'Upgrade'");
}

@("validateUpgradeRequest rejects missing Sec-WebSocket-Key")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    // No sec-websocket-key
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Missing Sec-WebSocket-Key header");
}

@("validateUpgradeRequest rejects too short Sec-WebSocket-Key")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "short";  // Too short
    headers["sec-websocket-version"] = "13";

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Invalid Sec-WebSocket-Key length");
}

@("validateUpgradeRequest rejects missing Sec-WebSocket-Version")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    // No version

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Missing Sec-WebSocket-Version header");
}

@("validateUpgradeRequest rejects wrong Sec-WebSocket-Version")
unittest {
    string[string] headers;
    headers["host"] = "example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "8";  // Old version

    auto result = validateUpgradeRequest("GET", headers);

    assert(!result.valid);
    assert(result.error == "Unsupported WebSocket version (must be 13)");
}

// ============================================================================
// buildUpgradeResponse Tests
// ============================================================================

@("buildUpgradeResponse generates correct HTTP 101 response")
unittest {
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==");

    assert(response.canFind("HTTP/1.1 101 Switching Protocols\r\n"));
    assert(response.canFind("Upgrade: websocket\r\n"));
    assert(response.canFind("Connection: Upgrade\r\n"));
    assert(response.canFind("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"));
}

@("buildUpgradeResponse ends with double CRLF")
unittest {
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==");

    assert(response.length >= 4);
    assert(response[$ - 4 .. $] == "\r\n\r\n");
}

@("buildUpgradeResponse includes selected subprotocol")
unittest {
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==", "chat");

    assert(response.canFind("Sec-WebSocket-Protocol: chat\r\n"));
}

@("buildUpgradeResponse omits protocol header when null")
unittest {
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==", null);

    assert(!response.canFind("Sec-WebSocket-Protocol:"));
}

@("buildUpgradeResponse omits protocol header when empty")
unittest {
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==", "");

    assert(!response.canFind("Sec-WebSocket-Protocol:"));
}

@("buildUpgradeResponse includes selected extensions")
unittest {
    auto response = buildUpgradeResponse(
        "dGhlIHNhbXBsZSBub25jZQ==",
        null,
        ["permessage-deflate", "x-custom"]
    );

    assert(response.canFind("Sec-WebSocket-Extensions: permessage-deflate, x-custom\r\n"));
}

@("buildUpgradeResponse omits extensions header when null")
unittest {
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==", null, null);

    assert(!response.canFind("Sec-WebSocket-Extensions:"));
}

@("buildUpgradeResponse omits extensions header when empty array")
unittest {
    string[] empty;
    auto response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==", null, empty);

    assert(!response.canFind("Sec-WebSocket-Extensions:"));
}

@("buildUpgradeResponse includes both protocol and extensions")
unittest {
    auto response = buildUpgradeResponse(
        "dGhlIHNhbXBsZSBub25jZQ==",
        "graphql-ws",
        ["permessage-deflate"]
    );

    assert(response.canFind("Sec-WebSocket-Protocol: graphql-ws\r\n"));
    assert(response.canFind("Sec-WebSocket-Extensions: permessage-deflate\r\n"));
}

// ============================================================================
// buildBadRequestResponse Tests
// ============================================================================

@("buildBadRequestResponse generates HTTP 400 response")
unittest {
    auto response = buildBadRequestResponse("Invalid key");

    assert(response.canFind("HTTP/1.1 400 Bad Request\r\n"));
    assert(response.canFind("Content-Type: text/plain\r\n"));
    assert(response.canFind("Connection: close\r\n"));
    assert(response.canFind("WebSocket handshake failed: Invalid key"));
}

@("buildBadRequestResponse includes correct Content-Length")
unittest {
    auto response = buildBadRequestResponse("test");

    // Body is "WebSocket handshake failed: test"
    import std.conv : to;
    auto expectedLen = "WebSocket handshake failed: test".length;
    assert(response.canFind("Content-Length: " ~ expectedLen.to!string ~ "\r\n"));
}

// ============================================================================
// Integration Tests
// ============================================================================

@("Full handshake flow with validation and response")
unittest {
    // Simulate a complete handshake
    string[string] headers;
    headers["host"] = "server.example.com";
    headers["upgrade"] = "websocket";
    headers["connection"] = "Upgrade";
    headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    headers["sec-websocket-version"] = "13";
    headers["sec-websocket-protocol"] = "chat, superchat";

    // Step 1: Validate
    auto validation = validateUpgradeRequest("GET", headers);
    assert(validation.valid);
    assert(validation.protocols == ["chat", "superchat"]);

    // Step 2: Select protocol (server chooses first supported)
    string selectedProtocol = "chat";

    // Step 3: Build response
    auto response = buildUpgradeResponse(validation.clientKey, selectedProtocol);

    assert(response.canFind("HTTP/1.1 101 Switching Protocols"));
    assert(response.canFind("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
    assert(response.canFind("Sec-WebSocket-Protocol: chat"));
}
