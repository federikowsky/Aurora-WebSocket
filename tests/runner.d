/**
 * WebSocket Test Runner
 *
 * Runs all unit tests for the WebSocket library.
 */
module runner;

void main() {
    import std.stdio : writeln;

    writeln("╔══════════════════════════════════════════════════════════════╗");
    writeln("║           WebSocket Library - Test Suite                     ║");
    writeln("╚══════════════════════════════════════════════════════════════╝");
    writeln();

    // Import all test modules to run their unittests
    static import websocket.message;
    static import websocket.protocol;
    static import websocket.handshake;
    static import websocket.stream;
    static import websocket.connection;

    // Import dedicated test files
    static import unit.message_test;
    static import unit.protocol_test;
    static import unit.handshake_test;

    writeln("✅ All tests passed!");
}
