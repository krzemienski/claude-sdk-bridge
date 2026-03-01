# Working Bridge

The production bridge that emerged after four failed attempts.

## Quick Start

```bash
# Install
pip install claude-agent-sdk

# Run directly
python3 bridge.py '{"prompt": "What is 2+2?", "options": {"model": "sonnet"}}'

# Or use the --prompt shorthand
python3 bridge.py --prompt "What is 2+2?"
```

## How It Works

1. **Swift** spawns `python3 bridge.py '<json-config>'` as a subprocess
2. **bridge.py** calls `claude_agent_sdk.query()` with async iteration
3. Each SDK event is converted to NDJSON and written to stdout
4. **Swift** reads stdout line-by-line and decodes each JSON line

## Files

| File | Language | Purpose |
|------|----------|---------|
| `bridge.py` | Python | SDK wrapper with NDJSON output |
| `executor.swift` | Swift | Process spawner with env sanitization |
| `pyproject.toml` | TOML | pip-installable package config |

## Critical Details

### Environment Variable Stripping (executor.swift)

```swift
var env = ProcessInfo.processInfo.environment
env.removeValue(forKey: "CLAUDECODE")
env = env.filter { !$0.key.hasPrefix("CLAUDE_CODE_") }
process.environment = env
```

Without this, running inside a Claude Code session causes silent failure.

### flush=True (bridge.py)

Every `sys.stdout.write()` must be followed by `sys.stdout.flush()`. Without explicit flushing, Python buffers output and breaks real-time streaming.

### waitUntilExit() (executor.swift)

Always call `process.waitUntilExit()` before `process.terminationStatus`. Reading stdout EOF does NOT mean the process has exited.
