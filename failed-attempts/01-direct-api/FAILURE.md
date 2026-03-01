# Attempt 1: Direct Anthropic API — FAILED

## What Was Tried

Import `@anthropic-ai/sdk` (or the Python `anthropic` package), pass an API key, and stream responses directly from the Anthropic API. The simplest possible approach — three lines of meaningful code.

## The Exact Error

```
anthropic.AuthenticationError: Error code: 401 - {'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}}
```

Or, more commonly, the SDK raises during initialization:

```
anthropic.AuthenticationError: No API key provided. Set ANTHROPIC_API_KEY environment variable or pass api_key parameter.
```

## Why It Fails Fundamentally

Claude Code does **not** use API keys for authentication. It uses a browser-based OAuth flow that produces session tokens managed internally by the CLI binary. These tokens are stored in `~/.claude/` and are not exposed through environment variables or any public API.

The `ANTHROPIC_API_KEY` environment variable simply does not exist in a Claude Code environment.

You *could* ask users to create an API key through the [Anthropic Console](https://console.anthropic.com/), but that defeats the entire purpose of building a client for Claude Code:

1. Users would need separate Anthropic API billing (Claude Code has its own billing)
2. The API key context would be isolated from Claude Code's session context
3. Claude Code features (tools, MCP servers, project context) would be unavailable
4. Users would pay twice — once for Claude Code subscription, once for API usage

## Time Lost

Half a day. The least painful failure on the list, because the error message was clear.

## Key Lesson

When building a client for a tool that manages its own authentication, you must flow through that tool's auth chain. There is no shortcut.
