/**
 * Unit tests for WebSocket extension functionality.
 *
 * Tests for permessage-deflate and extension negotiation.
 */
module tests.unit.extension_test;

import std.algorithm : canFind;
import std.array : appender;

import aurora_websocket.extension;
import aurora_websocket.protocol : Frame, Opcode;

// ============================================================================
// EXTENSION PARAMETER PARSING TESTS
// ============================================================================

@("parseExtensionParams - basic parsing")
unittest {
    auto params = parseExtensionParams("permessage-deflate; server_max_window_bits=10; client_no_context_takeover");

    assert("permessage-deflate" in params);
    assert(params["server_max_window_bits"] == "10");
    assert("client_no_context_takeover" in params);
    assert(params["client_no_context_takeover"] == "");
}

@("parseWindowBits - valid values")
unittest {
    assert(parseWindowBits("") == 15);
    assert(parseWindowBits("8") == 8);
    assert(parseWindowBits("15") == 15);
    assert(parseWindowBits("12") == 12);
}

@("parseWindowBits - invalid values")
unittest {
    assert(parseWindowBits("7") == 0);   // Too small
    assert(parseWindowBits("16") == 0);  // Too large
    assert(parseWindowBits("abc") == 0); // Invalid
}

@("parseExtensionsHeader - splits multiple extensions")
unittest {
    auto extensions = parseExtensionsHeader("permessage-deflate, x-custom-ext");
    assert(extensions.length == 2);
    assert(extensions[0] == "permessage-deflate");
    assert(extensions[1] == "x-custom-ext");
}

@("buildExtensionsHeader - joins extensions")
unittest {
    auto header = buildExtensionsHeader(["permessage-deflate", "x-custom"]);
    assert(header == "permessage-deflate, x-custom");
}

// ============================================================================
// PERMESSAGE-DEFLATE TESTS
// ============================================================================

@("PerMessageDeflate - creation with config")
unittest {
    auto config = PerMessageDeflateConfig();
    config.compressionLevel = 6;
    config.minCompressSize = 100;

    auto deflate = new PerMessageDeflate(config, true);
    assert(deflate.name == "permessage-deflate");
    assert(!deflate.negotiated);
}

@("PerMessageDeflate - offer generation")
unittest {
    auto config = PerMessageDeflateConfig();
    config.serverMaxWindowBits = 12;
    config.clientNoContextTakeover = true;

    auto deflate = new PerMessageDeflate(config);
    auto offer = deflate.generateOffer();

    assert(offer.canFind("permessage-deflate"));
    assert(offer.canFind("server_max_window_bits=12"));
    assert(offer.canFind("client_no_context_takeover"));
}

@("PerMessageDeflate - accept valid offer")
unittest {
    auto deflate = new PerMessageDeflate();
    auto response = deflate.acceptOffer("permessage-deflate; client_max_window_bits");

    assert(response !is null);
    assert(response.canFind("permessage-deflate"));
    assert(deflate.negotiated);
}

@("PerMessageDeflate - reject invalid offer")
unittest {
    auto deflate = new PerMessageDeflate();
    auto response = deflate.acceptOffer("x-custom-extension");

    assert(response is null);
    assert(!deflate.negotiated);
}

@("PerMessageDeflate - process server response")
unittest {
    auto deflate = new PerMessageDeflate(PerMessageDeflateConfig.init, true);
    auto accepted = deflate.processResponse("permessage-deflate; server_max_window_bits=12");

    assert(accepted);
    assert(deflate.negotiated);
}

@("PerMessageDeflate - compression/decompression roundtrip")
unittest {
    auto deflate = new PerMessageDeflate();
    deflate.processResponse("permessage-deflate");  // Force negotiated state

    // Create a test frame with compressible data
    Frame frame;
    frame.fin = true;
    frame.opcode = Opcode.Text;
    frame.rsv1 = false;
    
    // Large repetitive data compresses well
    auto result = appender!string();
    foreach (_; 0 .. 100) {
        result ~= "Hello World! ";
    }
    frame.payload = cast(ubyte[]) result.data.dup;

    // Compress
    auto compressed = deflate.transformOutgoing(frame);
    assert(compressed.rsv1 == true, "RSV1 should be set after compression");
    assert(compressed.payload.length < frame.payload.length, "Compressed should be smaller");

    // Decompress
    auto decompressed = deflate.transformIncoming(compressed);
    assert(decompressed.rsv1 == false, "RSV1 should be cleared after decompression");
}
