# Granville

Granville is a Zig-based inference kernel for local CPU models. It serves as the backend infrastructure layer for an AI-native OS framework written in Python.

Named after **Granville T. Woods** (1856-1910), the African American inventor known as "Black Edison" who held over 60 patents for railroad and electrical systems.

## Vision

Granville is the **kernel** of a larger AI OS stack:
- **Zig layer (Granville)**: Fast, portable binary handling inference, scheduling, and model management
- **Python layer**: High-level framework handling networking, workflows, and user-facing APIs

Zig was chosen for:
- Single static binary, no runtime dependencies
- Cross-compilation to any platform (phones, edge devices, servers)
- C interop for driver system
- Predictable performance (no GC pauses) for scheduler/queue

## Architecture

```
Python OS Framework
       ↓ (MessagePack over Unix socket / Named pipe on Windows)
   Granville Scheduler
       ↓ (priority queue: critical → low)
   Driver Interface → [granville-llama | custom-gpu | ...]
       ↓
   Model Inference
       ↓ (MessagePack callback)
   Python OS Framework
```

## Driver System

Granville uses a **pluggable driver architecture** for inference backends. The core binary is small (~100KB), and drivers are downloaded on demand.

### Driver Commands
```bash
granville driver install granville-llama  # Install a driver
granville driver list                      # List installed drivers
granville driver remove granville-llama   # Remove a driver
```

### Driver Naming Convention
- **Official drivers**: `granville-<backend>` (e.g., `granville-llama`, `granville-whisper`)
- **Community drivers**: `<vendor>-granville-<name>` (e.g., `acme-granville-tpu`)

### Driver Storage
```
~/.granville/
├── models/                    # Downloaded GGUF models
│   └── llama-2-7b.Q4_K_M.gguf
└── drivers/                   # Installed drivers
    └── granville-llama/
        ├── driver.json        # Metadata
        └── libgranville_llama.dylib  # Shared library
```

### Writing a Driver

Drivers are shared libraries that export a C ABI interface. They can be written in any language:
- **Zig** (recommended)
- C/C++
- Rust (with `extern "C"`)

Required exports:
```c
// Initialize driver, returns context
void* granville_driver_init();

// Cleanup
void granville_driver_deinit(void* ctx);

// Load model from path
void* granville_driver_load_model(void* ctx, const char* path);

// Unload model
void granville_driver_unload_model(void* ctx, void* model);

// Generate text
const char* granville_driver_generate(void* ctx, void* model, const char* prompt, uint32_t max_tokens);

// Free returned string
void granville_driver_free_string(const char* str);

// Driver info
const char* granville_driver_get_name();
const char* granville_driver_get_version();

// VTable for dynamic loading
extern DriverVTable granville_driver_vtable;
```

## Commands

```bash
granville download <url>           # Download GGUF model from Hugging Face
granville serve <model> [options]  # Start inference server
granville driver <subcommand>      # Manage drivers
granville help                     # Show help
granville version                  # Show version
```

### Serve Options
```
-p, --port <port>      HTTP status endpoint (default: 8080)
-s, --socket <path>    Unix socket path (default: /tmp/granville.sock)
-q, --queue-size <n>   Maximum queue size (default: 1000)
-d, --driver <name>    Inference driver (default: granville-llama)
```

## Project Structure

```
granville/
├── build.zig           # Build configuration
├── build.zig.zon       # Dependencies
├── registry.json       # Driver registry
├── CLAUDE.md           # This file
├── src/
│   ├── main.zig        # Entry point
│   ├── cli.zig         # Argument parsing
│   ├── download.zig    # Model download
│   ├── driver.zig      # Driver interface and loader
│   ├── server.zig      # Unix socket MessagePack server
│   ├── scheduler.zig   # Priority queue
│   └── protocol.zig    # MessagePack types
└── vendor/
    └── zig-msgpack/    # MessagePack library (vendored)
```

## Dependencies

- **zig-msgpack** (vendored) - MessagePack serialization

## Building

```bash
# Requires Zig 0.15.2+
zig build                         # Debug build
zig build -Doptimize=ReleaseFast  # Release build
zig build test                    # Run tests
```

## Cross-Compilation

```bash
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
```

## MessagePack Protocol

### Request (client → granville)
```json
{
  "id": "uuid",
  "text": "user input text",
  "callback": "/tmp/client.sock",
  "ranked": false,
  "priority": null
}
```

### ACK Response (immediate)
```json
{
  "id": "uuid",
  "status": "accepted"
}
```

### Result (granville → callback)
```json
{
  "id": "uuid",
  "tool_id": "__chat__",
  "tool_input_json": "[\"response text\"]",
  "priority": "normal"
}
```

### Error Response
```json
{
  "id": "uuid",
  "error": "queue_full",
  "code": 429
}
```

## Registry Evolution

The driver registry evolves in stages:
1. **Stage 1** (current): Single JSON file in repo
2. **Stage 2**: GitHub Releases for binary distribution
3. **Stage 3**: API + database for search/versioning
4. **Stage 4**: Federated registries for enterprise

## Development Notes

- Use `/opt/homebrew/bin/zig` on macOS if you have multiple Zig versions
- Tests are in the same file as code (idiomatic Zig)
- Drivers use C ABI for maximum language compatibility
- Platform abstraction via comptime - zero runtime cost

---

## Completed Features

### Multi-Model Load Balancing ✅

Multiple models on one socket with sticky sessions is **fully implemented**.

**CLI:**
```bash
granville serve model1.gguf model2.gguf model3.gguf  # Load multiple models
granville serve "inference:model.gguf"               # With model type
granville serve "inference:1:model.gguf"             # With explicit ID
```

**Protocol (implemented):**
```json
// Request
{
  "id": "uuid",
  "text": "input",
  "callback": "/tmp/client.sock",
  "model_id": null,        // null = load balancer picks, or 1/2/3 for sticky routing
  "max_tokens": 256
}

// Response (includes model_id for sticky routing)
{
  "id": "uuid",
  "model_id": 1,           // Integer ID of model that handled request
  "tool_id": "__chat__",
  "tool_input_json": "[\"response\"]",
  "priority": "normal"
}
```

**Implementation:**
- `model_pool.zig`: ModelPool with least-busy routing (`acquireLeastBusy`)
- Model types: inference, stt, tts, embedding, unassigned
- Sticky sessions via `model_id` field in requests/responses
- Active request tracking for load balancing
- Multiple worker threads (default: min(num_models, 8))

### GPU Support (granville-llama) ✅

Metal (macOS) acceleration is **enabled** in the granville-llama driver.

**Environment variables:**
```bash
GRANVILLE_LLAMA_GPU_LAYERS=35   # Layers to offload (0 = CPU only)
GRANVILLE_LLAMA_CONTEXT=2048    # Context size
GRANVILLE_LLAMA_THREADS=8       # CPU threads
```

---

## Future Roadmap

### 1. KV Cache Session Persistence

Enable session_id for KV cache reuse across requests (conversation continuity).

```json
{
  "session_id": "user-abc123"    // for KV cache reuse
}
```

### 2. Model Registry HTTP API

Expose model list/status via HTTP endpoint.

```json
// GET /models
{
  "models": [
    {"id": 1, "type": "inference", "path": "llama7b.gguf", "active_requests": 0},
    {"id": 2, "type": "stt", "path": "whisper.gguf", "active_requests": 1}
  ]
}
```

### 3. Crucible (Workflow Runtime)

Separate repo: `rjpruitt16/crucible`

Zig-based workflow executor that orchestrates multi-step pipelines.

**Architecture:**
```
┌─────────────────────────────────────┐
│  Crucible (port 9001)               │
│  - Workflow definitions             │
│  - Step execution                   │
│  - Model type routing               │
└──────────────┬──────────────────────┘
               │ MessagePack
               ▼
┌─────────────────────────────────────┐
│  Granville (port 9000)              │
│  - Model pool                       │
│  - Load balancing                   │
│  - Inference                        │
└─────────────────────────────────────┘
```

**Workflow definition:**
```zig
const workflow = Workflow{
    .steps = &.{
        Step{ .id = "transcribe", .model_type = "stt", .output = "text" },
        Step{ .id = "process", .model_type = "inference", .input = "text", .output = "response" },
        Step{ .id = "speak", .model_type = "tts", .input = "response", .output = "audio" },
    },
};
```

**Use cases:**
- Speech → Inference → Speech (voice assistant)
- RAG: embed → search → rerank → generate
- Code review: parse → analyze → summarize
- Content moderation: classify → explain → action
- Agent loops: plan → execute → observe → repeat

**Core loop:**
```zig
pub fn execute(workflow: *Workflow, ctx: *Context) !void {
    for (workflow.steps) |step| {
        if (step.shouldRun(ctx)) {
            const result = try granville.call(step.model_type, ctx.get(step.input));
            try ctx.set(step.output, result);
        }
    }
}
```

### Implementation Order

1. ~~**Model Pool** - load multiple models, assign IDs~~ ✅
2. ~~**Load Balancer** - round-robin/least-busy routing~~ ✅
3. ~~**Sticky Sessions** - track model_id per request/response~~ ✅
4. **Model Registry HTTP API** - expose model list/status via HTTP
5. ~~**GPU build** - rebuild granville-llama with Metal~~ ✅
6. **KV Cache Sessions** - track session_id for cache reuse
7. **Crucible scaffold** - new repo, basic executor
