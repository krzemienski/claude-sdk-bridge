/// Swift Process spawner with environment variable sanitization.
///
/// This is the Swift side of the working bridge — it spawns the Python
/// bridge script as a subprocess and reads NDJSON from stdout.
///
/// ## Critical Patterns
///
/// 1. **Environment stripping**: Remove CLAUDECODE and CLAUDE_CODE_* vars
/// 2. **waitUntilExit() before terminationStatus**: Prevents NSInvalidArgumentException
/// 3. **GCD-based stdout reading**: No RunLoop dependency (avoids NIO/RunLoop mismatch)
/// 4. **Two-tier timeouts**: 30s initial + 5min total
///
/// ## Usage
///
/// ```swift
/// let executor = BridgeExecutor(bridgePath: "path/to/bridge.py")
/// let stream = executor.execute(prompt: "Hello Claude")
/// for try await message in stream {
///     // Handle StreamMessage
/// }
/// ```

import Foundation

/// Executor that spawns the Python bridge and streams results.
public final class BridgeExecutor: Sendable {
    private let bridgePath: String
    private let initialTimeout: TimeInterval
    private let totalTimeout: TimeInterval

    /// Thread-safe boolean for timeout state sharing across GCD queues.
    private final class AtomicBool: @unchecked Sendable {
        private var _value: Bool
        private let lock = NSLock()
        init(_ value: Bool) { _value = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    /// Create a new bridge executor.
    ///
    /// - Parameters:
    ///   - bridgePath: Absolute path to bridge.py
    ///   - initialTimeout: Seconds to wait for first stdout data (default: 30)
    ///   - totalTimeout: Maximum total execution time in seconds (default: 300)
    public init(
        bridgePath: String,
        initialTimeout: TimeInterval = 30,
        totalTimeout: TimeInterval = 300
    ) {
        self.bridgePath = bridgePath
        self.initialTimeout = initialTimeout
        self.totalTimeout = totalTimeout
    }

    /// Execute a prompt and stream back parsed JSON events.
    ///
    /// - Parameters:
    ///   - prompt: The user's message
    ///   - model: Optional model override
    ///   - sessionId: Optional session ID for conversation continuation
    /// - Returns: AsyncThrowingStream of parsed JSON dictionaries
    public func execute(
        prompt: String,
        model: String? = nil,
        sessionId: String? = nil
    ) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            // Build config JSON
            var options: [String: Any] = ["include_partial_messages": true]
            if let model { options["model"] = model }
            if let sessionId { options["session_id"] = sessionId }

            let config: [String: Any] = ["prompt": prompt, "options": options]
            let configJson: String
            if let data = try? JSONSerialization.data(withJSONObject: config),
               let str = String(data: data, encoding: .utf8) {
                configJson = str
            } else {
                continuation.finish(throwing: NSError(domain: "BridgeExecutor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode config"]))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")

            // CRITICAL: Strip Claude Code nesting detection env vars.
            //
            // Without this, running inside an active Claude Code session causes
            // the child Claude CLI to silently refuse execution. No error, no
            // stderr — just a zero-byte response.
            //
            // This fix took 10 hours to discover. The symptom was
            // "works in terminal, fails inside Claude Code."
            let escaped = configJson.replacingOccurrences(of: "'", with: "'\\''")
            let command = "python3 '\(bridgePath)' '\(escaped)'"
            let cleanCmd = "for v in $(env | grep ^CLAUDE | cut -d= -f1); do unset $v; done; \(command)"
            process.arguments = ["-l", "-c", cleanCmd]

            // Belt-and-suspenders: also strip from Process.environment
            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key.hasPrefix("CLAUDE") {
                env.removeValue(forKey: key)
            }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Close stdin immediately — bridge reads config from argv, not stdin
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.closeFile()

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()
                continuation.finish(throwing: error)
                return
            }

            // Two-tier timeout mechanism
            let didTimeout = AtomicBool(false)

            let initialTimeoutWork = DispatchWorkItem {
                didTimeout.value = true
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + self.initialTimeout,
                execute: initialTimeoutWork
            )

            let totalTimeoutWork = DispatchWorkItem {
                guard process.isRunning else { return }
                didTimeout.value = true
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + self.totalTimeout,
                execute: totalTimeoutWork
            )

            // Read NDJSON on a dedicated GCD queue (no RunLoop dependency)
            DispatchQueue(label: "bridge-reader", qos: .userInitiated).async {
                defer {
                    stdoutPipe.fileHandleForReading.closeFile()
                    stderrPipe.fileHandleForReading.closeFile()
                }

                let handle = stdoutPipe.fileHandleForReading
                var buffer = Data()

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }

                    initialTimeoutWork.cancel()  // Got data, cancel initial timeout
                    buffer.append(chunk)

                    guard let str = String(data: buffer, encoding: .utf8) else { continue }
                    let lines = str.components(separatedBy: "\n")

                    if lines.count > 1 {
                        for i in 0..<(lines.count - 1) {
                            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                            if !line.isEmpty,
                               let data = line.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                continuation.yield(json)
                            }
                        }
                        buffer = lines.last?.data(using: .utf8) ?? Data()
                    }
                }

                // Process remaining buffer
                if let remaining = String(data: buffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !remaining.isEmpty,
                   let data = remaining.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    continuation.yield(json)
                }

                // CRITICAL: Always waitUntilExit() before terminationStatus.
                // stdout EOF does NOT mean process has exited.
                // Accessing terminationStatus on a running Process throws
                // NSInvalidArgumentException.
                process.waitUntilExit()
                initialTimeoutWork.cancel()
                totalTimeoutWork.cancel()

                if process.terminationStatus != 0 && didTimeout.value {
                    continuation.yield([
                        "type": "error",
                        "code": "TIMEOUT",
                        "message": "Bridge timed out",
                    ])
                }

                continuation.finish()
            }
        }
    }
}
