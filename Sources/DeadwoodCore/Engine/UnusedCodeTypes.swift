//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Models/UnusedCodeTypes.swift.
//  Trimmed: `UnusedCodeReport` (deadwood reports through `AnalysisReport`).

import AemiJSON
import ProjectModel

// MARK: - UnusedReason

/// Reasons why code is considered unused.
enum UnusedReason: String, Sendable, Codable {
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
    /// Production code reachable only from previews.
    case referencedOnlyByPreviews
    /// Production code reachable only from `#if DEBUG` code.
    case referencedOnlyByDebugCode
    /// Used, but only by declarations that are dead themselves.
    case onlyUsedByDeadCode
    /// Used only within a cycle of declarations nothing live reaches.
    case deadCycle
}

// MARK: - Confidence

/// Confidence level for unused code detection, ordered `low` < `medium` < `high` < `certain`.
public enum Confidence: String, Sendable, Comparable, CaseIterable, Codable {
    /// Proven by dataflow analysis (dead branches): not a heuristic.
    case certain

    /// Definitely unused (effectively private, no references found).
    case high

    /// Likely unused (internal, no visible references in the corpus).
    case medium

    /// Possibly unused (public API, may be used externally).
    case low

    public static func < (lhs: Self, rhs: Self) -> Bool {
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
@JSONCodable
struct UnusedCode: Sendable, Codable {
    /// The unused declaration (synthetic for dead branches).
    let declaration: Declaration

    /// Reason it's considered unused.
    let reason: UnusedReason

    /// Confidence level.
    let confidence: Confidence

    /// Suggested action.
    let suggestion: String
    /// For dead-code groups: the dead users of a member, or the size of a
    /// root's group.
    let detail: String?
    /// `CodeRegion.rawValue` of an `--include`d region this finding exists
    /// only because of (a generated declaration, or a preview/debug-only
    /// use promoted from a note): the note names it, so it can be filtered.
    /// Zero for an ordinary finding.
    let regionTag: UInt8

    init(
        declaration: Declaration,
        reason: UnusedReason,
        confidence: Confidence,
        suggestion: String = "Consider removing this declaration",
        detail: String? = nil,
        regionTag: UInt8 = 0
    ) {
        self.declaration = declaration
        self.reason = reason
        self.confidence = confidence
        self.suggestion = suggestion
        self.detail = detail
        self.regionTag = regionTag
    }

    init(
        declaration: Declaration,
        reason: UnusedReason,
        confidence: Confidence,
        suggestion: String = "Consider removing this declaration",
        detail: String? = nil,
        regionTag: CodeRegion
    ) {
        self.init(
            declaration: declaration, reason: reason, confidence: confidence, suggestion: suggestion,
            detail: detail, regionTag: regionTag.rawValue)
    }
}
