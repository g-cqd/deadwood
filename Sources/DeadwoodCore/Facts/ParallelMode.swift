//  Lifted from SwiftStaticAnalysis (MIT) — Configuration/ParallelMode.swift.
//  Trimmed: the streaming-verifier plumbing (`usesStreamingVerifier`) and
//  legacy-boolean bridging, which belonged to the deleted duplication
//  pipeline.

// MARK: - ParallelMode

/// Parallel execution mode for analysis operations.
///
/// - `none`: sequential execution, deterministic, lowest memory usage.
/// - `safe`: default parallel behaviour (TaskGroup-based), deterministic
///   via ordered aggregation.
/// - `maximum`: higher concurrency (`highThroughput` preset) for machines
///   with headroom.
enum ParallelMode: String, Sendable, CaseIterable {
    /// Sequential execution. No parallelism. Deterministic.
    case none

    /// TaskGroup-based parallelism with an ordered merge. Recommended
    /// default for most codebases.
    case safe

    /// Higher-concurrency execution (`highThroughput` preset).
    case maximum

    /// The concurrency limits this mode implies.
    var concurrencyConfiguration: ConcurrencyConfiguration {
        switch self {
        case .none:
            .serial
        case .safe:
            .default
        case .maximum:
            .highThroughput
        }
    }
}
