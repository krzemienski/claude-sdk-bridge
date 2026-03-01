# Attempt 4: Direct CLI Subprocess — PARTIALLY FAILED

## What Was Tried

Bypass all SDKs and spawn the Claude CLI directly as a `Process` (née `NSTask`) with GCD-based stdout reading. No RunLoop dependency, no Combine, just `DispatchQueue` handlers on a `Pipe`.

## The Behavior

**Works perfectly** when running the backend from a standalone terminal.

**Fails silently** when running inside an active Claude Code session (i.e., developing the backend using Claude Code).

## Root Cause: Nesting Detection Environment Variables

Claude CLI includes a nesting detection mechanism. When you run `claude` from within a Claude Code session, the CLI checks for:

- `CLAUDECODE=1` — signals an active parent session
- `CLAUDE_CODE_*` — prefixed variables carrying session metadata

If detected, the CLI silently refuses to execute as a safety measure against recursive agent loops.

The subprocess inherits the parent process's full environment, including these variables. The symptom is "Claude CLI exits immediately with no output" — no error, no stderr, just a zero-byte response.

## The Fix (Three Lines, Ten Hours to Find)

```swift
var env = ProcessInfo.processInfo.environment
env.removeValue(forKey: "CLAUDECODE")
env = env.filter { !$0.key.hasPrefix("CLAUDE_CODE_") }
process.environment = env
```

## Bonus Bug: NSTask terminationStatus Crash

While debugging this attempt, accessing `process.terminationStatus` after reading EOF from stdout caused `NSInvalidArgumentException`. Reading EOF from a pipe does **not** mean the process has exited — there's a race condition.

**Fix**: Always call `process.waitUntilExit()` before accessing `terminationStatus`.

## Why This Attempt Was Partially Successful

With env var stripping, direct CLI execution works. But it led to an increasingly complex Swift parser for Claude's streaming JSON format, which prompted the move to the Python SDK wrapper (Attempt 5) that handles this parsing natively.

## Time Lost

**Ten hours** on the nesting detection issue alone. The environment-dependent failure (works in terminal, fails in Claude Code) made it extremely hard to diagnose.

## Key Lessons

1. **Environment variables are ambient authority.** The subprocess didn't ask to be inside a Claude Code session. It inherited that context silently and failed silently.
2. **If you're spawning subprocesses from a server context, audit the inherited environment. Always.**
3. **Always call `waitUntilExit()` before `terminationStatus`.** This is documented but the crash message (`NSInvalidArgumentException`) is misleading enough to send you down the wrong diagnostic path.
