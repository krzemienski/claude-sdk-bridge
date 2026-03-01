/// Attempt 2: ClaudeCodeSDK in Vapor
///
/// Anthropic ships a Swift SDK — `ClaudeCodeSDK` — designed for this scenario.
/// It wraps the Claude CLI process, handles authentication, and provides a
/// publisher-based streaming interface using Combine's PassthroughSubject.
///
/// The SDK silently fails when used inside Vapor because of a RunLoop/NIO
/// impedance mismatch. No errors, no crashes — just an AsyncStream that
/// never yields.

import Foundation
import Vapor

// This is what the ClaudeCodeSDK does internally (simplified)
// to read stdout from the Claude CLI subprocess:
//
//   let pipe = Pipe()
//   pipe.fileHandleForReading.readabilityHandler = { handle in
//       let data = handle.availableData
//       subject.send(data)  // Combine PassthroughSubject
//   }
//
// The readabilityHandler dispatches through RunLoop.
// The PassthroughSubject also depends on RunLoop scheduling.
// Vapor runs on SwiftNIO, which uses EventLoop — NOT RunLoop.
// NIO event loops never pump RunLoop, so the subscriber never fires.

/// Demonstrates the ClaudeCodeSDK integration that silently fails in Vapor.
///
/// This route handler initializes the SDK, sends a prompt, and waits for
/// streaming responses. In a Vapor context, the AsyncStream never yields
/// any values because the RunLoop is never pumped.
func attemptClaudeCodeSDK(req: Request) async throws -> Response {
    // The SDK initializes correctly — no errors here
    let claude = ClaudeCodeProcess()

    // Configuration also works fine
    claude.arguments = ["-p", "--output-format", "stream-json"]

    // The process spawns, Claude receives the prompt, generates a response,
    // bytes arrive on stdout, readabilityHandler fires, PassthroughSubject.send()
    // is called... and then nothing. The subscriber callback never executes.
    let stream = claude.stream(prompt: "Say hello")

    // This loop runs forever, waiting for values that will never arrive.
    // No timeout, no error, no diagnostic output of any kind.
    var response = ""
    for try await chunk in stream {
        response += chunk  // Never reached
    }

    return Response(status: .ok, body: .init(string: response))
}

// Workarounds that were attempted (all failed):

/// Workaround 1: Manually pump RunLoop on a background thread.
/// Result: Deadlock. NIO's EventLoop and RunLoop contend for the same thread.
func workaround1_manualRunLoop() {
    let thread = Thread {
        let runLoop = RunLoop.current
        runLoop.add(Port(), forMode: .default)
        runLoop.run()  // Blocks forever, doesn't help NIO
    }
    thread.start()
}

/// Workaround 2: Wrap subscription in DispatchQueue.main.async.
/// Result: Moves the silent failure to a different layer. Events are
/// dispatched but the Combine pipeline still depends on RunLoop.
func workaround2_dispatchMain() {
    DispatchQueue.main.async {
        // subscriber.receive still requires RunLoop scheduling
        // This just moves the problem, doesn't solve it
    }
}

/// Workaround 3: Create a dedicated Thread with its own RunLoop.
/// Result: Event ordering issues and potential deadlocks when the
/// RunLoop thread and NIO EventLoop thread compete for resources.
func workaround3_dedicatedThread() {
    let runLoopThread = Thread {
        let loop = RunLoop.current
        // Even with a dedicated RunLoop, Combine's internal scheduling
        // doesn't guarantee delivery to the correct thread
        loop.run()
    }
    runLoopThread.start()
}

// MARK: - Stub types for compilation context

/// Placeholder representing the ClaudeCodeSDK's process wrapper.
/// The real SDK uses FileHandle.readabilityHandler + Combine PassthroughSubject.
struct ClaudeCodeProcess {
    var arguments: [String] = []

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // In the real SDK, this sets up:
            // 1. Process with stdout Pipe
            // 2. readabilityHandler on the pipe's fileHandleForReading
            // 3. PassthroughSubject that the handler sends data to
            // 4. Subscriber that maps data to the AsyncStream continuation
            //
            // Steps 1-3 work correctly.
            // Step 4 silently fails because no RunLoop pumps the subscriber.
            //
            // The continuation.yield() is never called.
            // The continuation.finish() is never called.
            // The stream hangs indefinitely.
        }
    }
}
