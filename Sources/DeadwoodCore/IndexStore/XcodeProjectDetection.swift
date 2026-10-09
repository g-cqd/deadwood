//  New in deadwood: detects an Xcode project among the analyzed paths, so a
//  run without the index store can say that its name-based findings are
//  imprecise. Platform-neutral: it only lists directories.

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Detection of Xcode projects and the warning a run without the index store
/// gets for them.
package enum XcodeProjectDetection {
    /// The note for an Xcode run that did not request the index store. Notes
    /// are printed to stderr and carried in the JSON `notes`; they never fail a run.
    package static let withoutIndexStoreNote =
        "\(ToolInfo.name): warning: analyzing an Xcode project without the index store; "
        + "findings use name-based reachability. Pass --index-store-path "
        + "<DerivedData>/<Project>-<hash>/Index.noindex/DataStore for precise cross-module results."

    /// Whether any path is an `.xcodeproj` or `.xcworkspace`, or is a directory
    /// whose top level holds one. Lists each directory once; never recurses.
    /// - Complexity: O(e) per path, where e is the entry count of its top level.
    package static func containsXcodeProject(in paths: [String]) -> Bool {
        paths.contains { path in
            if isXcodeContainer(path) { return true }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                return false
            }
            return entries.contains(where: isXcodeContainer)
        }
    }

    private static func isXcodeContainer(_ name: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        return fileExtension == "xcodeproj" || fileExtension == "xcworkspace"
    }
}
