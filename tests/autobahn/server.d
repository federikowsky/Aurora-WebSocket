/**
 * Autobahn Test Suite Server
 *
 * This server implements an echo WebSocket server for testing against
 * the Autobahn|Testsuite (wstest).
 *
 * Run with: dub run --config=autobahn-server
 * Then start wstest against ws://localhost:9001
 *
 * The server echoes:
 * - Text messages back as text
 * - Binary messages back as binary
 * - Responds to ping with pong (automatic)
 * - Handles close frames properly
 *
 * Note: This version uses GC control to avoid InvalidMemoryOperationError
 * during high-concurrency testing with vibe.d fibers.
 */
module tests.autobahn.server;

import std.stdio : writeln, writefln;
import core.time : seconds;
import core.memory : GC;

import vibe.core.core : runTask, sleep;
import vibe.core.net : listenTCP, TCPConnection, TCPListenOptions;

import websocket;

/// Connection handler wrapper that's @safe and nothrow
void safeHandleConnection(TCPConnection conn) nothrow @safe {
    try {
        handleConnectionImpl(conn);
    } catch (Exception e) {
        // Silently handle exceptions to avoid logging overhead
    }
}

void main() {
    writeln("===========================================");
    writeln("   Autobahn Test Server - aurora-websocket");
    writeln("===========================================");
    writeln();
    enum PORT = 9002;  // Changed from 9001 to avoid conflicts
    writefln("Listening on ws://localhost:%d", PORT);
    writeln("Run Autobahn tests with:");
    writeln("  docker run -it --rm \\");
    writeln("    -v $(pwd)/tests/autobahn:/config \\");
    writeln("    -v $(pwd)/tests/autobahn/reports:/reports \\");
    writeln("    --network=host \\");
    writeln("    crossbario/autobahn-testsuite \\");
    writeln("    wstest -m fuzzingclient -s /config/fuzzingclient.json");
    writeln();
    writeln("Press Ctrl+C to stop.");
    writeln();
    
    listenTCP(cast(ushort) PORT, (TCPConnection conn) nothrow @safe {
        safeHandleConnection(conn);
    }, TCPListenOptions.reuseAddress | TCPListenOptions.reusePort);
    
    // Periodic GC collection to avoid buildup
    size_t iteration = 0;
    while (true) {
        sleep(1.seconds);
        iteration++;
        // Run GC every 30 seconds during quiet periods
        if (iteration % 30 == 0) {
            GC.collect();
        }
    }
}

void handleConnectionImpl(TCPConnection conn) @trusted {
    // Use static buffer to avoid GC allocations during handshake
    enum MAX_HANDSHAKE_SIZE = 4096;
    char[MAX_HANDSHAKE_SIZE] requestBuffer;
    size_t requestLen = 0;
    
    // Read HTTP request into pre-allocated buffer
    ubyte[1] buf;
    int crlfCount = 0;
    
    while (crlfCount < 4 && requestLen < MAX_HANDSHAKE_SIZE - 1) {
        if (conn.empty) {
            return;
        }
        try {
            conn.read(buf[]);
        } catch (Exception) {
            return;
        }
        requestBuffer[requestLen++] = cast(char) buf[0];
        
        if ((crlfCount == 0 || crlfCount == 2) && buf[0] == '\r') {
            crlfCount++;
        } else if ((crlfCount == 1 || crlfCount == 3) && buf[0] == '\n') {
            crlfCount++;
        } else {
            crlfCount = 0;
        }
    }
    
    if (requestLen >= MAX_HANDSHAKE_SIZE - 1) {
        // Request too large
        return;
    }
    
    // Parse headers (simplified)
    string[string] headers;
    string request = cast(string) requestBuffer[0 .. requestLen];
    
    foreach (line; request.split("\r\n")[1 .. $]) {
        if (line.length == 0) break;
        auto colonPos = line.indexOf(':');
        if (colonPos > 0) {
            string key = line[0 .. colonPos].strip.toLower;
            string value = line[colonPos + 1 .. $].strip;
            headers[key] = value;
        }
    }
    
    // Validate WebSocket upgrade
    auto validation = validateUpgradeRequest("GET", headers);
    if (!validation.valid) {
        try {
            conn.write(cast(const(ubyte)[]) buildBadRequestResponse(validation.error));
            conn.close();
        } catch (Exception) {}
        return;
    }
    
    // Send upgrade response
    try {
        conn.write(cast(const(ubyte)[]) buildUpgradeResponse(validation.clientKey));
    } catch (Exception) {
        return;
    }
    
    // Create WebSocket connection
    auto stream = new VibeTCPAdapter(conn);
    auto config = WebSocketConfig();
    config.mode = ConnectionMode.server;
    config.autoReplyPing = true;
    config.maxFrameSize = 16 * 1024 * 1024;  // 16MB for large frame tests
    config.maxMessageSize = 64 * 1024 * 1024; // 64MB for fragmentation tests
    
    WebSocketConnection ws;
    try {
        ws = new WebSocketConnection(stream, config);
    } catch (Exception) {
        return;
    }
    
    // Echo loop with error recovery
    scope(exit) closeWsSafe(ws);
    
    echoLoop(ws);
}

/// Safe WebSocket close helper
private void closeWsSafe(WebSocketConnection ws) @trusted nothrow {
    try {
        if (ws !is null && ws.connected) ws.close();
    } catch (Exception) {}
}

/// Separate echo loop to minimize stack/GC pressure
private void echoLoop(WebSocketConnection ws) @trusted {
    while (ws.connected) {
        try {
            auto msg = ws.receive();
            
            final switch (msg.type) {
                case MessageType.Text:
                    ws.send(msg.text);
                    break;
                case MessageType.Binary:
                    ws.send(msg.data);
                    break;
                case MessageType.Close:
                    return;
                case MessageType.Ping:
                case MessageType.Pong:
                    break;
            }
        } catch (WebSocketClosedException e) {
            break;
        } catch (WebSocketProtocolException e) {
            try {
                ws.close(CloseCode.ProtocolError, e.msg);
            } catch (Exception) {}
            break;
        } catch (Exception e) {
            break;
        }
    }
}

private string toLower(string s) {
    import std.ascii : toLower;
    char[] result = new char[](s.length);
    foreach (i, c; s) {
        result[i] = toLower(c);
    }
    return cast(string) result;
}

private string strip(string s) {
    import std.ascii : isWhite;
    size_t start = 0;
    while (start < s.length && isWhite(s[start])) start++;
    size_t end = s.length;
    while (end > start && isWhite(s[end - 1])) end--;
    return s[start .. end];
}

private long indexOf(string s, char c) {
    foreach (i, ch; s) {
        if (ch == c) return i;
    }
    return -1;
}

private string[] split(string s, string delim) {
    string[] result;
    size_t start = 0;
    
    for (size_t i = 0; i <= s.length - delim.length; i++) {
        if (s[i .. i + delim.length] == delim) {
            result ~= s[start .. i];
            start = i + delim.length;
            i = start - 1;
        }
    }
    result ~= s[start .. $];
    return result;
}
