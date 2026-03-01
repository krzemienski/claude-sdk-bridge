/// Attempt 4: Direct CLI Subprocess via Process (née NSTask)
///
/// This approach works in isolation but fails inside active Claude Code
/// sessions due to nesting detection environment variables.
///
/// It also contains a sharp edge: accessing `process.terminationStatus`
/// before calling `process.waitUntilExit()` throws NSInvalidArgumentException.

import Foundation

/// Execute a Claude CLI query by spawning it as a subprocess.
///
/// Uses `DispatchQueue`-based stdout reading — no RunLoop dependency,
/// no Combine, just GCD dispatch handlers on a pipe.
///
/// **This works when run from a standalone terminal.**
/// **This fails silently when run inside an active Claude Code session.**
///
/// The failure is caused by environment variable inheritance:
/// - `CLAUDECODE=1` signals the parent Claude Code session
/// - `CLAUDE_CODE_*` variables carry session metadata
/// - The child process inherits these and refuses to execute
func executeClaudeDirectly(prompt: String) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
    process.arguments = ["-p", prompt, "--output-format", "stream-json"]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // BUG: This inherits ALL environment variables from the parent process,
    // including CLAUDECODE=1 and CLAUDE_CODE_* if running inside Claude Code.
    // The child Claude CLI detects these and silently refuses to execute.
    //
    // Symptom: Claude CLI exits immediately with no output — no error,
    // no stderr, just a zero-byte response that NDJSON parser interprets
    // as an empty stream.
    //
    // The fix (discovered after 10 hours):
    //
    //   var env = ProcessInfo.processInfo.environment
    //   env.removeValue(forKey: "CLAUDECODE")
    //   env = env.filter { !$0.key.hasPrefix("CLAUDE_CODE_") }
    //   process.environment = env
    //
    // Three lines. Ten hours to find them.

    var collectedOutput = ""

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        DispatchQueue.global().async {
            if let text = String(data: data, encoding: .utf8) {
                collectedOutput += text
            }
        }
    }

    try process.run()

    // CRASH BUG: Reading terminationStatus before the process exits.
    //
    // Reading EOF from stdout does NOT mean the process has exited.
    // There is a race condition between the pipe closing (all output
    // consumed) and the process actually terminating.
    //
    // WRONG — causes NSInvalidArgumentException:
    //   let status = process.terminationStatus  // Process still running!
    //
    // CORRECT — wait first, then read:
    //   process.waitUntilExit()
    //   let status = process.terminationStatus  // Safe now

    process.waitUntilExit()  // MUST call before accessing terminationStatus
    let status = process.terminationStatus

    if status != 0 {
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? "Unknown error"
        throw NSError(
            domain: "ClaudeExecutor",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: errText]
        )
    }

    return collectedOutput
}

/// Demonstrates the fix: strip nesting detection env vars before spawning.
///
/// This is the three-line fix that makes direct CLI execution work inside
/// active Claude Code sessions.
func executeClaudeWithEnvStripping(prompt: String) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-l", "-c", "claude -p '\(prompt)' --output-format stream-json"]

    // THE FIX: Strip nesting detection environment variables
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "CLAUDECODE")
    env = env.filter { !$0.key.hasPrefix("CLAUDE_CODE_") }
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: outputData, encoding: .utf8) ?? ""
}
