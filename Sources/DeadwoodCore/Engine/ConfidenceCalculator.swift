//  Rewritten in deadwood (originally lifted from SwiftStaticAnalysis's
//  ConfidenceCalculator): composite confidence model.
//
//  - dead branches are dataflow proofs → certain
//  - the base comes from *effective* visibility (a member of a private type
//    is effectively private, so "no references" is proof, not suspicion)
//  - demotions capture dynamic-reference risk the reachability graph cannot
//    see: a name appearing in a string literal, and members of NSObject
//    subclasses without @objc (selector machinery may still reach them)

// MARK: - Base confidence

extension Declaration {
    /// Base confidence that a no-reference verdict means genuinely unused
    /// code, from how far the declaration is visible. Detectors filter on
    /// this; the mapper composes demotions on top.
    func unusedConfidence(context: CorpusContext) -> Confidence {
        switch context.effectiveAccess(of: self) {
        case .fileprivate, .private:
            .high
        case .internal:
            .medium
        case .package, .open, .public:
            .low
        }
    }
}

// MARK: - ConfidenceCalculator

/// Composes the final confidence and its demotion notes for a finding.
struct ConfidenceCalculator: Sendable {
    /// The composite verdict: the confidence to surface plus one note per
    /// demotion that produced it.
    struct Assessment: Sendable {
        var confidence: Confidence
        var demotionNotes: [String]
    }

    let context: CorpusContext

    init(context: CorpusContext) {
        self.context = context
    }

    /// Assess one engine result.
    func assess(_ item: UnusedCode) -> Assessment {
        switch item.reason {
        case .deadBranch:
            // SCCP proved the branch cannot execute — not a heuristic.
            return Assessment(confidence: .certain, demotionNotes: [])
        case .deadStore:
            // Dataflow-backed but conservative around aliasing/inout.
            return Assessment(confidence: .high, demotionNotes: [])
        case .neverReferenced, .onlyAssigned, .importNotUsed, .referencedOnlyByTests:
            break
        }

        var confidence = item.declaration.unusedConfidence(context: context)
        var notes: [String] = []

        if context.nameAppearsInStringLiteral(item.declaration.name) {
            confidence = .low
            notes.append("name appears in a string literal — possible dynamic reference")
        }

        if context.isObjcAdjacentMember(item.declaration) {
            confidence = demoted(confidence)
            notes.append("member of an NSObject subclass without @objc — selector dispatch may reach it")
        }

        return Assessment(confidence: confidence, demotionNotes: notes)
    }

    /// One step down, floored at `.low`.
    private func demoted(_ confidence: Confidence) -> Confidence {
        switch confidence {
        case .certain: .high
        case .high: .medium
        case .medium, .low: .low
        }
    }
}
