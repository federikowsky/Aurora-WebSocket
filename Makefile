# Aurora-WebSocket Makefile
# RFC 6455 WebSocket library for D

.PHONY: all build test unittest clean docs install help

# Default target
all: build

# Build the library
build:
	dub build

# Build in release mode
release:
	dub build --build=release

# Run all unit tests
test:
	dub test

# Run unit tests with verbose output
unittest:
	dub test -- --verbose

# Clean build artifacts
clean:
	dub clean
	rm -f libwebsocket.a websocket
	rm -f dub.selections.json
	rm -rf .dub/
	rm -rf docs/

# Generate documentation
docs:
	dub build --build=docs

# Format source code (requires dfmt)
format:
	find source/ tests/ examples/ -name "*.d" -exec dfmt --inplace {} \;

# Check code style (requires dfmt)
check-format:
	find source/ tests/ examples/ -name "*.d" -exec dfmt --check {} \;

# Static analysis (requires dscanner)
lint:
	dub lint

# Run the echo server example
run-echo:
	dub run --config=echo-server

# Show help
help:
	@echo "Aurora-WebSocket Build System"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all          Build the library (default)"
	@echo "  build        Build the library in debug mode"
	@echo "  release      Build the library in release mode"
	@echo "  test         Run all unit tests"
	@echo "  unittest     Run unit tests with verbose output"
	@echo "  clean        Remove all build artifacts"
	@echo "  docs         Generate documentation"
	@echo "  format       Format source code with dfmt"
	@echo "  check-format Check code formatting"
	@echo "  lint         Run static analysis with dscanner"
	@echo "  run-echo     Run the echo server example"
	@echo "  help         Show this help message"
