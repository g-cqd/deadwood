import Foundation
import Testing

/// The shared configuration as each analyzer reads it (analyzerkit roadmap 0014, ADR-0020): one configuration
/// directory, `.swift-analyzers.json` with this tool's section, the tool's own file, and no silently ignored key.
@Suite(.serialized) struct SharedConfigurationAdoptionTests {
    private static let tool = "deadwood"
    private static let ownFile = ".deadwood.json"
    private static let extraArguments: [String] = []

    private static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func executable() throws -> URL {
        let build = packageRoot.appending(path: ".build")
        let candidates = ["debug", "release"].map { build.appending(path: "\($0)/\(tool)") }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        func modified(_ url: URL) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate]
                as? Date ?? .distantPast
        }
        return try #require(candidates.max { modified($0) < modified($1) }, "build \(tool) first")
    }

    /// A repository root with five reachable files under `Sources/` and `configuration` (file name: contents).
    private static func workspace(_ configuration: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "\(tool)-shared-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        var files = configuration
        files[".git"] = "gitdir: none\n"
        files["Sources/Main.swift"] =
            "@main struct Main {\n    static func main() { One.run(); Two.run(); Three.run(); Four.run() }\n}\n"
        for name in ["One", "Two", "Three", "Four"] {
            files["Sources/\(name)/\(name).swift"] =
                "enum \(name) {\n    static func run() {}\n    private static func unused\(name)() {}\n}\n"
        }
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private struct Run {
        let status: Int32
        let analyzedFileCount: Int?
        /// The files the run reports on: analyzed files, or for deadwood, which reads every file and leaves excluded
        /// ones out of the report only, the files with findings.
        let reported: Int?
        let errors: String
    }

    private static func run(_ configuration: [String: String], from directory: String = "", _ arguments: [String] = [])
        throws -> Run
    {
        let root = try workspace(configuration)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "stdout.json")
        let errors = root.appending(path: "stderr.txt")
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = try executable()
        process.arguments =
            ["analyze", root.appending(path: "Sources").path, "--format", "json", "--no-cache"]
            + extraArguments + arguments
        process.currentDirectoryURL = directory.isEmpty ? root : root.appending(path: directory)
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        process.waitUntilExit()
        let report = try? JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        return Run(
            status: process.terminationStatus, analyzedFileCount: report?["analyzedFileCount"] as? Int,
            reported: tool == "deadwood"
                ? (report?["findings"] as? [[String: Any]]).map { Set($0.compactMap { $0["path"] as? String }).count }
                : report?["analyzedFileCount"] as? Int,
            errors: String(decoding: try Data(contentsOf: errors), as: UTF8.self))
    }

    @Test func `exclude from the shared top level, the tool's section and the tool's file add up`() throws {
        let shared = #"{"exclude": ["Sources/One/"], "deadwood": {"exclude": ["/Sources/Two/*.swift"]}, "arcleak": {}}"#
        let run = try Self.run([".swift-analyzers.json": shared, Self.ownFile: #"{"exclude": ["Three"]}"#])
        #expect(run.status == 0)
        #expect(run.reported == 1, "Main and Four remain; got \(String(describing: run.reported))")
    }

    @Test func `run from a subdirectory, the project root's configuration is read`() throws {
        let run = try Self.run([".swift-analyzers.json": #"{"exclude": ["Sources/One/"]}"#], from: "Sources/Two")
        #expect(run.status == 0 && run.reported == 3)
    }

    @Test func `an unknown key fails with 78 and names the file and the key`() throws {
        for (file, text, key) in [
            (".swift-analyzers.json", #"{"exlude": ["x"]}"#, "exlude"),
            (".swift-analyzers.json", #"{"deadwood": {"bogus": 1}}"#, "deadwood.bogus"),
            (Self.ownFile, #"{"bogus": 1}"#, "bogus"),
        ] {
            let run = try Self.run([file: text])
            #expect(run.status == 78, "\(file) \(text)")
            #expect(run.errors.contains(file) && run.errors.contains("\"\(key)\""), "\(run.errors)")
        }
    }

    @Test func `another tool's section is not this tool's to check`() throws {
        let run = try Self.run([".swift-analyzers.json": #"{"arcleak": {"aKeyOnlyItKnows": true}}"#])
        #expect(run.status == 0 && run.reported == 4)
    }

    @Test func `--verbose names the configuration files and the overrides`() throws {
        let run = try Self.run(
            [".swift-analyzers.json": #"{"includeRegions": "test"}"#, Self.ownFile: #"{"includeRegions": "preview"}"#],
            ["--verbose"])
        #expect(run.status == 0)
        #expect(run.errors.contains("deadwood: configuration: read "), "\(run.errors)")
        #expect(run.errors.contains("deadwood: configuration: includeRegions from "), "\(run.errors)")
    }
}
