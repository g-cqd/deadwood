import DeadwoodCore
import Foundation
import Testing

/// `exclude` follows ADR-0008, the rule every tool shares: substrings as before, globs relative to the configuration
/// file's directory, not whole matches of the absolute path (analyzerkit roadmap 0005).
@Suite struct PathFilterAdoptionTests {
    @Test func `globs are relative to the configuration file and substrings keep their meaning`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-exclude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: ".deadwood.json")
        let entries = ["Sources/*/Internal", "/*.swift", "Generated/", "**/Fixtures/**"]
        try JSONSerialization.data(withJSONObject: ["exclude": entries]).write(to: file)
        let config = try Configuration.load(path: file.path)
        let base = root.path
        #expect(config.isExcluded(path: base + "/Sources/App/Internal/Secret.swift"))
        #expect(config.isExcluded(path: base + "/Package.swift"))
        #expect(config.isExcluded(path: base + "/Sources/Generated/API.swift"))
        #expect(config.isExcluded(path: base + "/Tests/Fixtures/Input.swift"))
        #expect(!config.isExcluded(path: base + "/Sources/App/Internal.swift"))
        #expect(!config.isExcluded(path: base + "/Sources/App/App.swift"))
    }

    @Test func `where the file lives is not part of the configuration, so it never changes the cache key`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-exclude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: ".deadwood.json")
        try JSONSerialization.data(withJSONObject: ["exclude": ["/*.swift"]]).write(to: file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let loaded = try encoder.encode(try Configuration.load(path: file.path))
        let built = try encoder.encode(Configuration(exclude: ["/*.swift"]))
        #expect(loaded == built)
    }
}
