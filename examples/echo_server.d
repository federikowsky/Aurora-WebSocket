/**
 * WebSocket Echo Server Example
 *
 * A simple WebSocket echo server using vibe-core.
 * Run with: dub run --single examples/echo_server.d
 *
 * Test with: websocat ws://localhost:8080/
 *  or: wscat -c ws://localhost:8080/
 */
module examples.echo_server;

/+ dub.sdl:
    name "echo_server"
    dependency "websocket" path=".."
    dependency "vibe-core" version="~>2.0"
+/

import vibe.core.core : runTask, runApplication;
import vibe.core.net : listenTCP, TCPConnection;

import websocket;

import std.stdio : writeln, writefln;

void main() {
    // Listen on port 8080
    auto listener = listenTCP(8080, (TCPConnection conn) {
        handleConnection(conn);
    });

    writeln("WebSocket echo server listening on ws://localhost:8080/");
    writeln("Test with: websocat ws://localhost:8080/");
    writeln("Press Ctrl+C to stop.");

    runApplication();
}

void handleConnection(TCPConnection conn) @trusted {
    try {
        // Read HTTP request (simplified - just read until double CRLF)
        string request = readHTTPRequest(conn);
        if (request.length == 0) return;

        // Parse headers
        auto headers = parseHeaders(request);

        // Validate WebSocket upgrade
        auto validation = validateUpgradeRequest("GET", headers);
        if (!validation.valid) {
            writefln("Invalid upgrade: %s", validation.error);
            conn.write(cast(ubyte[]) buildBadRequestResponse(validation.error));
            conn.close();
            return;
        }

        writeln("WebSocket connection accepted!");

        // Send upgrade response
        auto response = buildUpgradeResponse(validation.clientKey);
        conn.write(cast(ubyte[]) response);

        // Create WebSocket connection
        auto stream = new VibeTCPAdapter(conn);
        auto ws = new WebSocketConnection(stream);
        scope(exit) {
            if (ws.connected) ws.close();
        }

        // Echo loop
        while (ws.connected) {
            try {
                auto msg = ws.receive();

                final switch (msg.type) {
                    case MessageType.Text:
                        writefln("Received text: %s", msg.text);
                        ws.send("Echo: " ~ msg.text);
                        break;

                    case MessageType.Binary:
                        writefln("Received binary: %d bytes", msg.data.length);
                        ws.send(msg.data);
                        break;

                    case MessageType.Ping:
                        writeln("Received ping (auto-replied)");
                        break;

                    case MessageType.Pong:
                        writeln("Received pong");
                        break;

                    case MessageType.Close:
                        writefln("Received close: %d %s", msg.closeCode, msg.closeReason);
                        break;
                }
            } catch (WebSocketClosedException e) {
                writefln("Connection closed: %d %s", e.code, e.reason);
                break;
            } catch (WebSocketException e) {
                writefln("WebSocket error: %s", e.msg);
                break;
            }
        }

        writeln("Client disconnected.");
    } catch (Exception e) {
        writefln("Error: %s", e.msg);
    }
}

/// Read HTTP request from connection (simplified)
string readHTTPRequest(TCPConnection conn) @trusted {
    import std.array : appender;

    auto buffer = appender!string();
    ubyte[1] b;

    // Read until we see \r\n\r\n
    int crlfCount = 0;
    while (conn.connected && crlfCount < 4) {
        conn.read(b[]);
        buffer ~= cast(char) b[0];

        if ((crlfCount % 2 == 0 && b[0] == '\r') ||
            (crlfCount % 2 == 1 && b[0] == '\n')) {
            crlfCount++;
        } else {
            crlfCount = 0;
        }

        if (buffer.data.length > 8192) {
            return "";  // Request too large
        }
    }

    return buffer.data;
}

/// Parse HTTP headers (simplified)
string[string] parseHeaders(string request) {
    import std.string : split, strip, toLower, indexOf;

    string[string] headers;
    auto lines = request.split("\r\n");

    foreach (line; lines[1 .. $]) {  // Skip request line
        if (line.length == 0) break;

        auto colonPos = line.indexOf(':');
        if (colonPos > 0) {
            auto name = line[0 .. colonPos].strip().toLower();
            auto value = line[colonPos + 1 .. $].strip();
            headers[name] = value;
        }
    }

    return headers;
}
