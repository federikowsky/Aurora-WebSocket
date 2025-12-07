#!/bin/bash
# filepath: /Users/federicofilippi/Desktop/MyProj/D/Aurora-WebSocket/tests/autobahn/run_tests.sh
# 
# Run Autobahn WebSocket compliance tests
#
# Prerequisites:
# - Docker installed
# - Autobahn test server running (dub run --config=autobahn-server)
#
# Usage:
#   ./tests/autobahn/run_tests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "========================================"
echo "  Autobahn WebSocket Compliance Tests"
echo "========================================"
echo ""

# Create reports directory
mkdir -p "$SCRIPT_DIR/reports"

# Check if server is running
if ! nc -z localhost 9001 2>/dev/null; then
    echo "ERROR: Autobahn test server not running on port 9001"
    echo ""
    echo "Start the server first:"
    echo "  cd $PROJECT_DIR"
    echo "  dub run --config=autobahn-server"
    echo ""
    exit 1
fi

echo "Running Autobahn tests..."
echo ""

# Run wstest
docker run -it --rm \
    -v "$SCRIPT_DIR:/config:ro" \
    -v "$SCRIPT_DIR/reports:/reports" \
    --network=host \
    crossbario/autobahn-testsuite \
    wstest -m fuzzingclient -s /config/fuzzingclient.json

echo ""
echo "========================================"
echo "  Tests Complete!"
echo "========================================"
echo ""
echo "Results available at:"
echo "  $SCRIPT_DIR/reports/index.html"
echo ""
echo "Open with: open $SCRIPT_DIR/reports/index.html"
