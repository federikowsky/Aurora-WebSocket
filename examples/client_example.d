/**
 * WebSocket Client Example
 *
 * A simple WebSocket client that connects to a server and echoes messages.
 *
 * First, start the echo server:
 *   dub run --single examples/echo_server.d
 *
 * Then run this client:
 *   dub run --single examples/client_example.d
 *
 * Or connect to any WebSocket server:
 *   dub run --single examples/client_example.d -- ws://echo.websocket.org
 */
module examples.client_example;

/+ dub.sdl:
    name "client_example"
    dependency "aurora-websocket" path=".."
    dependency "vibe-core" version="~>2.0"
+/

import vibe.core.core : runApplication;

import aurora_websocket;

import std.stdio : writeln, writefln, readln;
import std.string : strip;

void main(string[] args) {
    // Default to local echo server
    string url = "ws://localhost:8080/";
    if (args.length > 1) {
        url = args[1];
    }
    
    writefln("Connecting to %s...", url);
    
    try {
        // Connect to WebSocket server
        auto ws = WebSocketClient.connect(url);
        scope(exit) ws.close();
        
        writeln("Connected! Type messages to send (empty line to quit):");
        writeln();
        
        // Simple send/receive loop
        while (ws.connected) {
            // Read user input
            write("> ");
            auto input = readln();
            if (input is null || input.strip().length == 0) {
                writeln("Disconnecting...");
                break;
            }
            
            // Send message
            ws.send(input.strip());
            
            // Receive response
            try {
                auto msg = ws.receive();
                
                switch (msg.type) {
                    case MessageType.Text:
                        writefln("< %s", msg.text);
                        break;
                    case MessageType.Binary:
                        writefln("< [binary: %d bytes]", msg.data.length);
                        break;
                    case MessageType.Close:
                        writefln("Server closed: %s", msg.closeReason);
                        break;
                    default:
                        break;
                }
            } catch (WebSocketClosedException e) {
                writefln("Connection closed: %s", e.reason);
                break;
            }
        }
        
        writeln("Goodbye!");
        
    } catch (WebSocketClientException e) {
        writefln("Connection failed: %s", e.msg);
    } catch (WebSocketHandshakeException e) {
        writefln("Handshake failed: %s", e.msg);
    } catch (Exception e) {
        writefln("Error: %s", e.msg);
    }
}

private void write(string s) {
    import std.stdio : stdout;
    stdout.write(s);
    stdout.flush();
}
