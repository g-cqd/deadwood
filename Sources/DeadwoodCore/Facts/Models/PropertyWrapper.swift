//  Lifted from SwiftStaticAnalysis (MIT) — Models/PropertyWrapper.swift.
//  Trimmed: `parse(from:)` and display helpers the engine never calls.

import Foundation

// MARK: - PropertyWrapperKind

/// Known property wrapper types whose synthesized accessors make the wrapped
/// property "used" even when the reference collector sees no read.
enum PropertyWrapperKind: String, Sendable, CaseIterable, Codable {
    // SwiftUI state management
    case state = "State"
    case binding = "Binding"
    case environment = "Environment"
    case environmentObject = "EnvironmentObject"
    case stateObject = "StateObject"
    case observedObject = "ObservedObject"

    // SwiftUI persistence
    case appStorage = "AppStorage"
    case sceneStorage = "SceneStorage"

    // SwiftUI focus
    case focusState = "FocusState"
    case focusedValue = "FocusedValue"
    case focusedBinding = "FocusedBinding"

    // SwiftUI gestures
    case gestureState = "GestureState"

    // SwiftUI animation
    case namespace = "Namespace"

    // SwiftData
    case query = "Query"
    case attribute = "Attribute"
    case relationship = "Relationship"

    // Core Data
    case fetchRequest = "FetchRequest"
    case sectionedFetchRequest = "SectionedFetchRequest"

    // Combine
    case published = "Published"

    // Concurrency
    case mainActor = "MainActor"

    case unknown = "Unknown"

    /// Initialize from an attribute name string, stripping `@` and generics.
    init(attributeName: String) {
        let name =
            attributeName.hasPrefix("@")
            ? String(attributeName.dropFirst())
            : attributeName
        let baseName = name.components(separatedBy: "<").first ?? name
        self = Self(rawValue: baseName) ?? .unknown
    }

    /// Whether properties with this wrapper are implicitly used.
    var impliesUsage: Bool {
        switch self {
        case .appStorage,
            .binding,
            .environment,
            .environmentObject,
            .focusState,
            .gestureState,
            .namespace,
            .observedObject,
            .published,
            .sceneStorage,
            .state,
            .stateObject:
            true

        default:
            false
        }
    }
}

// MARK: - PropertyWrapperInfo

/// A property wrapper applied to a declaration.
struct PropertyWrapperInfo: Sendable, Hashable, Codable {
    /// The kind of property wrapper.
    let kind: PropertyWrapperKind

    /// The full attribute text (e.g. "@State").
    let attributeText: String

    /// Arguments to the wrapper (if any).
    let arguments: String?

    init(kind: PropertyWrapperKind, attributeText: String, arguments: String? = nil) {
        self.kind = kind
        self.attributeText = attributeText
        self.arguments = arguments
    }
}

// MARK: - SwiftUIConformance

/// SwiftUI protocol conformances that affect analysis.
enum SwiftUIConformance: String, Sendable, CaseIterable, Codable {
    case view = "View"
    case viewModifier = "ViewModifier"
    case previewProvider = "PreviewProvider"
    case app = "App"
    case scene = "Scene"
    case commands = "Commands"
    case toolbarContent = "ToolbarContent"
    case customizableToolbarContent = "CustomizableToolbarContent"
    case tableRowContent = "TableRowContent"
    case tableColumnContent = "TableColumnContent"
    case dynamicProperty = "DynamicProperty"
}

// MARK: - SwiftUITypeInfo

/// SwiftUI-specific information for struct/class declarations.
struct SwiftUITypeInfo: Sendable, Hashable, Codable {
    /// SwiftUI protocol conformances.
    let conformances: Set<SwiftUIConformance>

    init(conformances: Set<SwiftUIConformance>) {
        self.conformances = conformances
    }

    /// Whether this is a View type.
    var isView: Bool {
        conformances.contains(.view) || conformances.contains(.viewModifier)
    }

    /// Whether this is an App entry point.
    var isApp: Bool {
        conformances.contains(.app)
    }

    /// Whether this is a preview provider.
    var isPreview: Bool {
        conformances.contains(.previewProvider)
    }
}
