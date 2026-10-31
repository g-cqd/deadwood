import Foundation
import Testing

/// The report contract, pinned (analyzerkit roadmap 0011, ADR-0017): SARIF, xcode and baseline output byte for byte as
/// recorded from the release before the shared formatter, JSON equal apart from the keys ADR-0017 adds, the added keys
/// present, and maintastic's decoder shape satisfied. `Goldens/` holds the recorded files; regenerate them only for a
/// deliberate contract change, and say so in the release notes.
@Suite(.serialized) struct ReportGoldenTests {
    private static let tool = "deadwood"
    /// Keys ADR-0017 adds that this tool did not write before.
    private static let addedKeys: Set<String> = ["tool", "version", "runNotes", "skippedFiles", "timings"]
    private static let inputs = ["Fixtures", "Goldens/Corpus"]

    private static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let goldens = testsDirectory.appending(path: "Goldens")

    private struct Run {
        let status: Int32
        let output: Data
        let errors: String
    }

    /// The tool built beside this package's tests, newest of the debug and release products.
    private static func executable() throws -> URL {
        let build = testsDirectory.deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build")
        let candidates = ["debug", "release"].map { build.appending(path: "\($0)/\(tool)") }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        func modified(_ url: URL) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate]
                as? Date ?? .distantPast
        }
        return try #require(candidates.max { modified($0) < modified($1) }, "build \(tool) first")
    }

    /// The corpus as the goldens were recorded from it, copied into a fresh repository root: `*.swift.bytes` (bytes no linter may touch, such as
    /// invalid UTF-8) become `*.swift`, and nothing is written into the source tree.
    private static func corpusCopy(in scratch: URL) throws -> URL {
        let corpus = scratch.appending(path: "corpus")
        // A repository root, as a corpus is in use: outside one, fingerprints keep absolute paths by design.
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        try Data("gitdir: none\n".utf8).write(to: corpus.appending(path: ".git"))
        for part in ["Fixtures", "Goldens/Corpus"] {
            let source = testsDirectory.appending(path: part)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = corpus.appending(path: part)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        }
        let entries = FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)
        let stored = (entries?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent.hasSuffix(".swift.bytes") }
        for file in stored { try FileManager.default.moveItem(at: file, to: file.deletingPathExtension()) }
        return corpus
    }

    private static func run(_ arguments: [String]) throws -> Run {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "\(tool)-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputURL = scratch.appending(path: "stdout")
        let errorURL = scratch.appending(path: "stderr")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = try executable()
        process.arguments = ["analyze"] + inputs + ["--relative-to", ".", "--no-cache"] + arguments
        let corpus = try corpusCopy(in: scratch)
        process.currentDirectoryURL = corpus
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        try output.close()
        try errors.close()
        return Run(
            status: process.terminationStatus, output: try Data(contentsOf: outputURL),
            errors: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
    }

    private static func recordedStatus(_ format: String) throws -> Int32 {
        let data = try Data(contentsOf: goldens.appending(path: "status.json"))
        let table = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        return Int32(try #require(table[format]))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `output` with the uri of `originalUriBaseIds.SRCROOT` replaced by a fixed placeholder.
    private static func placeholdingRoot(_ output: Data) -> Data {
        let text = String(decoding: output, as: UTF8.self)
        let replaced = text.replacing(
            /("SRCROOT" : \{\s*"uri" : ")[^"]*(")/, with: { "\($0.output.1)file:\\/\\/\\/SRCROOT\\/\($0.output.2)" })
        return Data(replaced.utf8)
    }

    @Test(arguments: ["sarif", "xcode"])
    func `SARIF and xcode output are byte for byte the recorded ones`(_ format: String) throws {
        let run = try Self.run(["--format", format])
        let golden = try Data(contentsOf: Self.goldens.appending(path: "report.\(format)"))
        // SARIF declares the run's absolute root as SRCROOT; the golden holds a placeholder there and only there.
        let output = format == "sarif" ? Self.placeholdingRoot(run.output) : run.output
        #expect(run.status == (try Self.recordedStatus(format)))
        let same = output == golden
        #expect(same, "report.\(format) differs from the golden; see Goldens/")
    }

    @Test func `the baseline file is byte for byte the recorded one`() throws {
        let path = FileManager.default.temporaryDirectory.appending(
            path: "\(Self.tool)-baseline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let run = try Self.run(["--write-baseline", path.path])
        #expect(run.status == (try Self.recordedStatus("write-baseline")))
        let same = try Data(contentsOf: path) == Data(contentsOf: Self.goldens.appending(path: "baseline.json"))
        #expect(same)
    }

    @Test func `JSON equals the recorded report apart from the keys ADR-0017 adds`() throws {
        let run = try Self.run(["--format", "json"])
        #expect(run.status == (try Self.recordedStatus("json")))
        var actual = try Self.object(run.output)
        for key in Self.addedKeys { actual[key] = nil }
        let expected = try Self.object(Data(contentsOf: Self.goldens.appending(path: "report.json")))
        let same = NSDictionary(dictionary: actual).isEqual(to: expected)
        #expect(same)
    }

    @Test func `the envelope names the tool and lists notes and skipped files`() throws {
        let report = try Self.object(try Self.run(["--format", "json"]).output)
        #expect(report["tool"] as? String == Self.tool)
        #expect((report["version"] as? String)?.isEmpty == false)
        #expect(report["runNotes"] is [Any])
        let skipped = try #require(report["skippedFiles"] as? [[String: String]])
        let degraded = try #require(report["degradedFiles"] as? [[String: Any]])
        #expect(
            Set(skipped.filter { $0["reason"] == "degraded" }.compactMap { $0["path"] })
                == Set(degraded.compactMap { $0["path"] as? String }))
        #expect(report["timings"] == nil)
    }

    @Test func `the xcode summary says how many files were not checked`() throws {
        let report = try Self.object(Data(contentsOf: Self.goldens.appending(path: "report.json")))
        let degraded = Set(((report["degradedFiles"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String })
        let run = try Self.run(["--format", "xcode"])
        if degraded.isEmpty {
            #expect(!run.errors.contains("not checked"))
        } else {
            #expect(run.errors.contains("(\(degraded.count) not checked)"))
        }
    }

    /// maintastic's `StaticAnalysisReport`, the one external decoder (DangerPlugins).
    private struct StaticAnalysisReport: Decodable {
        struct Finding: Decodable {
            struct Location: Decodable {
                let path: String
                let line: Int
            }
            let path: String
            let line: Int
            let message: String
            let note: String?
            let rule: String
            let severity: String
            let related: [Location]?
        }
        let schemaVersion: Int
        let findings: [Finding]
    }

    @Test func `maintastic's decoder reads the report`() throws {
        let run = try Self.run(["--format", "json"])
        let report = try JSONDecoder().decode(StaticAnalysisReport.self, from: run.output)
        #expect(report.schemaVersion == 1)
        let expected = try Self.object(Data(contentsOf: Self.goldens.appending(path: "report.json")))
        #expect(report.findings.count == (expected["findings"] as? [Any])?.count)
        #expect(report.findings.allSatisfy { ["error", "warning", "note"].contains($0.severity) })
    }
}
