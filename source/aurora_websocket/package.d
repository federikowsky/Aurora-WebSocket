/**
 * Aurora WebSocket Library
 *
 * A standalone RFC 6455 WebSocket implementation for D.
 * Zero dependencies - protocol-only implementation.
 *
 * Features:
 * - Full RFC 6455 compliance
 * - Frame encoding/decoding with masking
 * - Message fragmentation/reassembly
 * - Automatic ping/pong handling
 * - Clean close handshake
 * - IWebSocketStream abstraction for transport independence
 *
 * Quick Start (Server):
 * ---
 * import aurora_websocket;
 *
 * // You provide the stream adapter for your transport (vibe-d, etc.)
 * class MyTCPAdapter : IWebSocketStream { /+ implement methods +/ }
 *
 * void handleWebSocket(Request req, HijackedConnection conn) {
 *     // Validate upgrade request
 *     auto validation = validateUpgradeRequest(req.method, req.headers);
 *     if (!validation.valid) {
 *         conn.write(cast(ubyte[]) buildBadRequestResponse(validation.error));
 *         return;
 *     }
 *
 *     // Send upgrade response
 *     conn.write(cast(ubyte[]) buildUpgradeResponse(validation.clientKey));
 *
 *     // Create WebSocket connection with your stream adapter
 *     auto stream = new MyTCPAdapter(conn.tcpConnection);
 *     auto ws = new WebSocketConnection(stream);
 *     scope(exit) ws.close();
 *
 *     // Echo server loop
 *     while (ws.connected) {
 *         try {
 *             auto msg = ws.receive();
 *             if (msg.type == MessageType.Text) {
 *                 ws.send("Echo: " ~ msg.text);
 *             }
 *         } catch (WebSocketClosedException e) {
 *             break;
 *         }
 *     }
 * }
 * ---
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 * Standards: RFC 6455
 * See_Also: https://tools.ietf.org/html/rfc6455
 */
module aurora_websocket;

// ============================================================================
// PUBLIC API RE-EXPORTS
// ============================================================================

// Message types and utilities
public import aurora_websocket.message : MessageType, CloseCode, Message, isValidCloseCode;

// Protocol-level types (for advanced use)
public import aurora_websocket.protocol : 
    Opcode,
    Frame,
    encodeFrame,
    decodeFrame,
    DecodeResult,
    applyMask,
    generateMaskKey,
    isControlOpcode,
    isDataOpcode,
    isValidOpcode,
    validateFrame,
    WebSocketException,
    WebSocketProtocolException,
    // Zero-copy / low-allocation variants
    DecodeResultZeroCopy,
    decodeFrameZeroCopy,
    encodedFrameSize,
    encodeFrameInto;

// Handshake utilities (server mode)
public import aurora_websocket.handshake :
    WS_MAGIC_GUID,
    WS_VERSION,
    computeAcceptKey,
    UpgradeValidation,
    validateUpgradeRequest,
    buildUpgradeResponse,
    buildBadRequestResponse,
    WebSocketHandshakeException,
    // Client mode
    generateSecWebSocketKey,
    buildUpgradeRequest,
    ClientUpgradeValidation,
    validateUpgradeResponse,
    // Subprotocol negotiation
    selectSubprotocol,
    validateSelectedSubprotocol;

// Stream abstraction
public import aurora_websocket.stream :
    IWebSocketStream,
    MockWebSocketStream,
    WebSocketStreamException;

// Connection management
public import aurora_websocket.connection :
    ConnectionMode,
    WebSocketConfig,
    WebSocketConnection,
    WebSocketClosedException;

// Client API
public import aurora_websocket.client :
    WebSocketUrl,
    parseWebSocketUrl,
    WebSocketClient,
    WebSocketClientException;

// Extension support
public import aurora_websocket.extension :
    IWebSocketExtension,
    PerMessageDeflateConfig,
    PerMessageDeflate,
    WebSocketExtensionException,
    parseExtensionParams,
    parseWindowBits,
    parseExtensionsHeader,
    buildExtensionsHeader;

// TLS configuration for secure WebSocket (wss://)
public import aurora_websocket.tls :
    TlsPeerValidation,
    TlsConfig;

// Backpressure and flow control
public import aurora_websocket.backpressure :
    MessagePriority,
    BackpressureState,
    BackpressureConfig,
    SlowClientAction,
    BackpressureStats,
    SendBuffer,
    BackpressureWebSocket,
    DrainCallback,
    SlowClientCallback,
    StateChangeCallback;

// ============================================================================
// CONVENIENCE FUNCTIONS
// ============================================================================

/**
 * Accept a WebSocket connection from a validated upgrade request.
 *
 * This is a convenience function that combines stream creation and
 * WebSocket connection initialization.
 *
 * Params:
 *   stream = Connected stream
 *   config = WebSocket configuration
 *
 * Returns:
 *   New WebSocketConnection ready for use
 *
 * Example:
 * ---
 * auto ws = acceptWebSocket(stream);
 * scope(exit) ws.close();
 *
 * while (ws.connected) {
 *     auto msg = ws.receive();
 *     // Handle message...
 * }
 * ---
 */
WebSocketConnection acceptWebSocket(
    IWebSocketStream stream,
    WebSocketConfig config = WebSocketConfig.init
) @safe {
    return new WebSocketConnection(stream, config);
}

// ============================================================================
// VERSION INFO
// ============================================================================

/// Library version
enum WEBSOCKET_VERSION = "1.0.0";

/// WebSocket protocol version supported
enum WEBSOCKET_PROTOCOL_VERSION = 13;
