# Attempt 2: ClaudeCodeSDK in Vapor — FAILED

## What Was Tried

Integrate Anthropic's `ClaudeCodeSDK` Swift package directly into the Vapor backend. Same language, same ecosystem — seemed purpose-built for this scenario.

## The Exact Behavior

Nothing happened. No errors. No crashes. No output. The `AsyncStream` returned by the SDK simply never yielded a single value.

```swift
let stream = claude.stream(prompt: "Say hello")
for try await chunk in stream {
    // This line is never reached
    response += chunk
}
// Execution hangs here forever
```

## Root Cause: RunLoop/NIO Impedance Mismatch

The SDK internally uses `FileHandle.readabilityHandler` to read stdout from the Claude CLI subprocess. That handler dispatches events through `RunLoop`. The events flow through a Combine `PassthroughSubject`, which also depends on `RunLoop` scheduling.

**Vapor runs on SwiftNIO.** SwiftNIO uses its own event loop implementation (`EventLoop`, not `RunLoop`). The NIO event loops **never pump RunLoop**. So:

1. The Claude CLI process spawns correctly
2. Claude receives the prompt and generates a response
3. Bytes arrive on stdout
4. `readabilityHandler` fires and reads the data
5. `PassthroughSubject.send()` is called with the data
6. **The subscriber callback never executes** because no `RunLoop` iteration delivers the event

The data exists. It was read. It was sent into the publisher. And then it vanishes into a scheduling void.

## Why It Fails Fundamentally

This is an **architectural incompatibility**, not a bug:

| Component | Scheduling Mechanism |
|-----------|---------------------|
| `FileHandle.readabilityHandler` | RunLoop |
| Combine `PassthroughSubject` | RunLoop |
| Vapor/SwiftNIO | EventLoop (cooperative) |

Apple's documentation treats `RunLoop` as the default scheduling mechanism for Foundation callbacks. But modern Swift server frameworks — Vapor, Hummingbird, anything on SwiftNIO — use cooperative task executors and NIO event loops. **Any library that assumes RunLoop availability is quietly incompatible with server-side Swift.**

## Workarounds Attempted

| Workaround | Result |
|------------|--------|
| Manually pump RunLoop on background thread | Deadlock: NIO EventLoop and RunLoop contend |
| `DispatchQueue.main.async` wrapper | Moves silent failure to different layer |
| Dedicated Thread with own RunLoop | Event ordering issues, potential deadlocks |

## Time Lost

**Two full days.** Most of that time was spent verifying the SDK *was* receiving data — adding logging at every layer, confirming `PassthroughSubject.send()` was being called, slowly narrowing the gap to the subscriber side.

The silence was the hardest part. If the SDK had thrown an error or logged a warning, this would have been a 30-minute fix.

## Key Lesson

**Silent failures are worse than crashes.** When something explodes, you know where to look. When something silently does nothing, you question whether you understand how computers work. The RunLoop/NIO mismatch is not documented as a limitation anywhere. It manifests as "the callback never fires" with zero diagnostic output.
