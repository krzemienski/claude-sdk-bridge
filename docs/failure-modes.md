# Failure Modes Catalog

A comprehensive catalog of failure modes encountered while building a bridge between iOS/Swift and Claude Code. Each failure mode includes the exact symptom, root cause, and fix.

## 1. RunLoop/NIO Deadlock

**Symptom**: AsyncStream never yields any values. No errors, no crashes, no output.

**Root Cause**: `ClaudeCodeSDK` uses `FileHandle.readabilityHandler` + Combine `PassthroughSubject`, which require `RunLoop` scheduling. Vapor/SwiftNIO uses `EventLoop`, which does not pump `RunLoop`. Publisher emissions are silently dropped.

**Detection**: Add logging to `PassthroughSubject.send()` — you'll see data being sent but never received by the subscriber.

**Fix**: Bypass the SDK. Use direct `Process` with `DispatchQueue`-based stdout reading (no RunLoop dependency).

**Severity**: Fatal. No workaround within the SDK's architecture.

## 2. Nesting Detection Environment Variables

**Symptom**: Claude CLI exits immediately with no output. No error, no stderr. Zero-byte response.

**Root Cause**: Claude Code sets `CLAUDECODE=1` and `CLAUDE_CODE_*` environment variables. Child processes inherit these. The CLI's nesting detection mechanism silently refuses to execute when it detects a parent Claude Code session.

**Detection**: Compare `env` output between a standalone terminal and the subprocess environment. Look for `CLAUDECODE=1`.

**Fix**:
```swift
var env = ProcessInfo.processInfo.environment
env.removeValue(forKey: "CLAUDECODE")
env = env.filter { !$0.key.hasPrefix("CLAUDE_CODE_") }
process.environment = env
```

**Severity**: Fatal in development (when running backend inside Claude Code). Silent in production (where these env vars aren't present).

## 3. NSTask terminationStatus Crash

**Symptom**: `NSInvalidArgumentException` when accessing `process.terminationStatus`.

**Root Cause**: Reading EOF from a pipe does not mean the process has exited. There is a race condition between pipe closure and process termination. Accessing `terminationStatus` on a still-running `Process` throws an Objective-C exception.

**Detection**: Crash log shows `NSInvalidArgumentException` with no obvious argument validation issue.

**Fix**:
```swift
process.waitUntilExit()  // MUST call first
let status = process.terminationStatus  // Safe now
```

**Severity**: Crash. Misleading exception type sends you down the wrong diagnostic path.

## 4. Python stdout Buffering

**Symptom**: Real-time streaming appears broken. No output for seconds, then a burst of text, then silence again.

**Root Cause**: Python's default stdout buffering delays output when writing to a pipe (non-TTY). The parent process sees delayed, batched output instead of real-time token-by-token delivery.

**Detection**: Add timestamps to both Python writes and Swift reads. You'll see Python writing continuously but Swift receiving data in bursts.

**Fix**:
```python
sys.stdout.write(line + "\n")
sys.stdout.flush()  # Critical: force immediate delivery
```

**Severity**: UX-breaking but not fatal. The data eventually arrives, just not in real time.

## 5. Text Duplication (P2 Bug)

**Symptom**: Every streamed response appears twice. "Hello" becomes "HelloHello".

**Root Cause**: Two contributing causes:

1. **`+=` vs `=` for assistant messages**: Each `assistant` event contains the accumulated text, not just the new token. Using `+=` on already-accumulated text doubles it.

2. **Message index reset**: When the stream ends, resetting `lastProcessedMessageIndex` to 0 causes the message loop to replay all messages from the beginning.

**Fix**:
```swift
// Fix 1: Assignment for assistant events (accumulated text)
message.text = textBlock.text  // NOT +=

// Fix 2: Preserve high-water mark on stream end
let finalCount = sseClient.messages.count
self.lastProcessedMessageIndex = finalCount  // NOT 0
```

**Severity**: Data corruption (visual). Two bugs, same symptom, different layers.

## 6. OAuth Authentication Boundary

**Symptom**: `AuthenticationError: No API key provided` or `401 invalid x-api-key`.

**Root Cause**: Claude Code uses browser-based OAuth authentication. Session tokens are managed internally by the CLI and stored in `~/.claude/`. They are not exposed as environment variables or through any public API. Direct API calls require `ANTHROPIC_API_KEY`, which doesn't exist in a Claude Code environment.

**Fix**: Use the Claude CLI (or a wrapper like `claude-agent-sdk`) instead of calling the API directly. The CLI handles the OAuth token chain.

**Severity**: Architectural. Cannot be fixed without changing the authentication approach.

## 7. Port Collision

**Symptom**: API responses contain unexpected data formats. Serialization errors. Data that looks like it comes from a different application.

**Root Cause**: Multiple localhost services using the same port. In ILS, the backend runs on port 9999, but port 8080 (a common default) was already used by another project.

**Detection**: `lsof -i :PORT -P -n` — verify the binary path matches your expected server.

**Fix**: Assign and document explicit ports. Never use framework defaults (8080, 3000, etc.) without checking.

**Severity**: Hours of debugging symptoms that look like serialization bugs.
