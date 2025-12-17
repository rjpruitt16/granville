# Granville

Zig-based inference kernel for local CPU models. Named after **Granville T. Woods** (1856-1910), the African American inventor known as "Black Edison" who held over 60 patents for railroad and electrical systems.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Python OS Framework                              │
│                    (Layer8 / User Applications)                          │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │ MessagePack over IPC
                                      │ (Unix socket / Windows named pipe)
┌─────────────────────────────────────▼───────────────────────────────────┐
│                           GRANVILLE KERNEL                               │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                        Socket Server                             │    │
│  │              (accepts connections, sends ACKs)                   │    │
│  └─────────────────────────────┬───────────────────────────────────┘    │
│                                │                                         │
│  ┌─────────────────────────────▼───────────────────────────────────┐    │
│  │                     Unranked Queue (FIFO)                        │    │
│  │               Tasks waiting to be classified                     │    │
│  └─────────────────────────────┬───────────────────────────────────┘    │
│                                │                                         │
│  ┌─────────────────────────────▼───────────────────────────────────┐    │
│  │                       Ranker Thread                              │    │
│  │    - Classifies priority: CRITICAL > HIGH > NORMAL > LOW         │    │
│  │    - Redacts PII: [EMAIL] [PHONE] [SSN] [NAME] [ADDRESS] [CARD]  │    │
│  └─────────────────────────────┬───────────────────────────────────┘    │
│                                │                                         │
│  ┌─────────────────────────────▼───────────────────────────────────┐    │
│  │                    Ranked Queue (Priority)                       │    │
│  │              Tasks sorted by priority, ready for inference       │    │
│  └─────────────────────────────┬───────────────────────────────────┘    │
│                                │                                         │
│  ┌─────────────────────────────▼───────────────────────────────────┐    │
│  │                       Worker Thread                              │    │
│  │            Pulls highest priority, runs inference                │    │
│  └─────────────────────────────┬───────────────────────────────────┘    │
│                                │                                         │
│  ┌─────────────────────────────▼───────────────────────────────────┐    │
│  │                      Driver Interface                            │    │
│  │                 C ABI for pluggable backends                     │    │
│  └─────────────────────────────┬───────────────────────────────────┘    │
└────────────────────────────────┼────────────────────────────────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
        ▼                        ▼                        ▼
┌───────────────┐      ┌───────────────┐      ┌───────────────┐
│granville-llama│      │ granville-gpu │      │  custom-tpu   │
│  (llama.cpp)  │      │   (future)    │      │   (future)    │
└───────────────┘      └───────────────┘      └───────────────┘
```

## Request Flow

```
Client                          Granville
  │                                │
  │──── Request ──────────────────▶│
  │                                │── ACK (immediate)
  │◀─── ACK ───────────────────────│── Push to Unranked Queue
  │                                │
  │    [Client free to continue]   │
  │                                │── Ranker: classify + redact PII
  │                                │── Push to Ranked Queue (by priority)
  │                                │── Worker: inference on redacted text
  │                                │
  │◀─── Result (via callback) ─────│
  │                                │
```

1. **Submit** - Client sends MessagePack request over IPC
2. **ACK** - Server immediately acknowledges receipt (client can disconnect)
3. **Enqueue** - Task goes to Unranked Queue (FIFO)
4. **Rank & Redact** - Ranker thread (async) classifies priority AND redacts PII
5. **Priority Queue** - Redacted task moves to Ranked Queue sorted by priority
6. **Inference** - Worker thread pulls highest priority task, runs inference on clean text
7. **Callback** - Result sent to client's callback socket

## PII Redaction

Granville automatically strips personally identifiable information (PII) from all ranked requests **before** they reach the inference model. This happens during the ranking step, ensuring sensitive data never touches the LLM or appears in logs.

### How It Works

When a request is submitted with `ranked: true`, the ranker thread:
1. Analyzes the text for PII patterns
2. Replaces detected PII with placeholder tokens
3. Classifies the priority (CRITICAL/HIGH/NORMAL/LOW)
4. Passes the **redacted** text to inference

### Supported PII Types

| PII Type | Placeholder | Example |
|----------|-------------|---------|
| Email addresses | `[EMAIL]` | `john@example.com` → `[EMAIL]` |
| Phone numbers | `[PHONE]` | `555-123-4567` → `[PHONE]` |
| SSN/ID numbers | `[SSN]` | `123-45-6789` → `[SSN]` |
| Names of people | `[NAME]` | `John Smith` → `[NAME]` |
| Physical addresses | `[ADDRESS]` | `123 Main St, NYC` → `[ADDRESS]` |
| Credit card numbers | `[CARD]` | `4111-1111-1111-1111` → `[CARD]` |

### Why This Matters

- **Privacy by design** - Sensitive data never reaches the model
- **Compliance ready** - Helps with GDPR, HIPAA, PCI-DSS requirements
- **No data leakage** - PII can't appear in model responses or logs
- **Zero latency overhead** - Redaction happens during ranking (already async)

## Quick Start

The easiest way to get started with the L8 OS stack (Granville + McCoy):

```bash
curl -sSL https://raw.githubusercontent.com/rjpruitt16/granville/main/install.sh | bash
```

This will:
1. Download the Granville binary for your platform
2. Install the `granville-llama` driver
3. Download TinyLlama (~640MB) as a starter model
4. Install McCoy (Python agent framework) via pip

Then start chatting:

```bash
# Terminal 1: Start the inference server
granville serve ~/.granville/models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf

# Terminal 2: Chat with your local AI
mccoy chat
```

### Install Options

```bash
# Skip model download (you have your own)
curl -sSL ... | bash -s -- --no-model

# Skip McCoy install (Granville only)
curl -sSL ... | bash -s -- --no-mccoy

# Install to a different directory
INSTALL_DIR=/opt/bin curl -sSL ... | bash
```

### Manual Installation

```bash
# Requires Zig 0.15.2+
git clone https://github.com/rjpruitt16/granville.git
cd granville
zig build -Doptimize=ReleaseFast

# Install the llama.cpp driver
./zig-out/bin/granville driver install granville-llama

# Download a model
./zig-out/bin/granville download https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf

# Start serving
./zig-out/bin/granville serve ~/.granville/models/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf
```

## MessagePack Protocol

### Request
```json
{
  "id": "uuid",
  "text": "user input",
  "callback": "/tmp/client.sock",
  "ranked": true
}
```

### Response (to callback)
```json
{
  "id": "uuid",
  "tool_id": "__chat__",
  "tool_input_json": "[\"response\"]",
  "priority": "NORMAL"
}
```

## Platform Support

| Platform | IPC Method | Status |
|----------|-----------|--------|
| macOS | Unix Socket | ✅ Supported |
| Linux | Unix Socket | ✅ Supported |
| Windows | Named Pipe | ✅ Comptime Ready |

## Why Zig?

- **Single static binary** - No runtime dependencies
- **Cross-compilation** - Build for any platform from any platform
- **C interop** - Native FFI for driver system
- **Predictable performance** - No GC pauses for scheduler
- **Comptime** - Zero-cost platform abstractions

## License

MIT
