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

The ranker automatically detects and redacts personally identifiable information:

| PII Type | Placeholder |
|----------|-------------|
| Email addresses | `[EMAIL]` |
| Phone numbers | `[PHONE]` |
| SSN/ID numbers | `[SSN]` |
| Names of people | `[NAME]` |
| Physical addresses | `[ADDRESS]` |
| Credit card numbers | `[CARD]` |

This ensures sensitive data never reaches the inference model or logs.

## Installation

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
