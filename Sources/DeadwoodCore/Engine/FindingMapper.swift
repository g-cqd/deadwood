//  New in deadwood: maps engine `UnusedCode` results onto the stable
//  `Finding` contract (rule ids, severities, messages), collapsing member
//  findings into their flagged enclosing type.

// MARK: - FindingMapper

/// Maps `UnusedCode` results to `Finding`s per the deadwood configuration.
struct FindingMapper: Sendable {
    /// The user-facing configuration (rule toggles + severities).
    let configuration: Configuration

    /// Detection mode, for message wording (single file vs corpus).
    let mode: DetectionMode

    init(configuration: Configuration, mode: DetectionMode) {
        self.configuration = configuration
        self.mode = mode
    }

    /// Convert engine results into findings: rule per declaration kind,
    /// public API routed to `unused-public-api`, disabled rules dropped,
    /// members of flagged types collapsed into the type's finding.
    func findings(from unused: [UnusedCode], context: CorpusContext) -> [Finding] {
        // Collapse: when a type is flagged, its members are implied — one
        // finding on the type reads better than one per member.
        let flaggedTypeKeys = Set(
            unused
                .filter { Self.typeKinds.contains($0.declaration.kind) }
                .map { key(of: $0.declaration) }
        )

        var findings: [Finding] = []
        for item in unused {
            if item.reason != .deadBranch, isInsideFlaggedType(item.declaration, flaggedTypeKeys, context) {
                continue
            }
            if let finding = finding(from: item, context: context) {
                findings.append(finding)
            }
        }
        return findings
    }

    /// Map one engine result to a finding; nil when its rule is disabled or
    /// the declaration kind has no rule.
    func finding(from item: UnusedCode, context: CorpusContext) -> Finding? {
        guard let rule = rule(for: item, context: context) else { return nil }
        guard configuration.isEnabled(rule) else { return nil }

        return Finding(
            rule: rule,
            severity: configuration.severity(for: rule),
            path: item.declaration.location.file,
            line: item.declaration.location.line,
            column: item.declaration.location.column,
            message: message(for: item, rule: rule),
            note: note(for: item)
        )
    }

    // MARK: - Rule mapping

    private static let typeKinds: Set<DeclarationKind> = [
        .class, .struct, .enum, .protocol, .actor, .extension,
    ]

    private func rule(for item: UnusedCode, context: CorpusContext) -> RuleID? {
        if item.reason == .deadBranch {
            return .deadBranch
        }
        if item.reason == .importNotUsed || item.declaration.kind == .import {
            return .unusedImport
        }
        // Public surface routes to its own opt-in rule regardless of kind.
        if context.effectiveAccess(of: item.declaration) >= .public {
            return .unusedPublicApi
        }
        switch item.declaration.kind {
        case .function, .method:
            return .unusedFunction
        case .class, .struct, .enum, .protocol, .typealias, .actor:
            return .unusedType
        case .variable, .constant:
            return .unusedProperty
        case .enumCase:
            return .unusedEnumCase
        default:
            // initializer/deinitializer/subscript/parameter/operator/
            // extension/associatedtype: no rule — name-level reference
            // tracking cannot judge them reliably.
            return nil
        }
    }

    // MARK: - Containment collapse

    private func key(of declaration: Declaration) -> String {
        let location = declaration.location
        return "\(location.file):\(location.line):\(location.column)"
    }

    private func isInsideFlaggedType(
        _ declaration: Declaration,
        _ flaggedTypeKeys: Set<String>,
        _ context: CorpusContext
    ) -> Bool {
        guard !flaggedTypeKeys.isEmpty else { return false }
        return context.enclosingTypeDeclarations(of: declaration)
            .contains { flaggedTypeKeys.contains(key(of: $0)) }
    }

    // MARK: - Text

    private func message(for item: UnusedCode, rule: RuleID) -> String {
        let declaration = item.declaration
        switch rule {
        case .deadBranch:
            // The dead-branch pass fills the suggestion with the precise
            // condition/value sentence; surface it as the message.
            return item.suggestion
        case .unusedImport:
            return "imported module '\(declaration.name)' has no referenced symbol in this file"
        case .unusedPublicApi:
            return
                "public \(kindWord(declaration)) '\(displayName(of: declaration))' is never referenced inside the analyzed corpus"
        default:
            break
        }

        let subject = "\(kindWord(declaration)) '\(displayName(of: declaration))'"
        switch item.reason {
        case .onlyAssigned:
            return "\(subject) is assigned but never read"
        default:
            switch mode {
            case .simple:
                return "\(subject) is never referenced in this file"
            case .reachability:
                return "\(subject) is never referenced from any entry point"
            }
        }
    }

    private func note(for item: UnusedCode) -> String {
        let reasonText: String =
            switch item.reason {
            case .neverReferenced: "no reference found"
            case .onlyAssigned: "written but never read"
            case .importNotUsed: "syntax-level heuristic; extensions and operators are invisible"
            case .deadBranch: "sparse conditional constant propagation"
            }
        return "confidence \(item.confidence.rawValue) — \(reasonText)"
    }

    private func displayName(of declaration: Declaration) -> String {
        if let signature = declaration.signature {
            return declaration.name + signature.selectorString
        }
        return declaration.name
    }

    private func kindWord(_ declaration: Declaration) -> String {
        switch declaration.kind {
        case .function: "function"
        case .method: "method"
        case .variable: "property"
        case .constant: "property"
        case .enumCase: "enum case"
        case .class: "class"
        case .struct: "struct"
        case .enum: "enum"
        case .protocol: "protocol"
        case .typealias: "typealias"
        case .actor: "actor"
        default: declaration.kind.rawValue
        }
    }
}
