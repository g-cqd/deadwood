/// Every diagnostic the tool can emit. Raw values are the public rule ids
/// used in configuration, suppression directives, and SARIF.
public enum RuleID: String, CaseIterable, Sendable, Codable {
    case unusedFunction = "unused-function"
    case unusedType = "unused-type"
    case unusedProperty = "unused-property"
    case unusedEnumCase = "unused-enum-case"
    case unusedImport = "unused-import"
    case unusedPublicApi = "unused-public-api"
    case deadBranch = "dead-branch"
    case referencedOnlyByTests = "referenced-only-by-tests"
    case assignOnlyProperty = "assign-only-property"
    case deadStore = "dead-store"
    case previewOnly = "preview-only"
    case debugOnly = "debug-only"
    case unusedTransitively = "unused-transitively"

    public var summary: String {
        switch self {
        case .unusedFunction:
            "function or method with no reference reachable from any entry point"
        case .unusedType:
            "type declaration with no reference reachable from any entry point"
        case .unusedProperty:
            "stored or computed property with no reachable reference"
        case .unusedEnumCase:
            "enum case never constructed or matched"
        case .unusedImport:
            "imported module whose symbols are never referenced (syntax-level heuristic)"
        case .unusedPublicApi:
            "public/open declaration unreferenced inside the analyzed corpus"
        case .deadBranch:
            "branch proven unreachable by sparse conditional constant propagation"
        case .referencedOnlyByTests:
            "declaration only tests can reach (production mode only)"
        case .assignOnlyProperty:
            "stored property that is written but never read"
        case .deadStore:
            "assignment overwritten before any read (liveness + reaching definitions)"
        case .previewOnly:
            "production code that only SwiftUI previews use"
        case .debugOnly:
            "production code that only #if DEBUG code uses"
        case .unusedTransitively:
            "declaration only dead code uses: dead with it"
        }
    }

    public var explanation: String {
        switch self {
        case .unusedFunction, .unusedType, .unusedProperty:
            """
            No reference to this declaration is reachable from any detected entry \
            point (@main, public API, @objc, IBOutlets/IBActions, tests, SwiftUI \
            roots, Codable synthesis). Unreachable code costs compile time, review \
            attention, and misleads readers about what the system does. Delete it; \
            if it is kept deliberately (upcoming feature, template), accept it with \
            a directive so the decision is auditable.
            """
        case .unusedEnumCase:
            """
            The case is never constructed and never matched outside exhaustive \
            switches. Removing it simplifies every switch over the enum. Beware \
            externally-decoded enums (Codable raw values): accept those with a \
            directive naming the wire contract.
            """
        case .unusedImport:
            """
            No symbol of the imported module is referenced in this file at the \
            syntax level. This heuristic cannot see extensions and operator \
            visibility, so it is opt-in; treat it as a review prompt, not a fact.
            """
        case .unusedPublicApi:
            """
            The declaration is public/open but nothing inside the analyzed corpus \
            references it. For libraries this is normal surface; for applications \
            it usually marks dead API. Opt-in because only you know which one this \
            codebase is.
            """
        case .deadBranch:
            """
            Constant propagation proves this branch can never execute (its \
            condition folds to a constant along every path). Dead branches hide \
            bugs — the code reads as if it runs. Delete the branch or fix the \
            condition it was meant to test.
            """
        case .referencedOnlyByTests:
            """
            With test entry points the declaration is reachable; without them \
            nothing in production code uses it. It is not dead — the tests would \
            break — but it only exists to be tested. Either the feature it \
            belongs to was removed (delete both) or the tests cover speculative \
            surface. Only emitted under --production.
            """
        case .assignOnlyProperty:
            """
            Every reference to this stored property is a write: state is \
            maintained that nothing ever consumes. Delete the property and its \
            assignments, or wire up the read that was intended. Opt-in because \
            member-access writes (`object.property = x`) are indistinguishable \
            from reads at the syntax level, so only self-shaped code is judged.
            """
        case .deadStore:
            """
            Liveness analysis shows the assigned value is never read, and \
            reaching definitions show a later store overwrites it on every \
            path. The computation and the store are wasted work and usually \
            mark a logic slip (wrong variable, leftover debugging). Opt-in \
            because inout/aliasing effects are approximated conservatively.
            """
        case .previewOnly:
            """
            Only #Preview bodies and PreviewProvider types reach this \
            declaration. It is used, so it is not dead, but it ships in release \
            builds for nothing. Move it under #if DEBUG next to the previews. \
            Code that already sits in #if DEBUG or in a preview is never \
            reported.
            """
        case .unusedTransitively:
            """
            Something uses this declaration, but everything that uses it is \
            dead: unreachable from any entry point. Deleting the dead users \
            leaves it unused, so it is reported in the same run, with the \
            users named, rather than one run per link of the chain. Its \
            confidence is the weakest along the chain. Delete it with them.
            """
        case .debugOnly:
            """
            Only code inside #if DEBUG reaches this declaration. It is used, so \
            it is not dead, but it ships in release builds for nothing. Move it \
            under #if DEBUG with its callers. Code that already sits in #if \
            DEBUG is never reported.
            """
        }
    }

    public var defaultSeverity: Severity {
        switch self {
        case .previewOnly, .debugOnly: .note
        default: .warning
        }
    }

    public var enabledByDefault: Bool {
        switch self {
        case .unusedImport, .unusedPublicApi, .assignOnlyProperty, .deadStore: false
        default: true
        }
    }
}
