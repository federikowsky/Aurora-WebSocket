/**
 * Unit tests for websocket.stream module
 */
module tests.unit.stream_test;

import websocket.stream;

// Test MockWebSocketStream - basic read
unittest {
    auto stream = new MockWebSocketStream(cast(ubyte[]) "Hello");

    auto result = stream.readExactly(5);
    assert(result == cast(ubyte[]) "Hello");
}

// Test MockWebSocketStream - write capture
unittest {
    auto stream = new MockWebSocketStream();

    stream.write(cast(ubyte[]) "Test");
    stream.write(cast(ubyte[]) " data");

    assert(stream.writtenData == cast(ubyte[]) "Test data");
}

// Test MockWebSocketStream - EOF handling
unittest {
    auto stream = new MockWebSocketStream(cast(ubyte[]) "Hi");

    stream.readExactly(2);

    bool threw = false;
    try {
        stream.readExactly(1);  // No more data
    } catch (WebSocketStreamException) {
        threw = true;
    }
    assert(threw, "Should throw on EOF");
}

// Test MockWebSocketStream - close behavior
unittest {
    auto stream = new MockWebSocketStream();
    assert(stream.connected);

    stream.close();
    assert(!stream.connected);

    bool threw = false;
    try {
        stream.write([0x00]);
    } catch (WebSocketStreamException) {
        threw = true;
    }
    assert(threw, "Should throw when closed");
}

// Test MockWebSocketStream - pushReadData
unittest {
    auto stream = new MockWebSocketStream();

    stream.pushReadData(cast(ubyte[]) "Part1");
    stream.pushReadData(cast(ubyte[]) "Part2");

    auto result = stream.readExactly(10);
    assert(result == cast(ubyte[]) "Part1Part2");
}

// Test read with partial buffer
unittest {
    auto stream = new MockWebSocketStream(cast(ubyte[]) "Hello World");

    ubyte[5] buffer;
    auto result = stream.read(buffer);

    assert(result.length == 5);
    assert(result == cast(ubyte[]) "Hello");
}
