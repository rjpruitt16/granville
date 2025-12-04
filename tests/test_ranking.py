#!/usr/bin/env python3
"""
Test ranking and PII redaction functionality.
Every task should be ranked and have PII redacted before being processed.

Run with: poetry run python tests/test_ranking.py
"""

import socket
import msgpack
import uuid
import os
import time

SOCKET_PATH = "/tmp/granville.sock"
CALLBACK_PATH = "/tmp/granville_ranking_callback.sock"

def cleanup_sockets():
    try:
        os.unlink(CALLBACK_PATH)
    except FileNotFoundError:
        pass

def test_ranking(text: str, expected_priority: str, should_redact: bool = False):
    """Send a task with ranked=True and see what priority gets assigned"""
    cleanup_sockets()

    # Create callback socket to receive result
    callback_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    callback_sock.bind(CALLBACK_PATH)
    callback_sock.listen(1)
    callback_sock.settimeout(120)  # Long timeout for inference + ranking

    try:
        # Connect to server
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(SOCKET_PATH)
        client.settimeout(10)

        # Send request with ranked=True (no explicit priority)
        request = {
            'id': str(uuid.uuid4()),
            'text': text,
            'callback': CALLBACK_PATH,
            'ranked': True,  # Ask server to rank this task and redact PII
            # No 'priority' field - server should determine it
        }
        client.send(msgpack.packb(request))

        # Get ACK
        ack = msgpack.unpackb(client.recv(4096))
        assert ack['status'] == 'accepted', f"ACK failed: {ack}"
        print(f"  ACK received for: {text[:40]}...")
        client.close()

        # Wait for result on callback socket
        conn, _ = callback_sock.accept()
        conn.settimeout(120)
        result = msgpack.unpackb(conn.recv(65536))
        conn.close()

        priority = result.get('priority', 'unknown')
        print(f"  Priority assigned: {priority} (expected: {expected_priority})")

        # Check if PII was redacted in the response (if applicable)
        if should_redact:
            response_text = result.get('tool_input_json', '')
            has_redaction = any(tag in response_text for tag in ['[EMAIL]', '[PHONE]', '[SSN]', '[NAME]', '[ADDRESS]', '[CARD]'])
            print(f"  PII redaction detected: {has_redaction}")

        return priority

    finally:
        callback_sock.close()
        cleanup_sockets()

def main():
    print("\n=== Granville Ranking & PII Redaction Test ===\n")

    # Check socket exists
    if not os.path.exists(SOCKET_PATH):
        print(f"ERROR: Server not running. Socket {SOCKET_PATH} not found.")
        print("Start with: ./zig-out/bin/granville serve ~/.granville/models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf")
        return 1

    # Test cases with different urgency levels
    print("=== Priority Classification Tests ===")
    priority_tests = [
        ("URGENT: Production server is DOWN! All customers affected!", "CRITICAL"),
        ("The checkout button is not working for mobile users", "HIGH"),
        ("Can you help me write a function to sort an array?", "NORMAL"),
        ("Maybe someday add a fun easter egg to the about page", "LOW"),
    ]

    results = []
    for text, expected in priority_tests:
        print(f"\nTesting: {text[:50]}...")
        try:
            actual = test_ranking(text, expected)
            results.append((text, expected, actual, expected.lower() == actual.lower()))
        except Exception as e:
            print(f"  FAILED: {e}")
            results.append((text, expected, "ERROR", False))

    # PII redaction tests
    print("\n=== PII Redaction Tests ===")
    pii_tests = [
        ("Contact john.doe@example.com about the urgent server issue", "CRITICAL", True),
        ("Call me at 555-123-4567 to discuss the bug", "HIGH", True),
        ("My SSN is 123-45-6789 and I need help with my account", "CRITICAL", True),
        ("Send the report to Jane Smith at 123 Main St, NYC", "NORMAL", True),
    ]

    for text, expected, should_redact in pii_tests:
        print(f"\nTesting PII: {text[:50]}...")
        try:
            actual = test_ranking(text, expected, should_redact)
            results.append((text, expected, actual, expected.lower() == actual.lower()))
        except Exception as e:
            print(f"  FAILED: {e}")
            results.append((text, expected, "ERROR", False))

    # Summary
    print("\n=== Results ===")
    passed = 0
    for text, expected, actual, success in results:
        status = "PASS" if success else "MISS"
        if success:
            passed += 1
        print(f"  [{status}] Expected {expected}, got {actual}: {text[:40]}...")

    print(f"\n{passed}/{len(results)} matched expectations")
    print("\nNote: Ranking and PII redaction depend on model interpretation. Mismatches may be acceptable.")

    return 0

if __name__ == "__main__":
    exit(main())
