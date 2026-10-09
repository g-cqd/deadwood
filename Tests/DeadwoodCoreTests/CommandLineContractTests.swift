import Foundation
import Testing

@testable import DeadwoodCore

/// What a host sees when it runs the `deadwood` executable: the SARIF on
/// standard output. GitHub code scanning and diagnostics hosts consume exactly
/// this, so it is checked on the built executable, not inferred from the
/// library.
@Suite struct CommandLineContractTests {
    /// A declaration nothing reaches, so every file yields one finding.
    private static func unusedHelper(_ name: String) -> String {
        "private func \(name)() {}\n"
    }

    // MARK: - Exit status

    @Test("A run that skipped every file prints its report, then exits 70")
    func everyFileSkippedPrintsItsReport() throws {
        let root = try Workspace.make([:])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x6C, 0x65, 0x74, 0x20, 0xFF]).write(to: root.appending(path: "Bad.swift"))
        let run = try BuiltTool.analyze(root.path, relativeTo: root.path, in: root)

        #expect(run.status == 70)
        let log = try JSONDecoder().decode(SarifLog.self, from: run.standardOutput)
        #expect(log.results.map(\.ruleId) == ["deadwood/degraded-file"])
        #expect(log.artifactLocations.map(\.uri) == ["Bad.swift"])
        let invocation = try #require(log.runs.first?.invocations?.first)
        #expect(!invocation.executionSuccessful)
        #expect(invocation.toolExecutionNotifications?.map(\.level) == ["error"])
    }

    @Test("A run that analyzed its files records a successful invocation")
    func analyzedRunSucceeds() throws {
        let root = try Workspace.make(["Sources/A.swift": Self.unusedHelper("unusedA")])
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try BuiltTool.analyze(root.path, relativeTo: root.path, in: root)

        #expect(run.status == 0)
        let log = try JSONDecoder().decode(SarifLog.self, from: run.standardOutput)
        let invocation = try #require(log.runs.first?.invocations?.first)
        #expect(invocation.executionSuccessful)
        #expect(invocation.toolExecutionNotifications == nil)
    }

    @Test("An empty --only-from file reports nothing, moves the findings out of scope, and exits 0")
    func emptyOnlyFromReportsNothing() throws {
        let root = try Workspace.make(["Sources/A.swift": Self.unusedHelper("unusedA")])
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = root.appending(path: "changed.txt")
        try Data().write(to: scope)
        let run = try BuiltTool.run(
            ["analyze", root.path, "--format", "json", "--no-cache", "--only-from", scope.path], in: root)

        #expect(run.status == 0)
        let report = try JSONDecoder().decode(AnalysisReport.self, from: run.standardOutput)
        #expect(report.findings.isEmpty)
        #expect(report.outOfScope.count == 1)
        #expect(report.analyzedFileCount == 1)
    }

    @Test("`A cache without this build's header is a miss`")
    func cacheWithoutHeaderDoesNotCrash() throws {
        let root = try Workspace.make(["Sources/A.swift": Self.unusedHelper("unusedA")])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "facts.json")
        try Data("\"x\"".utf8).write(to: cache)

        let run = try BuiltTool.run(
            ["analyze", root.path, "--format", "sarif", "--relative-to", root.path, "--cache-path", cache.path],
            in: root)

        #expect(run.status == 0)
        _ = try JSONDecoder().decode(SarifLog.self, from: run.standardOutput)
    }

    @Test("`A cache with a valid header and corrupt body is reported once`")
    func corruptCurrentCacheIsRewritten() throws {
        let root = try Workspace.make(["Sources/A.swift": Self.unusedHelper("unusedA")])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "facts.json")
        let arguments = [
            "analyze", root.path, "--format", "sarif", "--relative-to", root.path, "--cache-path", cache.path,
        ]
        let cold = try BuiltTool.run(arguments, in: root)
        #expect(cold.status == 0)
        let written = try Data(contentsOf: cache)
        let headerEnd = try #require(written.firstIndex(of: UInt8(ascii: "\n")))
        var corrupt = Data(written[...headerEnd])
        corrupt.append(Data("\"x\"".utf8))
        try corrupt.write(to: cache)

        let recovered = try BuiltTool.run(arguments, in: root)
        let warm = try BuiltTool.run(arguments, in: root)
        #expect(recovered.status == 0)
        #expect(recovered.standardOutput == cold.standardOutput)
        #expect(recovered.standardError.components(separatedBy: "ignored the facts cache").count == 2)
        #expect(!warm.standardError.contains("ignored the facts cache"))
    }

    @Test("`A copied executable does not reuse another build's cache`")
    func cacheIsScopedToExecutableIdentity() throws {
        let root = try Workspace.make(["Sources/A.swift": Self.unusedHelper("unusedA")])
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(BuiltTool.executable)
        let copy = root.appending(path: "other-deadwood")
        try FileManager.default.copyItem(at: original, to: copy)
        let cache = root.appending(path: "facts.json")
        let arguments = ["analyze", root.path, "--format", "json", "--cache-path", cache.path]

        let first = try BuiltTool.run(arguments, in: root)
        let second = try BuiltTool.run(arguments, in: root, executable: copy)
        let third = try BuiltTool.run(arguments, in: root, executable: copy)
        #expect(first.status == 0)
        #expect(second.status == 0)
        #expect(third.status == 0)
        let firstReport = try JSONDecoder().decode(AnalysisReport.self, from: first.standardOutput)
        let secondReport = try JSONDecoder().decode(AnalysisReport.self, from: second.standardOutput)
        let thirdReport = try JSONDecoder().decode(AnalysisReport.self, from: third.standardOutput)
        #expect(firstReport.cacheMisses == 1)
        #expect(secondReport.cacheHits == 0)
        #expect(thirdReport.cacheHits == 1)
    }

    /// A function over the dead-branch statement bound skips that pass for the
    /// function, not the file. Counting each such note as a skipped file made a
    /// corpus with as many oversized functions as files exit 70, as if nothing
    /// had been analyzed.
    @Test("Oversized functions do not count as skipped files")
    func oversizedFunctionsAreNotSkippedFiles() throws {
        let filler = (0...DeadBranchLimit.statements).map { "    value += \($0)" }.joined(separator: "\n")
        let oversized = ["first", "second"].map { name in
            "func \(name)() -> Int {\n    var value = 0\n\(filler)\n    return value\n}\n"
        }
        let root = try Workspace.make([
            "Sources/Generated.swift": oversized.joined(separator: "\n"),
            "Sources/Plain.swift": Self.unusedHelper("unusedPlain"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try BuiltTool.analyze(root.path, relativeTo: root.path, in: root)

        #expect(run.status == 0)
        let log = try JSONDecoder().decode(SarifLog.self, from: run.standardOutput)
        let notes = log.results.filter { $0.ruleId == "deadwood/degraded-file" }
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0.message.text.hasPrefix("analysis degraded: ") })
    }

    // MARK: - SARIF regions

    @Test("SARIF columns count UTF-16 code units, and the run says so")
    func columnsCountUTF16CodeUnits() throws {
        // Text before the finding that UTF-8 and UTF-16 count differently.
        let line = #"let marker = "😀é"; private func unusedHelper() {}"#
        let root = try Workspace.make(["Sources/A.swift": line + "\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try BuiltTool.sarif(analyzing: root.path, relativeTo: root.path, in: root)

        #expect(log.runs.first?.columnKind == "utf16CodeUnits")
        let result = try #require(log.results.first { $0.ruleId == "unused-function" })
        #expect(
            result.locations.map(\.physicalLocation.region.startColumn)
                == [try Workspace.utf16Column(of: "private func", in: line)])
    }

    // MARK: - SARIF artifact locations

    @Test("Locations under --relative-to are relative to a base the log declares")
    func relativeLocationsDeclareTheirBase() throws {
        let root = try Workspace.make([
            "Sources/A.swift": Self.unusedHelper("unusedA"), "Sources/B.swift": Self.unusedHelper("unusedB"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try BuiltTool.sarif(analyzing: root.path, relativeTo: root.path, in: root)

        let locations = log.artifactLocations
        #expect(Set(locations.map(\.uri)) == ["Sources/A.swift", "Sources/B.swift"])
        for location in locations {
            #expect(location.uriBaseId == "SRCROOT", "\(location.uri) names no base")
        }
        let base = try #require(log.originalUriBaseIds["SRCROOT"])
        #expect(base.hasPrefix("file:///"))
        #expect(base.hasSuffix("/"), "a base uri must end with a slash (SARIF 2.1.0 §3.14.14)")
        #expect(URL(string: String(base.dropLast()))?.path == Workspace.canonical(root))
    }

    @Test("A path a relative reference cannot carry unescaped is an absolute file URI")
    func unsafePathsBecomeFileURIs() throws {
        let special = "Sources/Sub Dir/Résumé+Box#1.swift"
        let root = try Workspace.make([
            special: Self.unusedHelper("unusedBox"), "Sources/Plain.swift": Self.unusedHelper("unusedPlain"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = try BuiltTool.sarif(analyzing: root.path, relativeTo: root.path, in: root)
            .artifactLocations

        let plain = try #require(locations.first { $0.uri == "Sources/Plain.swift" })
        #expect(plain.uriBaseId == "SRCROOT")
        let escaped = try #require(locations.first { $0.uri != "Sources/Plain.swift" })
        #expect(escaped.uri.hasPrefix("file:///"))
        #expect(escaped.uriBaseId == nil, "an absolute URI must not name a base (SARIF 2.1.0 §3.4.4)")
        #expect(Workspace.isURIReference(escaped.uri), "not a valid URI reference: \(escaped.uri)")
        #expect(URL(string: escaped.uri)?.path == Workspace.canonical(root) + "/" + special)
    }

    @Test("Without --relative-to every location is an absolute file URI")
    func absoluteLocationsAreFileURIs() throws {
        let root = try Workspace.make([
            "My Sources/A.swift": Self.unusedHelper("unusedA"), "My Sources/B.swift": Self.unusedHelper("unusedB"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try BuiltTool.sarif(analyzing: root.path, relativeTo: nil, in: root)

        #expect(log.originalUriBaseIds.isEmpty)
        let expected = Set(["A.swift", "B.swift"].map { Workspace.canonical(root) + "/My Sources/" + $0 })
        #expect(Set(log.artifactLocations.compactMap { URL(string: $0.uri)?.path }) == expected)
        for location in log.artifactLocations {
            #expect(location.uri.hasPrefix("file:///"))
            #expect(location.uriBaseId == nil)
            #expect(Workspace.isURIReference(location.uri), "not a valid URI reference: \(location.uri)")
        }
    }

    /// One directory has several spellings: through a symlink, and on macOS
    /// with or without `/private` (`realpath(3)` keeps it, Foundation strips
    /// it). The analyzed path and `--relative-to` may each use any of them.
    @Test("Every spelling of the root gives the same locations")
    func rootSpellingsAgree() throws {
        let root = try Workspace.make([
            "Sources/A.swift": Self.unusedHelper("unusedA"), "Sources/B.swift": Self.unusedHelper("unusedB"),
        ])
        let link = root.deletingLastPathComponent().appending(path: root.lastPathComponent + "-link")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        var spellings = [root.path, link.path]
        let physical = "/private" + Workspace.canonical(root)
        if FileManager.default.fileExists(atPath: physical) { spellings.append(physical) }

        func locations(analyzing analyzed: String, relativeTo base: String) throws -> Set<String> {
            let log = try BuiltTool.sarif(analyzing: analyzed, relativeTo: base, in: root)
            return Set(log.artifactLocations.map { "\($0.uriBaseId ?? "-") \($0.uri)" })
        }
        let expected = try locations(analyzing: root.path, relativeTo: root.path)
        #expect(expected == ["SRCROOT Sources/A.swift", "SRCROOT Sources/B.swift"])
        for analyzed in spellings {
            for base in spellings {
                #expect(try locations(analyzing: analyzed, relativeTo: base) == expected, "\(analyzed) vs \(base)")
            }
        }
    }

    @Test("A degraded file is named relative to the root, in its location and its message")
    func degradedFilesAreRelative() throws {
        let root = try Workspace.make(["Sources/A.swift": Self.unusedHelper("unusedA")])
        defer { try? FileManager.default.removeItem(at: root) }
        // A dangling link is listed like any `.swift` entry, then fails the read.
        try FileManager.default.createSymbolicLink(
            atPath: root.path + "/Sources/Broken.swift", withDestinationPath: "Missing.swift")
        let log = try BuiltTool.sarif(analyzing: root.path, relativeTo: root.path, in: root)

        let degraded = log.results.filter { $0.ruleId == "deadwood/degraded-file" }
        #expect(degraded.count == 1)
        for result in degraded {
            #expect(result.locations.map(\.physicalLocation.artifactLocation.uri) == ["Sources/Broken.swift"])
            #expect(result.locations.map(\.physicalLocation.artifactLocation.uriBaseId) == ["SRCROOT"])
            #expect(!result.message.text.contains(Workspace.canonical(root)), "\(result.message.text)")
            #expect(!result.message.text.contains(root.path), "\(result.message.text)")
        }
    }
}

// MARK: - Harness

/// The dead-branch pass's statement bound, restated: the executable is tested
/// from outside, so the test does not reach into the library for it.
enum DeadBranchLimit {
    static let statements = 5000
}

/// Runs the `deadwood` executable that `swift build` and `swift test` place
/// next to this test bundle.
enum BuiltTool {
    /// What one run of the executable produced.
    struct Run {
        let status: Int32
        let standardOutput: Data
        let standardError: String
    }

    /// SwiftPM puts every product of a build in one directory. The test
    /// resources sit in that directory on Linux and inside the `.xctest`
    /// bundle on macOS, so the executable is found among their ancestors.
    static let executable: URL? = {
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = directory.appending(path: "deadwood")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// The SARIF log `deadwood analyze` prints for `analyzed`, relativized to
    /// `base` when one is given, run from `directory` with the facts cache off.
    static func sarif(analyzing analyzed: String, relativeTo base: String?, in directory: URL) throws -> SarifLog {
        try JSONDecoder().decode(
            SarifLog.self, from: analyze(analyzed, relativeTo: base, in: directory).standardOutput)
    }

    /// `deadwood analyze` with SARIF output and the facts cache off.
    static func analyze(_ analyzed: String, relativeTo base: String?, in directory: URL) throws -> Run {
        var arguments = ["analyze", analyzed, "--format", "sarif", "--no-cache"]
        if let base { arguments += ["--relative-to", base] }
        return try run(arguments, in: directory)
    }

    /// The executable's exit status and standard output. Output goes to a file
    /// rather than a pipe, so a large report cannot fill a pipe buffer and
    /// stall the child while the test waits for it to exit.
    static func run(_ arguments: [String], in directory: URL, executable override: URL? = nil) throws -> Run {
        let executable = try #require(
            override ?? Self.executable,
            "no deadwood executable near \(Bundle.module.bundleURL.path); build the package first")
        let scratch = FileManager.default.temporaryDirectory.appending(path: "deadwood-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputURL = scratch.appending(path: "stdout")
        let errorURL = scratch.appending(path: "stderr")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        try output.close()
        try error.close()
        return Run(
            status: process.terminationStatus,
            standardOutput: try Data(contentsOf: outputURL),
            standardError: try String(contentsOf: errorURL, encoding: .utf8))
    }
}

/// A scratch directory of source files.
enum Workspace {
    /// Writes each `relative path: contents` pair under a fresh directory.
    static func make(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-cli-\(UUID().uuidString)")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: root) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            // fileURLWithPath, not appending(path:): the names under test carry
            // `#` and spaces, which must stay part of the file name.
            let url = URL(fileURLWithPath: root.path + "/" + path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        completed = true
        return root
    }

    /// The spelling deadwood reports a path under: absolute, symlinks
    /// resolved, and on macOS without `/private`.
    static func canonical(_ url: URL) -> String {
        URL(fileURLWithPath: url.path).standardized.resolvingSymlinksInPath().path
    }

    /// The 1-based UTF-16 column at which `needle` first starts in `line`.
    static func utf16Column(of needle: String, in line: String) throws -> Int {
        let range = try #require(line.range(of: needle))
        return line.utf16.distance(from: line.startIndex, to: range.lowerBound) + 1
    }

    /// Whether `uri` is made only of what RFC 3986 allows in a URI reference
    /// with no query or fragment: unreserved and reserved characters (less `?`,
    /// `#`, `[` and `]`) and well-formed percent escapes.
    static func isURIReference(_ uri: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/".utf8)
        let hex = Set("0123456789ABCDEFabcdef".utf8)
        let bytes = Array(uri.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, hex.contains(bytes[index + 1]), hex.contains(bytes[index + 2])
                else { return false }
                index += 3
            } else {
                guard allowed.contains(bytes[index]) else { return false }
                index += 1
            }
        }
        return true
    }
}

/// The parts of a SARIF 2.1.0 log these tests read, decoded independently of
/// the formatter that wrote it.
struct SarifLog: Decodable {
    struct Run: Decodable {
        let columnKind: String?
        let invocations: [Invocation]?
        let originalUriBaseIds: [String: ArtifactLocation]?
        let results: [Result]
    }

    struct Invocation: Decodable {
        let executionSuccessful: Bool
        let toolExecutionNotifications: [Notification]?
    }

    struct Notification: Decodable {
        let level: String
        let message: Message
    }

    struct Result: Decodable {
        let ruleId: String
        let message: Message
        let locations: [Location]
    }

    struct Message: Decodable {
        let text: String
    }

    struct Location: Decodable {
        let physicalLocation: PhysicalLocation
    }

    struct PhysicalLocation: Decodable {
        let artifactLocation: ArtifactLocation
        let region: Region
    }

    struct Region: Decodable {
        let startLine: Int
        let startColumn: Int
    }

    struct ArtifactLocation: Decodable {
        let uri: String
        let uriBaseId: String?
    }

    let runs: [Run]

    var results: [Result] { runs.first?.results ?? [] }

    /// Every location a result points at.
    var artifactLocations: [ArtifactLocation] {
        results.flatMap { $0.locations.map(\.physicalLocation.artifactLocation) }
    }

    /// Each declared base id and the `uri` it stands for.
    var originalUriBaseIds: [String: String] {
        (runs.first?.originalUriBaseIds ?? [:]).mapValues(\.uri)
    }
}
