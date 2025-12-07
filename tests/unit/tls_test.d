/**
 * Unit tests for aurora_websocket.tls module
 */
module tests.unit.tls_test;

import aurora_websocket.tls;

// Test TlsConfig defaults
unittest {
    TlsConfig config;
    assert(config.peerValidation == TlsPeerValidation.trustedCert);
    assert(config.caCertFile is null);
    assert(config.clientCertFile is null);
    assert(config.sniHost is null);
}

// Test TlsConfig.insecure()
unittest {
    auto config = TlsConfig.insecure();
    assert(config.peerValidation == TlsPeerValidation.none);
}

// Test TlsPeerValidation enum values
unittest {
    assert(TlsPeerValidation.trustedCert != TlsPeerValidation.none);
    assert(TlsPeerValidation.validCert != TlsPeerValidation.requireCert);
}
