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
    static import aurora_websocket.message;
    static import aurora_websocket.protocol;
    static import aurora_websocket.handshake;
    static import aurora_websocket.stream;
    static import aurora_websocket.connection;

    // Import dedicated test files
    static import unit.message_test;
    static import unit.protocol_test;
    static import unit.handshake_test;

    writeln("✅ All tests passed!");
}
