#!/usr/bin/env python3
"""
Granville Integration Tests

Run with: make test-integration
Requires: pip install msgpack
"""

import socket
import msgpack
import uuid
import os
import subprocess
import time
import sys

GRANVILLE_BIN = "./zig-out/bin/granville"
SOCKET_PATH = "/tmp/granville_test.sock"
CALLBACK_PATH = "/tmp/granville_test_callback.sock"

def cleanup_sockets():
    """Remove any existing socket files"""
    for path in [SOCKET_PATH, CALLBACK_PATH]:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

def test_driver_list():
    """Test that driver list command works"""
    print("Testing: driver list...")
    result = subprocess.run(
        [GRANVILLE_BIN, "driver", "list"],
        capture_output=True,
        text=True
    )
    # Should not crash, may or may not have drivers
    assert result.returncode == 0 or "No drivers" in result.stdout
    print("  PASS: driver list")

def test_help():
    """Test help command"""
    print("Testing: help...")
    result = subprocess.run(
        [GRANVILLE_BIN, "help"],
        capture_output=True,
        text=True
    )
    output = result.stdout + result.stderr
    assert "USAGE" in output or "usage" in output.lower(), f"Got: {output}"
    print("  PASS: help")

def test_version():
    """Test version command"""
    print("Testing: version...")
    result = subprocess.run(
        [GRANVILLE_BIN, "version"],
        capture_output=True,
        text=True
    )
    output = result.stdout + result.stderr
    assert "0.2.0" in output, f"Got: {output}"
    print("  PASS: version")

def test_serve_without_model():
    """Test that serve fails gracefully without model"""
    print("Testing: serve without model...")
    result = subprocess.run(
        [GRANVILLE_BIN, "serve"],
        capture_output=True,
        text=True,
        timeout=5
    )
    output = result.stdout + result.stderr
    assert result.returncode != 0
    assert "model" in output.lower() or "required" in output.lower(), f"Got: {output}"
    print("  PASS: serve without model")

def test_inference_if_model_available():
    """Test full inference if a model is available"""
    model_path = os.path.expanduser("~/.granville/models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf")
    driver_path = os.path.expanduser("~/.granville/drivers/granville-llama/libgranville_llama.dylib")

    if not os.path.exists(model_path):
        print("Testing: inference (SKIPPED - no model)")
        return

    if not os.path.exists(driver_path):
        print("Testing: inference (SKIPPED - no driver)")
        return

    print("Testing: full inference pipeline...")
    cleanup_sockets()

    # Start server
    server = subprocess.Popen(
        [GRANVILLE_BIN, "serve", model_path, "-s", SOCKET_PATH],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT
    )

    try:
        # Wait for server to start
        time.sleep(10)

        # Create callback socket
        callback_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        callback_sock.bind(CALLBACK_PATH)
        callback_sock.listen(1)
        callback_sock.settimeout(60)

        # Send request
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(SOCKET_PATH)

        request = {
            'id': str(uuid.uuid4()),
            'text': 'Hello',
            'callback': CALLBACK_PATH,
            'ranked': False,
            'priority': 'normal'
        }
        client.send(msgpack.packb(request))

        # Check ACK
        ack = msgpack.unpackb(client.recv(4096))
        assert ack['status'] == 'accepted', f"Expected accepted, got {ack}"
        client.close()

        # Wait for result
        conn, _ = callback_sock.accept()
        result = msgpack.unpackb(conn.recv(65536))
        conn.close()
        callback_sock.close()

        assert 'tool_input_json' in result
        assert result['id'] == request['id']

        print("  PASS: full inference pipeline")

    finally:
        server.terminate()
        server.wait()
        cleanup_sockets()

def main():
    print("\n=== Granville Integration Tests ===\n")

    if not os.path.exists(GRANVILLE_BIN):
        print(f"ERROR: {GRANVILLE_BIN} not found. Run 'zig build' first.")
        sys.exit(1)

    tests = [
        test_help,
        test_version,
        test_driver_list,
        test_serve_without_model,
        test_inference_if_model_available,
    ]

    passed = 0
    failed = 0

    for test in tests:
        try:
            test()
            passed += 1
        except Exception as e:
            print(f"  FAIL: {test.__name__} - {e}")
            failed += 1

    print(f"\n=== Results: {passed} passed, {failed} failed ===\n")
    sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    main()
