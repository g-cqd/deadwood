//  Lifted from SwiftStaticAnalysis (MIT) — Configuration/DetectionMode.swift.
//  The `.indexStore` case is trimmed: deadwood is a pure syntax-level tool
//  with no IndexStoreDB dependency.

// MARK: - DetectionMode

/// Mode for unused code detection.
enum DetectionMode: String, Sendable, CaseIterable {
    /// Simple reference counting (fast, approximate; what single-file
    /// analysis uses).
    case simple

    /// Reachability graph analysis (more accurate, considers entry points;
    /// what corpus analysis uses).
    case reachability
}
