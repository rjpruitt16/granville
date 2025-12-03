# Granville Makefile
# Local CPU Model Inference Kernel

ZIG ?= /opt/homebrew/bin/zig

.PHONY: all build build-release test test-unit test-integration clean install setup

# Default target
all: build

# Build debug version
build:
	$(ZIG) build

# Build optimized release
build-release:
	$(ZIG) build -Doptimize=ReleaseFast

# Install Python dependencies
setup:
	poetry install

# Run all tests
test: test-unit test-integration

# Run Zig unit tests
test-unit:
	$(ZIG) build test

# Run Python integration tests
test-integration: build
	poetry run python tests/integration_test.py

# Clean build artifacts
clean:
	rm -rf zig-out .zig-cache

# Install to ~/.local/bin (optional)
install: build-release
	mkdir -p ~/.local/bin
	cp zig-out/bin/granville ~/.local/bin/
	@echo "Installed to ~/.local/bin/granville"
	@echo "Make sure ~/.local/bin is in your PATH"

# Cross-compile for Linux
build-linux-x64:
	$(ZIG) build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu

build-linux-arm64:
	$(ZIG) build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu

# Development helpers
run-server:
	./zig-out/bin/granville serve ~/.granville/models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf

list-drivers:
	./zig-out/bin/granville driver list

# Help
help:
	@echo "Granville - Local CPU Model Inference Kernel"
	@echo ""
	@echo "Targets:"
	@echo "  build            Build debug version"
	@echo "  build-release    Build optimized release"
	@echo "  test             Run all tests"
	@echo "  test-unit        Run Zig unit tests"
	@echo "  test-integration Run Python integration tests"
	@echo "  clean            Remove build artifacts"
	@echo "  install          Install to ~/.local/bin"
	@echo ""
	@echo "Cross-compilation:"
	@echo "  build-linux-x64  Build for Linux x86_64"
	@echo "  build-linux-arm64 Build for Linux ARM64"
