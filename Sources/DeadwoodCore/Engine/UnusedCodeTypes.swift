//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Models/UnusedCodeTypes.swift.
//  Trimmed: `UnusedCodeReport` (deadwood reports through `AnalysisReport`).

// MARK: - UnusedReason

/// Reasons why code is considered unused.
enum UnusedReason: String, Sendable {
    /// Declaration is never referenced anywhere.
    case neverReferenced

    /// Variable is assigned but never read.
    case onlyAssigned

    /// Import statement is not used.
    case importNotUsed

    /// Branch of an `if`/`guard`/`while` provably never executes — gated by
    /// a condition that folds to a constant (SCCP dead-branch pass).
    case deadBranch

    /// A store whose value is overwritten before any read (liveness +
    /// reaching definitions).
    case deadStore

    /// Reachable with test entry points, unreachable without them —
    /// production mode only.
    case referencedOnlyByTests
}

// MARK: - Confidence

/// Confidence level for unused code detection.
enum Confidence: String, Sendable, Comparable, CaseIterable {
    /// Proven by dataflow analysis (dead branches): not a heuristic.
    case certain

    /// Definitely unused (effectively private, no references found).
    case high

    /// Likely unused (internal, no visible references in the corpus).
    case medium

    /// Possibly unused (public API, may be used externally).
    case low

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .certain: 4
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }
}

// MARK: - UnusedCode

/// A piece of unused code, as detected by the engine.
struct UnusedCode: Sendable {
    /// The unused declaration (synthetic for dead branches).
    let declaration: Declaration

    /// Reason it's considered unused.
    let reason: UnusedReason

    /// Confidence level.
    let confidence: Confidence

    /// Suggested action.
    let suggestion: String

    init(
        declaration: Declaration,
        reason: UnusedReason,
        confidence: Confidence,
        suggestion: String = "Consider removing this declaration"
    ) {
        self.declaration = declaration
        self.reason = reason
        self.confidence = confidence
        self.suggestion = suggestion
    }
}
