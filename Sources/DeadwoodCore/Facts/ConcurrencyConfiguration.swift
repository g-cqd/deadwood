//  Lifted from SwiftStaticAnalysis (MIT) — Concurrency/ConcurrencyConfiguration.swift.
//  Changes during the lift:
//  - `chunks(ofCount:)` (swift-algorithms) replaced by `chunkedSlices` from
//    CollectionShims.
//  - `forEach` dropped (nothing in this tool runs side-effect-only batches).
//  - `map` no longer throws: the parse pipeline is error-tolerant.

import Foundation

// MARK: - ConcurrencyConfiguration

/// Configuration for parallel processing in analysis operations.
///
/// Setting `maxConcurrentFiles == 1` forces serial execution;
/// `ParallelProcessor` codepaths key off the cap alone.
struct ConcurrencyConfiguration: Sendable {
    /// Default configuration based on system capabilities.
    static let `default` = Self()

    /// Single-threaded configuration (for debugging or testing).
    static let serial = Self(maxConcurrentFiles: 1)

    /// High-throughput configuration for powerful machines.
    static let highThroughput = Self(
        maxConcurrentFiles: ProcessInfo.processInfo.activeProcessorCount * 2
    )

    /// Maximum number of files to process concurrently.
    let maxConcurrentFiles: Int

    init(maxConcurrentFiles: Int? = nil) {
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        self.maxConcurrentFiles = max(1, maxConcurrentFiles ?? processorCount)
    }
}

// MARK: - ParallelProcessor

/// Utilities for parallel processing with a strict concurrency cap.
enum ParallelProcessor {
    /// Process items in parallel, preserving input order in the result.
    ///
    /// Uses the streaming-bounded pattern (start `maxConcurrency` tasks,
    /// add a new one each time one completes) — no batch barriers, so fast
    /// items don't wait for a slow neighbour's chunk.
    static func map<T: Sendable, R: Sendable>(
        _ items: [T],
        maxConcurrency: Int,
        operation: @Sendable @escaping (T) async -> R
    ) async -> [R] {
        guard !items.isEmpty else { return [] }
        let cap = max(1, maxConcurrency)

        return await withTaskGroup(of: (Int, R).self) { group in
            var iterator = items.enumerated().makeIterator()
            var inFlight = 0

            // Prime up to the concurrency cap.
            while inFlight < cap, let next = iterator.next() {
                let (index, item) = next
                group.addTask { (index, await operation(item)) }
                inFlight += 1
            }

            // Drain completions, replacing each finished slot with the next
            // pending item. Order-preserving via `index`.
            var indexedResults: [(Int, R)] = []
            indexedResults.reserveCapacity(items.count)
            while let result = await group.next() {
                indexedResults.append(result)
                inFlight -= 1
                if let next = iterator.next() {
                    let (index, item) = next
                    group.addTask { (index, await operation(item)) }
                    inFlight += 1
                }
            }
            return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Process items in parallel, collecting only non-nil results
    /// (order not guaranteed).
    static func compactMap<T: Sendable, R: Sendable>(
        _ items: [T],
        maxConcurrency: Int,
        operation: @Sendable @escaping (T) async -> R?
    ) async -> [R] {
        guard !items.isEmpty else { return [] }
        let cap = max(1, maxConcurrency)

        return await withTaskGroup(of: R?.self) { group in
            var iterator = items.makeIterator()
            var inFlight = 0

            while inFlight < cap, let item = iterator.next() {
                group.addTask { await operation(item) }
                inFlight += 1
            }

            var results: [R] = []
            while let result = await group.next() {
                inFlight -= 1
                if let result {
                    results.append(result)
                }
                if let item = iterator.next() {
                    group.addTask { await operation(item) }
                    inFlight += 1
                }
            }
            return results
        }
    }
}
