# 5-Layer Bridge Architecture

## Overview

The bridge connects an iOS/macOS SwiftUI app to Claude Code's API through five layers. Each layer exists because the layer above cannot talk to the layer below without an intermediary.

```
Layer 1: iOS App (SwiftUI)
    |  HTTP POST /api/v1/chat/stream
    v
Layer 2: Vapor Backend (Swift/NIO)
    |  Process() spawn, sanitized env
    v
Layer 3: Python sdk-wrapper.py
    |  claude_agent_sdk.query() async iterator
    v
Layer 4: Claude CLI
    |  OAuth-authenticated HTTP
    v
Layer 5: Anthropic API
```

## Why Each Layer Exists

### Layer 1 → Layer 2: iOS to Vapor

Standard HTTP with SSE streaming. The only layer that worked on the first try. The iOS app sends `POST /api/v1/chat/stream` and receives Server-Sent Events in return.

### Layer 2 → Layer 3: Vapor to Python

**Required because**: The Swift SDK (`ClaudeCodeSDK`) has a RunLoop dependency incompatible with Vapor's NIO runtime. Publisher emissions are silently dropped because NIO event loops don't pump RunLoop.

Process spawning with GCD-based stdout reading avoids the impedance mismatch. Environment variable stripping prevents nesting detection failures.

### Layer 3: Python Wrapper

**Required because**: The raw Claude CLI output needs structured parsing with partial message support. The `claude-agent-sdk` Python package provides this with a clean async iterator. The wrapper also serves as an isolation boundary — if the SDK changes its interface, only the 8-line Python script needs updating.

### Layer 4: Claude CLI

**Required because**: Claude Code uses OAuth authentication, not API keys. The CLI is the only consumer-accessible interface that handles the OAuth token chain correctly.

### Layer 5: Anthropic API

The actual destination. The only layer that was never a problem.

## Response Path

The response flows in reverse, with each layer translating the format:

```
Anthropic API → Claude CLI → stdout →
Python (json.dumps) → stdout NDJSON →
Swift (line parse) → SSE events → iOS (EventSource)
```

## Serialization Boundaries

Six serialization boundaries exist in the full path:

1. Swift struct → JSON (HTTP request body)
2. JSON → Python dict (bridge config)
3. Python SDK event → JSON string (NDJSON line)
4. JSON string → Swift Data (stdout read)
5. Swift Data → StreamMessage (Codable decode)
6. StreamMessage → SSE event (text/event-stream)

Each boundary is a potential source of bugs. The text duplication P2 bug was caused by incorrect accumulation semantics at boundary 5.

## Performance

| Path | Latency | Notes |
|------|---------|-------|
| Direct API (hypothetical) | ~1-3s | If API key auth were available |
| Python bridge, cold start | ~12s | Process spawn + interpreter + SDK init |
| Python bridge, warm | ~2-3s | Subsequent calls in same session |
| Cost per query | ~$0.04 | Claude Sonnet, typical chat message |

The cold start penalty is real but acceptable for a chat interface where the user is reading the previous response.
