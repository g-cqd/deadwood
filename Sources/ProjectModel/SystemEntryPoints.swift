/// A type the system instantiates by name, read from a project file rather
/// than from Swift: an extension's principal class, a scene delegate, an
/// Interface Builder custom class. No Swift source ever references it.
public struct SystemEntryPoint: Sendable, Hashable {
    public enum Origin: String, Sendable, Hashable {
        /// A class-name key in an Info.plist.
        case infoPlist
        /// An `INFOPLIST_KEY_…` build setting in an Xcode project.
        case buildSetting
        /// A `customClass` in a storyboard or xib.
        case interfaceBuilder
    }

    /// The type name, without its module prefix.
    public let typeName: String
    public let origin: Origin
    /// The plist key or build setting that names the type; `customClass` for
    /// Interface Builder files.
    public let key: String

    public init(typeName: String, origin: Origin, key: String) {
        self.typeName = typeName
        self.origin = origin
        self.key = key
    }
}

/// Reads system entry points from project files. Parsing is textual and
/// needs no Foundation: the keys it looks for are unambiguous in each
/// format, and an unknown format yields nothing.
public enum SystemEntryPoints {
    /// Info.plist keys whose value is a class the system instantiates.
    public static let classNameKeys: Set<String> = [
        "NSExtensionPrincipalClass",
        "NSPrincipalClass",
        "UISceneDelegateClassName",
        "UISceneClassName",
        "WKExtensionDelegateClassName",
        "WKApplicationDelegateClassName",
        "CLKComplicationPrincipalClass",
    ]

    /// Whether `path` is a file this scanner reads.
    public static func isProjectFile(_ path: String) -> Bool {
        path.hasSuffix(".plist") || path.hasSuffix(".storyboard") || path.hasSuffix(".xib")
            || path.hasSuffix(".pbxproj")
    }

    /// The entry points one project file names.
    /// - Complexity: O(n) in the length of `contents`.
    public static func scan(path: String, contents: String) -> [SystemEntryPoint] {
        if path.hasSuffix(".plist") {
            return infoPlistEntryPoints(contents)
        }
        if path.hasSuffix(".storyboard") || path.hasSuffix(".xib") {
            return interfaceBuilderEntryPoints(contents)
        }
        if path.hasSuffix(".pbxproj") {
            return buildSettingEntryPoints(contents)
        }
        return []
    }

    /// `<key>K</key>` followed by `<string>V</string>`, at any nesting depth.
    static func infoPlistEntryPoints(_ contents: String) -> [SystemEntryPoint] {
        var found: [SystemEntryPoint] = []
        var rest = Substring(contents)
        while let key = value(after: "<key>", upTo: "</key>", in: &rest) {
            guard classNameKeys.contains(key.trimmed) else { continue }
            var lookahead = rest.drop { $0.isWhitespace }
            guard lookahead.hasPrefix("<string>"),
                let name = value(after: "<string>", upTo: "</string>", in: &lookahead),
                let typeName = typeName(from: name)
            else { continue }
            found.append(SystemEntryPoint(typeName: typeName, origin: .infoPlist, key: key.trimmed))
        }
        return found
    }

    /// Every `customClass="Name"` attribute.
    static func interfaceBuilderEntryPoints(_ contents: String) -> [SystemEntryPoint] {
        var found: [SystemEntryPoint] = []
        var rest = Substring(contents)
        while let name = value(after: "customClass=\"", upTo: "\"", in: &rest) {
            if let typeName = typeName(from: name) {
                found.append(SystemEntryPoint(typeName: typeName, origin: .interfaceBuilder, key: "customClass"))
            }
        }
        return found
    }

    /// `INFOPLIST_KEY_<key> = value;` for the class-name keys.
    static func buildSettingEntryPoints(_ contents: String) -> [SystemEntryPoint] {
        var found: [SystemEntryPoint] = []
        var rest = Substring(contents)
        while let setting = value(after: "INFOPLIST_KEY_", upTo: ";", in: &rest) {
            let parts = setting.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmed
            guard classNameKeys.contains(key), let typeName = typeName(from: parts[1]) else { continue }
            found.append(SystemEntryPoint(typeName: typeName, origin: .buildSetting, key: key))
        }
        return found
    }

    /// `$(PRODUCT_MODULE_NAME).SampleExtensionHandler`, `Module.SampleExtensionHandler` or
    /// `"SampleExtensionHandler"` → `SampleExtensionHandler`; nil when no identifier remains.
    static func typeName(from value: Substring) -> String? {
        var text = value.trimmed
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        let name = text.split(separator: ".").last.map(String.init) ?? text
        guard let first = name.first, first.isLetter || first == "_",
            name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        return name
    }

    /// The text between the next `open` and the `close` after it, advancing
    /// `rest` past `close`; nil when either is missing.
    private static func value(after open: String, upTo close: String, in rest: inout Substring) -> Substring? {
        guard let start = rest.firstRange(of: open) else {
            rest = rest[rest.endIndex...]
            return nil
        }
        let afterOpen = rest[start.upperBound...]
        guard let end = afterOpen.firstRange(of: close) else {
            rest = rest[rest.endIndex...]
            return nil
        }
        rest = afterOpen[end.upperBound...]
        return afterOpen[..<end.lowerBound]
    }
}

extension Substring {
    fileprivate var trimmed: String {
        String(drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
    }
}
