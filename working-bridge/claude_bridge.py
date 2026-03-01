"""Production Python bridge for Claude Code integration.

This is the working solution that emerged after four failed attempts to connect
an iOS app to Claude Code. It wraps the Claude Agent SDK's async iterator
interface and outputs NDJSON lines for consumption by Swift's Process spawner.

Architecture:
    Swift (ClaudeExecutorService)
      -> spawns: python3 bridge.py '{"prompt":"Hello"}'
      -> reads stdout: NDJSON lines (one JSON object per line)
      -> converts: JSON -> StreamMessage Swift types

Why Python:
    1. The `claude-agent-sdk` package wraps Claude CLI natively
    2. It inherits OAuth authentication from ~/.claude/
    3. It provides async iteration with partial message streaming
    4. It handles all the streaming JSON parsing internally
    5. Python is pre-installed on macOS

Why not Swift/JS/direct API:
    See ../failed-attempts/ for detailed failure documentation.

Critical: flush=True
    Without explicit flushing, Python's stdout buffering delays events by
    unpredictable amounts (sometimes seconds). Users would see nothing,
    then a burst of text, then nothing again. Every sys.stdout.write()
    must be followed by sys.stdout.flush().

SDK Compliance (CRITICAL REQUIREMENT #2):
    Message and block type checking MUST use isinstance(), NOT getattr() or .type.
    See: https://docs.anthropic.com/claude-agent-sdk

NOTE: When using ClaudeAgentOptions, you MUST set setting_sources
to load plugins, skills, and CLAUDE.md from the filesystem:
    options = ClaudeAgentOptions(setting_sources=["user", "project"])
Without this, plugins=[], skills=[], commands=[] (nothing loads).

Usage:
    # Direct execution
    python3 bridge.py '{"prompt": "What is 2+2?", "options": {"model": "sonnet"}}'

    # As a pip package
    from claude_bridge import stream_response
    async for event in stream_response("Hello"):
        print(event)
"""

import sys
import json
import asyncio
from typing import AsyncIterator

# SDK message and block type imports — required for isinstance() checks.
# Imported at module level per official SDK compliance requirements.
from claude_agent_sdk import (
    query, ClaudeAgentOptions,
    AssistantMessage, UserMessage, SystemMessage, ResultMessage,
    TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock,
)


# Protocol-level events that don't contain user-facing content.
# These are filtered out before emitting to stdout.
SKIP_EVENTS = frozenset({
    "rate_limit_event", "rate_limit", "ping", "heartbeat",
    "error", "content_block_start", "content_block_stop",
    "content_block_delta", "message_start", "message_stop",
    "message_delta",
})


def emit(obj: dict) -> None:
    """Write a JSON object as an NDJSON line to stdout.

    Uses compact separators to minimize bandwidth.
    flush=True ensures real-time delivery to the parent process.
    """
    line = json.dumps(obj, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def convert_block(block) -> dict:
    """Convert an SDK content block to a serializable dict.

    Handles TextBlock, ToolUseBlock, ToolResultBlock, ThinkingBlock
    using isinstance() checks per official SDK compliance requirements.
    """
    # SDK compliance: use isinstance(), NOT getattr(block, "type", ...) or block.type
    if isinstance(block, TextBlock):
        return {"type": "text", "text": block.text}
    elif isinstance(block, ToolUseBlock):
        return {
            "type": "tool_use",
            "id": block.id,
            "name": block.name,
            "input": block.input,
        }
    elif isinstance(block, ToolResultBlock):
        return {
            "type": "tool_result",
            "tool_use_id": block.tool_use_id,
            "content": block.content,
            "is_error": block.is_error,
        }
    elif isinstance(block, ThinkingBlock):
        return {"type": "thinking", "thinking": block.thinking}
    else:
        text = getattr(block, "text", None) or str(block)
        return {"type": "text", "text": text}


async def stream_response(prompt: str, **kwargs) -> AsyncIterator[dict]:
    """Stream Claude responses as dicts. Async generator interface.

    Args:
        prompt: The user's message to send to Claude.
        **kwargs: Additional options passed to ClaudeAgentOptions
            (model, max_turns, system_prompt, session_id, etc.)

    Yields:
        dict: NDJSON-compatible event dicts with 'type' field.
    """
    options = ClaudeAgentOptions(**kwargs) if kwargs else ClaudeAgentOptions()

    async for message in query(prompt=prompt, options=options):
        # SDK compliance: use isinstance(), NOT getattr(message, "type", ...) or message.type
        if isinstance(message, SystemMessage):
            pass

        elif isinstance(message, AssistantMessage):
            blocks = [convert_block(b) for b in message.content]
            yield {
                "type": "assistant",
                "content": blocks,
                "model": getattr(message, "model", None),
            }

        elif isinstance(message, ResultMessage):
            result = {
                "type": "result",
                "is_error": message.is_error,
                "session_id": message.session_id,
                "total_cost_usd": message.total_cost_usd or 0.0,
            }
            if message.usage:
                u = message.usage
                result["usage"] = {
                    "input_tokens": getattr(u, "input_tokens", 0),
                    "output_tokens": getattr(u, "output_tokens", 0),
                }
            yield result

        elif isinstance(message, UserMessage):
            pass  # UserMessage not emitted in stream_response


async def run_bridge(config: dict) -> None:
    """Run the bridge in NDJSON-to-stdout mode for Swift Process consumption."""
    prompt = config.get("prompt", "")
    opts = config.get("options", {})

    kwargs = {k: v for k, v in opts.items() if v is not None}
    options = ClaudeAgentOptions(**kwargs) if kwargs else ClaudeAgentOptions()
    session_id = opts.get("session_id", "bridge-session")

    emit({"type": "system", "subtype": "init", "data": {"session_id": session_id, "tools": []}})

    got_content = False
    got_result = False

    try:
        async for message in query(prompt=prompt, options=options):
            # SDK compliance: use isinstance(), NOT getattr(message, "type", ...) or message.type
            if isinstance(message, SystemMessage):
                pass

            elif isinstance(message, AssistantMessage):
                blocks = [convert_block(b) for b in message.content]
                if blocks:
                    got_content = True
                emit({"type": "assistant", "message": {"role": "assistant", "content": blocks, "model": getattr(message, "model", None)}})

            elif isinstance(message, ResultMessage):
                got_result = True
                result = {
                    "type": "result",
                    "subtype": "error" if message.is_error else "success",
                    "is_error": message.is_error,
                    "session_id": message.session_id or session_id,
                    "total_cost_usd": message.total_cost_usd or 0.0,
                }
                if message.usage:
                    u = message.usage
                    result["usage"] = {
                        "input_tokens": getattr(u, "input_tokens", 0),
                        "output_tokens": getattr(u, "output_tokens", 0),
                        "cache_read_input_tokens": getattr(u, "cache_read_input_tokens", 0),
                        "cache_creation_input_tokens": getattr(u, "cache_creation_input_tokens", 0),
                    }
                emit(result)

            elif isinstance(message, UserMessage):
                blocks = [convert_block(b) for b in message.content]
                emit({"type": "user", "message": {"role": "user", "content": blocks}})

    except Exception as e:
        error_msg = str(e).lower()
        is_benign = "unknown message type" in error_msg or "rate_limit" in error_msg

        if is_benign and got_content and not got_result:
            emit({"type": "result", "subtype": "success", "is_error": False, "session_id": session_id, "total_cost_usd": 0.0})
        elif not (is_benign and got_content):
            emit({"type": "result", "subtype": "error", "is_error": True, "session_id": session_id, "total_cost_usd": 0.0, "error": str(e)})


def main():
    if len(sys.argv) < 2:
        print("Usage: bridge.py '<json-config>'", file=sys.stderr)
        print("  or:  bridge.py --prompt 'Hello Claude'", file=sys.stderr)
        sys.exit(1)

    if sys.argv[1] == "--prompt":
        config = {"prompt": " ".join(sys.argv[2:]), "options": {"include_partial_messages": True}}
    else:
        try:
            config = json.loads(sys.argv[1])
        except json.JSONDecodeError as e:
            emit({"type": "result", "subtype": "error", "is_error": True, "total_cost_usd": 0.0, "error": f"Invalid JSON: {e}"})
            sys.exit(1)

    asyncio.run(run_bridge(config))


if __name__ == "__main__":
    main()
