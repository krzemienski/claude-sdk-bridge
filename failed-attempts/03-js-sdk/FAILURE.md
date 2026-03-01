# Attempt 3: JavaScript SDK — FAILED

## What Was Tried

Use the `@anthropic-ai/sdk` npm package to call the Anthropic API directly from a Node.js subprocess, avoiding the Swift SDK's RunLoop issues entirely.

## The Exact Error

```
Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
```

## Why It Fails Fundamentally

The same authentication wall as Attempt 1: Claude Code uses OAuth, not API keys. The JavaScript SDK is just a different language binding for the same API key-based authentication.

Additionally, even the Node.js Agent SDK (`@anthropic-ai/claude-agent-sdk`) has environment variable inheritance issues — when spawned from within a Claude Code session, `CLAUDECODE=1` triggers nesting detection in the underlying CLI call.

## Why It Was Abandoned (Beyond Auth)

Even if authentication worked, this approach adds Node.js as a **runtime dependency** for a Swift/Vapor backend:

1. **Unnecessary runtime**: The backend is Swift. Adding Node.js means managing `node`, `npm`, `package.json`, and `node_modules` for a single subprocess call.
2. **No advantage over Python**: The `claude-agent-sdk` Python package provides identical functionality with a smaller footprint. Python is typically pre-installed on macOS.
3. **Streaming complexity**: The JS SDK's streaming interface requires careful async iteration handling. The Python SDK's `async for` is cleaner.

## Time Lost

A few hours. Abandoned quickly once the auth issue repeated from Attempt 1 and the Python alternative became clear.

## Key Lesson

When choosing a bridge language, prefer the ecosystem that the tool already supports best. Claude Code's Agent SDK is maintained for Python — that's the path of least resistance.
