/**
 * WebSocket TLS Configuration
 *
 * This module provides TLS configuration types for secure WebSocket connections (wss://).
 * 
 * The actual TLS stream adapter implementation should be provided by the user
 * (e.g., using vibe-d, OpenSSL bindings, or other TLS libraries).
 *
 * Example (with vibe-d adapter in your application):
 * ---
 * import websocket;
 * import your_app.adapters : VibeTLSAdapter;
 *
 * // Create TLS config
 * auto tlsConfig = TlsConfig();
 * tlsConfig.peerValidation = TlsPeerValidation.trustedCert;
 *
 * // Create TLS stream using your adapter
 * auto stream = new VibeTLSAdapter(host, port, tlsConfig);
 *
 * // Use with WebSocket client
 * auto ws = WebSocketClient.connect(stream, url);
 * ---
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 * Standards: RFC 6455, RFC 5246 (TLS 1.2), RFC 8446 (TLS 1.3)
 */
module websocket.tls;

// ============================================================================
// TLS CONFIGURATION
// ============================================================================

/**
 * TLS peer validation modes.
 *
 * Controls how strictly the server's certificate is validated.
 */
enum TlsPeerValidation {
    /// Validate certificate against trusted CAs (recommended for production)
    /// Checks cert validity, peer name, and trust chain
    trustedCert,
    
    /// Validate certificate and peer name but don't require trusted CA
    /// Useful for self-signed certs with known fingerprints
    validCert,
    
    /// Only require certificate exists, no validation
    requireCert,
    
    /// Skip all certificate validation (INSECURE - for testing only!)
    none
}

/**
 * TLS configuration options.
 *
 * Configure certificate validation, client certificates, and TLS version.
 * Pass this to your TLS stream adapter implementation.
 */
struct TlsConfig {
    /// How to validate the server's certificate
    TlsPeerValidation peerValidation = TlsPeerValidation.trustedCert;
    
    /// Custom CA certificate file path (PEM format)
    /// If null, system CA store is used
    string caCertFile = null;
    
    /// Client certificate file path (PEM format) for mutual TLS
    string clientCertFile = null;
    
    /// Client private key file path (PEM format) for mutual TLS
    string clientKeyFile = null;
    
    /// Override SNI hostname (null = use connection hostname)
    string sniHost = null;
    
    /// Allow specific TLS versions (null = use library defaults)
    /// Format: "tlsv1.2", "tlsv1.3", etc.
    string minVersion = null;
    
    /**
     * Create a TlsConfig that skips certificate validation.
     * 
     * WARNING: Only use for testing! This is insecure.
     */
    static TlsConfig insecure() pure @safe nothrow {
        TlsConfig config;
        config.peerValidation = TlsPeerValidation.none;
        return config;
    }
}
