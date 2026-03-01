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
    with fallback to class name inspection for SDK version compatibility.
    """
    block_type = getattr(block, "type", None)

    if block_type is None:
        name = type(block).__name__.lower()
        if "text" in name and "tool" not in name:
            block_type = "text"
        elif "thinking" in name:
            block_type = "thinking"
        elif "tooluse" in name or "tool_use" in name:
            block_type = "tool_use"
        elif "toolresult" in name or "tool_result" in name:
            block_type = "tool_result"

    if block_type == "text":
        return {"type": "text", "text": getattr(block, "text", str(block))}
    elif block_type == "tool_use":
        return {
            "type": "tool_use",
            "id": getattr(block, "id", ""),
            "name": getattr(block, "name", ""),
            "input": getattr(block, "input", {}),
        }
    elif block_type == "tool_result":
        return {
            "type": "tool_result",
            "tool_use_id": getattr(block, "tool_use_id", ""),
            "content": getattr(block, "content", ""),
            "is_error": getattr(block, "is_error", False),
        }
    elif block_type == "thinking":
        return {"type": "thinking", "thinking": getattr(block, "thinking", "")}
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
    from claude_agent_sdk import query, ClaudeAgentOptions

    options = ClaudeAgentOptions(**kwargs) if kwargs else ClaudeAgentOptions()

    async for message in query(prompt=prompt, options=options):
        msg_type = getattr(message, "type", type(message).__name__).lower()

        if msg_type in SKIP_EVENTS:
            continue

        if "assistant" in msg_type and hasattr(message, "content"):
            blocks = [convert_block(b) for b in message.content]
            yield {
                "type": "assistant",
                "content": blocks,
                "model": getattr(message, "model", None),
            }

        elif "result" in msg_type:
            result = {
                "type": "result",
                "is_error": getattr(message, "is_error", False),
                "session_id": getattr(message, "session_id", ""),
                "total_cost_usd": getattr(message, "total_cost_usd", 0.0) or 0.0,
            }
            if hasattr(message, "usage") and message.usage:
                u = message.usage
                result["usage"] = {
                    "input_tokens": getattr(u, "input_tokens", 0),
                    "output_tokens": getattr(u, "output_tokens", 0),
                }
            yield result


async def run_bridge(config: dict) -> None:
    """Run the bridge in NDJSON-to-stdout mode for Swift Process consumption."""
    from claude_agent_sdk import query, ClaudeAgentOptions

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
            msg_type = getattr(message, "type", type(message).__name__).lower()

            if msg_type in SKIP_EVENTS:
                continue

            if "assistant" in msg_type:
                blocks = [convert_block(b) for b in (message.content if hasattr(message, "content") else [])]
                if blocks:
                    got_content = True
                emit({"type": "assistant", "message": {"role": "assistant", "content": blocks, "model": getattr(message, "model", None)}})

            elif "result" in msg_type:
                got_result = True
                result = {
                    "type": "result",
                    "subtype": "error" if getattr(message, "is_error", False) else "success",
                    "is_error": getattr(message, "is_error", False),
                    "session_id": getattr(message, "session_id", session_id),
                    "total_cost_usd": getattr(message, "total_cost_usd", 0.0) or 0.0,
                }
                if hasattr(message, "usage") and message.usage:
                    u = message.usage
                    result["usage"] = {
                        "input_tokens": getattr(u, "input_tokens", 0),
                        "output_tokens": getattr(u, "output_tokens", 0),
                        "cache_read_input_tokens": getattr(u, "cache_read_input_tokens", 0),
                        "cache_creation_input_tokens": getattr(u, "cache_creation_input_tokens", 0),
                    }
                emit(result)

            elif "user" in msg_type:
                blocks = [convert_block(b) for b in (message.content if hasattr(message, "content") else [])]
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
