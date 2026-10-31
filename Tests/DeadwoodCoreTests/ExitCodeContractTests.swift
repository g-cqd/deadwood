import Foundation
import Testing

/// The exit status of `analyze` in each scenario ADR-0018 fixes for every analyzer (analyzerkit roadmap 0013). The
/// same table runs in each tool; a row this tool cannot express (no configuration file, no severities) is left out.
@Suite(.serialized) struct ExitCodeContractTests {
    private static let tool = "deadwood"
    private static let subcommand = "analyze"
    /// One file with exactly one finding of `rule`.
    private static let finding = "private func unusedHelper() {}\n"
    private static let rule: String? = "unused-function"
    /// A configuration giving `rule` a severity, or nil when the tool has no configuration file.
    private static func configuration(severity: String) -> String? {
        #"{"rules": {"unused-function": {"severity": "\#(severity)"}}}"#
    }
    private static let cacheFlags: [String] = ["--no-cache"]
    private static let hasBaseline = true

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

    /// A fresh repository root with `clean/` (reachable code no tool reports), `finding/`, `invalid/` (not UTF-8), `locked/` (mode 000) and `empty/`.
    private static func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "\(tool)-exit-\(UUID().uuidString)")
        let manager = FileManager.default
        for (directory, bytes) in [
            ("clean", Data("@main struct Clean {\n    static func main() {}\n}\n".utf8)),
            ("finding", Data(finding.utf8)),
            ("invalid", Data([0x6C, 0x65, 0x74, 0x20, 0xFF, 0x0A])), ("locked", Data("struct Locked {}\n".utf8)),
        ] {
            try manager.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true)
            try bytes.write(to: root.appending(path: "\(directory)/A.swift"))
        }
        try manager.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appending(path: "locked/A.swift").path)
        try Data("gitdir: none\n".utf8).write(to: root.appending(path: ".git"))
        try Data("{ not json".utf8).write(to: root.appending(path: "malformed.json"))
        if rule != nil {
            for severity in ["note", "warning", "error"] {
                if let text = configuration(severity: severity) {
                    try Data(text.utf8).write(to: root.appending(path: "\(severity).json"))
                }
            }
        }
        return root
    }

    private static func status(_ arguments: [String], in root: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = [subcommand] + arguments + cacheFlags
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func expect(_ table: [(arguments: [String], status: Int32)]) throws {
        let root = try workspace()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: root.appending(path: "locked/A.swift").path)
            try? FileManager.default.removeItem(at: root)
        }
        for row in table {
            let status = try status(row.arguments, in: root)
            #expect(status == row.status, "\(tool) \(row.arguments.joined(separator: " ")) exits \(status)")
        }
    }

    @Test func `findings fail a run by severity: an error, a warning only under strict, a note never`() throws {
        var table: [(arguments: [String], status: Int32)] = [(["clean"], 0), (["clean", "--strict"], 0)]
        if Self.configuration(severity: "error") != nil {
            table += [
                (["finding", "--config", "note.json"], 0), (["finding", "--config", "note.json", "--strict"], 0),
                (["finding", "--config", "warning.json"], 0), (["finding", "--config", "warning.json", "--strict"], 1),
                (["finding", "--config", "error.json"], 1), (["finding", "--config", "error.json", "--strict"], 1),
            ]
        } else {
            // Its findings are warnings.
            table += [(["finding"], 0), (["finding", "--strict"], 1)]
        }
        try Self.expect(table)
    }

    @Test func `usage errors are 64: an unknown option, a missing path, no Swift file`() throws {
        try Self.expect([(["clean", "--no-such-option"], 64), (["absent"], 64), (["empty"], 64)])
    }

    /// Not as root (the Linux CI container): root reads a file whatever its mode, so `locked` is not unreadable.

    @Test(.enabled(if: ProcessInfo.processInfo.userName != "root"))

    func `a run that could read no file it found is an internal failure, 70`() throws {
        try Self.expect([(["locked"], 70), (["locked", "clean"], 0)])
    }

    @Test func `an unreadable or invalid configuration or baseline is 78`() throws {
        var table: [(arguments: [String], status: Int32)] = []
        if Self.configuration(severity: "error") != nil {
            table += [(["clean", "--config", "malformed.json"], 78), (["clean", "--config", "absent.json"], 78)]
        }
        if Self.hasBaseline {
            table += [(["clean", "--baseline", "malformed.json"], 78), (["clean", "--baseline", "absent.json"], 78)]
        }
        try Self.expect(table)
    }

    @Test func `an output that cannot be written is 74`() throws {
        guard Self.hasBaseline else { return }
        try Self.expect([(["finding", "--write-baseline", "/nonexistent-\(UUID().uuidString)/baseline.json"], 74)])
    }
}
