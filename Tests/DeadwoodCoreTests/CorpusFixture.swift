import DeadwoodCore
import Foundation

/// A throwaway corpus on disk: writes the given files into a fresh
/// temporary directory, runs a corpus analysis over them, and removes the
/// directory whatever happens.
struct CorpusFixture {
    let files: [String: String]

    init(_ files: [String: String]) {
        self.files = files
    }

    func analyze(configuration: Configuration = .default) async throws -> AnalysisReport {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-corpus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var swiftPaths: [String] = []
        for (relativePath, contents) in files {
            let url = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            if url.pathExtension == "swift" {
                swiftPaths.append(url.path)
            }
        }
        return await Analyzer(configuration: configuration).analyze(files: swiftPaths.sorted())
    }
}

extension AnalysisReport {
    /// Whether any finding's message names `name` in quotes.
    func flags(_ name: String) -> Bool {
        findings.contains { $0.message.contains("'\(name)") }
    }
}
