//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Utilities/ConfidenceCalculator.swift.
//  Changes during the lift: confidence keys off the *effective* access level
//  (a member of a private type is effectively private, so "no references"
//  is proof, not suspicion).

// MARK: - Declaration confidence

extension Declaration {
    /// Confidence that a no-reference verdict means genuinely unused code,
    /// based on how far the declaration is visible.
    func unusedConfidence(context: CorpusContext) -> Confidence {
        switch context.effectiveAccess(of: self) {
        case .fileprivate, .private:
            .high
        case .internal, .package:
            .medium
        case .open, .public:
            .low
        }
    }
}
