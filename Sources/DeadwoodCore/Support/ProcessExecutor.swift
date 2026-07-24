//  Lifted from SwiftStaticAnalysis (MIT) — Utilities/ProcessExecutor.swift.
//  Changes during the lift:
//  - The upstream watchdog scheduled a global-queue timer (a GCD work item)
//    to terminate a hung child. deadwood forbids GCD (Scripts/no-gcd.sh gates
//    it), so the timeout is rewritten as a structured-concurrency race: a
//    `ContinuousClock`-backed `Task.sleep` deadline against the process's
//    `terminationHandler`, joined in a `TaskGroup`; on deadline expiry the
//    child is `terminate()`d. `run` is therefore `async` (its only caller,
//    the index auto-build, already is).
//  - A synchronous, timeout-free `runUntilExit` is kept for instant commands
//    (`xcrun --find`) so the index-store reader's initializer stays sync.
//  - `AnalysisLogger` and the plugin-host commentary are dropped.

import Foundation
import Synchronization

// MARK: - ProcessExecutor

/// Spawns short-lived subprocesses (`swift build`, `xcodebuild`, `xcrun`)
/// with a **scrubbed environment** — only the allowlisted variables below
/// are inherited from the parent. This prevents environment-based
/// influences (`DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`, `SWIFTPM_HOOKS_DIR`,
/// `LD_LIBRARY_PATH`, etc.) from changing how the child resolves toolchain
/// binaries or libraries.
enum ProcessExecutor {
    /// Environment variables inherited from the parent. Anything else is
    /// dropped — including `DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`,
    /// `SWIFTPM_HOOKS_DIR`, all `LD_*` / `DYLD_*` overrides.
    ///
    /// The list intentionally excludes shell-related variables (`SHELL`,
    /// `BASH_ENV`) and IFS-style settings that have historically been vectors
    /// for privilege-escalation chains.
    static let allowedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL",
        "LC_CTYPE", "LC_MESSAGES", "TMPDIR", "TERM",
    ]

    /// Result of a subprocess invocation.
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        /// `true` if the process exited normally with code 0.
        var succeeded: Bool { exitCode == 0 }
    }

    /// Errors raised by `ProcessExecutor`.
    enum Error: Swift.Error, Sendable {
        case launchFailed(executable: String, underlying: String)
        case timedOut(executable: String, after: Duration)
    }

    /// Default subprocess timeout. The CLI never legitimately needs to block
    /// on a child for longer than two minutes; an unresponsive
    /// `swiftc`/`xcrun` past this point is hung and should be killed instead
    /// of stalling the analyzer.
    static let defaultTimeout: Duration = .seconds(120)

    /// Run a subprocess with a scrubbed environment and a structured-
    /// concurrency timeout.
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the binary.
    ///   - arguments: Command-line arguments (the binary name is NOT
    ///     prepended; it's implicit in `executable`).
    ///   - currentDirectory: Optional working directory.
    ///   - environmentOverrides: Additional environment variables on top of
    ///     the allowlist.
    ///   - timeout: Maximum wall-clock time the child may run. After this the
    ///     process is `terminate()`d and the call throws `Error.timedOut`.
    /// - Returns: stdout / stderr / exit code.
    /// - Throws: `Error.launchFailed` if `Process.run()` throws; `.timedOut`
    ///   if the deadline expires before exit.
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        timeout: Duration = defaultTimeout
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd = currentDirectory {
            process.currentDirectoryURL = cwd
        }
        process.environment = scrubbedEnvironment(overrides: environmentOverrides)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // One-shot exit gate signalled from `terminationHandler`. Both the
        // gate and the process box are `Sendable`, so the timeout race never
        // shares mutable Swift state across tasks.
        let gate = ExitGate()
        process.terminationHandler = { _ in gate.markExited() }

        do {
            try process.run()
        } catch {
            throw Error.launchFailed(
                executable: executable.path,
                underlying: error.localizedDescription
            )
        }

        let timedOut = await Self.awaitExitOrTimeout(
            process: ProcessBox(value: process),
            gate: gate,
            timeout: timeout
        )

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if timedOut {
            throw Error.timedOut(executable: executable.path, after: timeout)
        }

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Run a subprocess synchronously with a scrubbed environment and **no**
    /// timeout. Reserved for instant, trusted commands (`xcrun --find`) so
    /// callers on a synchronous path (the index-store reader's initializer)
    /// keep the environment scrub without inheriting an async signature. No
    /// GCD is involved: it is a plain `run()` + `waitUntilExit()`.
    static func runUntilExit(
        executable: URL,
        arguments: [String],
        environmentOverrides: [String: String] = [:]
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = scrubbedEnvironment(overrides: environmentOverrides)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw Error.launchFailed(
                executable: executable.path,
                underlying: error.localizedDescription
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Compose the child environment from the allowlist plus any explicit
    /// overrides.
    static func scrubbedEnvironment(
        overrides: [String: String] = [:],
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in allowedEnvironmentKeys {
            if let value = source[key] {
                env[key] = value
            }
        }
        for (key, value) in overrides {
            env[key] = value
        }
        return env
    }

    // MARK: - Structured-concurrency timeout

    /// Race the child's termination against the deadline. Returns `true` iff
    /// the deadline fired first (in which case the child was terminated).
    ///
    /// Replaces the upstream GCD deferred-work watchdog: a `Task.sleep`
    /// deadline and a `terminationHandler`-fed exit gate are joined in a
    /// `TaskGroup`; whichever resolves first wins. On timeout the child is
    /// terminated inside the group so its exit gate resolves and the group's
    /// implicit join cannot deadlock.
    private static func awaitExitOrTimeout(
        process: ProcessBox,
        gate: ExitGate,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await gate.wait()
                return false  // exited normally
            }
            group.addTask {
                try? await Task.sleep(for: timeout, clock: .continuous)
                return true  // deadline expired
            }

            let deadlineWon = await group.next() ?? false
            if deadlineWon, process.value.isRunning {
                process.value.terminate()
            }
            group.cancelAll()
            return deadlineWon
        }
    }
}

// MARK: - ExitGate

/// One-shot, `Sendable` gate resolved by a `Process.terminationHandler`.
/// The `Mutex` closes the race between "handler fires before anyone waits"
/// and "waiter suspends before the handler fires": whichever happens first,
/// the waiter is resumed exactly once.
private final class ExitGate: Sendable {
    private struct State {
        var exited = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// Mark the process exited and resume a suspended waiter, if any.
    func markExited() {
        let waiter = state.withLock { current -> CheckedContinuation<Void, Never>? in
            current.exited = true
            let waiter = current.waiter
            current.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Suspend until the process has exited (or return immediately if it
    /// already has).
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyExited = state.withLock { current -> Bool in
                if current.exited { return true }
                current.waiter = continuation
                return false
            }
            if alreadyExited { continuation.resume() }
        }
    }
}

// MARK: - ProcessBox

/// SAFETY: `Process.terminate()` and `isRunning` are documented thread-safe.
/// This box exists solely to let the structured-concurrency timeout deliver a
/// single `terminate()` on deadline expiry; no mutable Swift state is shared
/// across the boundary, so the `@unchecked Sendable` is sound. It replaces the
/// upstream GCD watchdog's `[weak process]` capture.
private struct ProcessBox: @unchecked Sendable {
    let value: Process
}
