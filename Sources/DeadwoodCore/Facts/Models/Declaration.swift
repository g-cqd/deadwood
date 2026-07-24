//  Lifted from SwiftStaticAnalysis (MIT) — Models/Declaration.swift.
//  Trimmed: `swa:ignore` directive plumbing (deadwood suppression is the
//  `@dw:` table in the Analyzer), Codable conformance, and display helpers
//  nothing in this tool reads.

import ADJSON

// MARK: - DeclarationKind

/// The kind of declaration.
enum DeclarationKind: String, Sendable, CaseIterable, Codable {
    case function
    case method
    case initializer
    case deinitializer
    case variable
    case constant
    case parameter
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case `typealias`
    case `associatedtype`
    case `import`
    case `subscript`
    case `operator`
    case enumCase
    case actor
}

// MARK: - AccessLevel

/// Swift access level modifiers, ordered from most to least restrictive.
enum AccessLevel: String, Sendable, Comparable, CaseIterable, Codable {
    case `private`
    case `fileprivate`
    case `internal`
    case package
    case `public`
    case open

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .private: 0
        case .fileprivate: 1
        case .internal: 2
        case .package: 3
        case .public: 4
        case .open: 5
        }
    }
}

// MARK: - DeclarationModifiers

/// Modifiers that can be applied to declarations.
struct DeclarationModifiers: OptionSet, Sendable, Hashable, Codable {
    static let `static` = Self(rawValue: 1 << 0)
    static let `class` = Self(rawValue: 1 << 1)
    static let final = Self(rawValue: 1 << 2)
    static let override = Self(rawValue: 1 << 3)
    static let mutating = Self(rawValue: 1 << 4)
    static let nonmutating = Self(rawValue: 1 << 5)
    static let lazy = Self(rawValue: 1 << 6)
    static let weak = Self(rawValue: 1 << 7)
    static let unowned = Self(rawValue: 1 << 8)
    static let optional = Self(rawValue: 1 << 9)
    static let required = Self(rawValue: 1 << 10)
    static let convenience = Self(rawValue: 1 << 11)
    static let nonisolated = Self(rawValue: 1 << 12)
    static let consuming = Self(rawValue: 1 << 13)
    static let borrowing = Self(rawValue: 1 << 14)

    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

// MARK: - FunctionSignature

/// A function or method signature.
@JSONCodable
struct FunctionSignature: Sendable, Hashable, Codable {
    /// A single parameter in a function signature.
    @JSONCodable
    struct Parameter: Sendable, Hashable, Codable {
        /// External parameter label (nil for unlabeled).
        let label: String?

        /// Internal parameter name.
        let name: String

        /// Parameter type as source text.
        let type: String

        /// Whether the parameter has a default value.
        let hasDefaultValue: Bool

        /// Whether the parameter is variadic.
        let isVariadic: Bool

        /// Whether the parameter is `inout`.
        let isInout: Bool

        init(
            label: String?,
            name: String,
            type: String,
            hasDefaultValue: Bool = false,
            isVariadic: Bool = false,
            isInout: Bool = false
        ) {
            self.label = label
            self.name = name
            self.type = type
            self.hasDefaultValue = hasDefaultValue
            self.isVariadic = isVariadic
            self.isInout = isInout
        }

        /// Short label for selector-style display (e.g. "id:" or "_:").
        var selectorLabel: String {
            if let label {
                return "\(label):"
            }
            return "_:"
        }
    }

    /// Parameters of the function.
    let parameters: [Parameter]

    /// Return type (nil for Void).
    let returnType: String?

    /// Whether the function is `async`.
    let isAsync: Bool

    /// Whether the function `throws`.
    let isThrowing: Bool

    /// Whether the function `rethrows`.
    let isRethrowing: Bool

    init(
        parameters: [Parameter] = [],
        returnType: String? = nil,
        isAsync: Bool = false,
        isThrowing: Bool = false,
        isRethrowing: Bool = false
    ) {
        self.parameters = parameters
        self.returnType = returnType
        self.isAsync = isAsync
        self.isThrowing = isThrowing
        self.isRethrowing = isRethrowing
    }

    /// Selector-style representation (e.g. "(id:)" for `fetch(id:)`).
    var selectorString: String {
        if parameters.isEmpty {
            return "()"
        }
        return "(" + parameters.map(\.selectorLabel).joined() + ")"
    }
}

// MARK: - Declaration

/// A declaration in Swift source code, as collected by `DeclarationCollector`.
@JSONCodable
struct Declaration: Sendable, Hashable, Codable {
    /// The declared name.
    let name: String

    /// Kind of declaration.
    let kind: DeclarationKind

    /// Declared access level (see `AccessResolver` for the effective level).
    let accessLevel: AccessLevel

    /// Applied modifiers.
    let modifiers: DeclarationModifiers

    /// Location in source (after leading trivia, i.e. the declaration itself).
    let location: SourceLocation

    /// Range of the entire declaration.
    let range: SourceRange

    /// Scope containing this declaration.
    let scope: ScopeID

    /// Type annotation (if present).
    let typeAnnotation: String?

    /// Generic parameters (if any).
    let genericParameters: [String]

    /// Function/method signature (for functions, methods, initializers).
    let signature: FunctionSignature?

    /// Documentation comment (if any).
    let documentation: String?

    /// Property wrappers applied to this declaration (for variables/constants).
    let propertyWrappers: [PropertyWrapperInfo]

    /// SwiftUI type information (for struct/class declarations).
    let swiftUIInfo: SwiftUITypeInfo?

    /// Protocol conformances declared on this type. For enum cases this
    /// carries the *parent enum's* inheritance list so externally-constructed
    /// cases (raw values, Codable, CaseIterable) can be recognized as roots.
    let conformances: [String]

    /// Attributes applied to this declaration (e.g. main, objc, IBAction).
    let attributes: [String]

    init(
        name: String,
        kind: DeclarationKind,
        accessLevel: AccessLevel = .internal,
        modifiers: DeclarationModifiers = [],
        location: SourceLocation,
        range: SourceRange,
        scope: ScopeID,
        typeAnnotation: String? = nil,
        genericParameters: [String] = [],
        signature: FunctionSignature? = nil,
        documentation: String? = nil,
        propertyWrappers: [PropertyWrapperInfo] = [],
        swiftUIInfo: SwiftUITypeInfo? = nil,
        conformances: [String] = [],
        attributes: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.accessLevel = accessLevel
        self.modifiers = modifiers
        self.location = location
        self.range = range
        self.scope = scope
        self.typeAnnotation = typeAnnotation
        self.genericParameters = genericParameters
        self.signature = signature
        self.documentation = documentation
        self.propertyWrappers = propertyWrappers
        self.swiftUIInfo = swiftUIInfo
        self.conformances = conformances
        self.attributes = attributes
    }
}

// MARK: - Declaration SwiftUI helpers

extension Declaration {
    /// Whether this declaration's property wrappers imply usage
    /// (synthesized accessors the reference collector cannot see).
    var hasImplicitUsageWrapper: Bool {
        propertyWrappers.contains { $0.kind.impliesUsage }
    }

    /// Whether this is a SwiftUI View type.
    var isSwiftUIView: Bool {
        swiftUIInfo?.isView ?? false
    }

    /// Whether this is a SwiftUI App entry point.
    var isSwiftUIApp: Bool {
        swiftUIInfo?.isApp ?? false
    }

    /// Whether this is a SwiftUI preview provider.
    var isSwiftUIPreview: Bool {
        swiftUIInfo?.isPreview ?? false
    }
}

// MARK: - DeclarationIndex

/// Index of declarations for fast lookup.
struct DeclarationIndex: Sendable {
    /// All declarations.
    private(set) var declarations: [Declaration] = []

    /// Declarations indexed by kind.
    private(set) var byKind: [DeclarationKind: [Declaration]] = [:]

    init() {}

    /// Add a declaration to the index.
    mutating func add(_ declaration: Declaration) {
        declarations.append(declaration)
        byKind[declaration.kind, default: []].append(declaration)
    }

    /// Find declarations of a specific kind.
    func find(kind: DeclarationKind) -> [Declaration] {
        byKind[kind] ?? []
    }
}
