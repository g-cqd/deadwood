public import ArgumentParser
import DeadwoodCore
import Foundation

@main
struct DeadwoodCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ToolInfo.name,
        abstract: "Unused- and dead-code detection for Swift: unreferenced declarations and provably dead branches.",
        version: ToolInfo.version,
        subcommands: [Analyze.self, Rules.self],
        defaultSubcommand: Analyze.self
    )
}

extension OutputFormat: ExpressibleByArgument {}

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze Swift files or directories (default: current directory)."
    )

    @Argument(help: "Files or directories to analyze.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: xcode, json, or sarif.")
    var format: OutputFormat = .xcode

    @Flag(name: .long, help: "Exit 1 on any finding, not just errors.")
    var strict = false

    @Flag(
        name: .long,
        help:
            "Production mode: declarations reachable only through tests get the referenced-only-by-tests rule."
    )
    var production = false

    @Option(name: .long, help: "Configuration file (default: ./.deadwood.json when present).")
    var config: String?

    @Option(name: .long, help: "Baseline file: findings it contains are filtered out.")
    var baseline: String?

    @Option(name: .long, help: "Write the current findings as a new baseline, then exit 0.")
    var writeBaseline: String?

    @Flag(
        name: .long,
        help:
            "Enable the incremental facts cache (default location: ~/Library/Caches/deadwood/facts.json). Opt-in: on corpora of small files, re-parsing beats the cache's JSON round-trip."
    )
    var cache = false

    @Option(name: .long, help: "Facts-cache file (implies --cache).")
    var cachePath: String?

    @Flag(name: .long, help: "Disable the incremental facts cache (overrides --cache/--cache-path).")
    var noCache = false

    @Flag(
        name: .long,
        help:
            "macOS only. Use the compiler's index store for USR-precise cross-module reachability (~95% precision) instead of the name-level syntax graph. Requires a built index (`swift build`); with no index found it prints a note and falls back to the syntax path. Default (absent) is the syntax path."
    )
    var indexStore = false

    @Option(
        name: .long,
        help:
            "Explicit path to an index store (e.g. .build/debug/index/store). Implies --index-store and skips discovery."
    )
    var indexStorePath: String?

    @Flag(
        name: .long,
        help:
            "Opt-in: run `swift build` to generate an index if none is found, then use it. Implies --index-store."
    )
    var indexStoreBuild = false

    @Flag(
        name: .long,
        help:
            "EXPERIMENTAL (macOS): annotate each finding with a semantic-anomaly confidence score. Embeds the flagged declarations (Apple NLContextualEmbedding, zero download; deterministic fallback) and scores each as a kNN outlier among its peers. Never changes which findings fire — it only annotates the note."
    )
    var experimentalEmbeddingConfidence = false

    func run() async throws {
        var configuration = try loadConfiguration()
        if production {
            configuration.production = true
        }
        let files = try discoverSwiftFiles(configuration: configuration)
        guard !files.isEmpty else { throw ValidationError(DeadwoodError.noInputs.description) }

        let indexOptions = IndexStoreOptions(
            enabled: indexStore || indexStorePath != nil || indexStoreBuild,
            explicitPath: indexStorePath,
            autoBuild: indexStoreBuild
        )

        var report = await Analyzer(configuration: configuration)
            .analyze(
                files: files,
                cacheURL: cacheURL(),
                indexStore: indexOptions,
                embeddingConfidence: experimentalEmbeddingConfidence
            )

        for note in report.notes {
            FileHandle.standardError.write(Data((note + "\n").utf8))
        }

        if let writeBaseline {
            try Baseline(findings: report.findings).write(path: writeBaseline)
            FileHandle.standardError.write(
                Data("\(ToolInfo.name): wrote baseline with \(report.findings.count) fingerprint(s)\n".utf8)
            )
            return
        }
        var baselinedCount = 0
        if let baseline {
            let loaded = try Baseline.load(path: baseline)
            let (kept, baselined) = loaded.filter(report.findings)
            report.findings = kept
            baselinedCount = baselined.count
        }

        let output = ReportFormatter.format(report, as: format)
        if !output.isEmpty {
            print(output)
        }
        var summary = ReportFormatter.summary(report)
        if baselinedCount > 0 {
            summary += "; \(baselinedCount) baselined"
        }
        if report.cacheHits + report.cacheMisses > 0, !noCache {
            summary += "; cache: \(report.cacheHits) reused, \(report.cacheMisses) parsed"
        }
        FileHandle.standardError.write(Data((summary + "\n").utf8))

        let failed = strict ? !report.findings.isEmpty : report.maxSeverity == .error
        if failed {
            throw ExitCode(1)
        }
    }

    private func cacheURL() -> URL? {
        if noCache { return nil }
        if let cachePath { return URL(fileURLWithPath: cachePath) }
        guard cache,
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appending(path: "deadwood/facts.json")
    }

    private func loadConfiguration() throws -> Configuration {
        if let config {
            return try Configuration.load(path: config)
        }
        let implicit = FileManager.default.currentDirectoryPath + "/.deadwood.json"
        if FileManager.default.fileExists(atPath: implicit) {
            return try Configuration.load(path: implicit)
        }
        return .default
    }

    /// Deterministic discovery: explicit files pass through; directories are
    /// walked recursively, skipping build products and VCS internals.
    private func discoverSwiftFiles(configuration: Configuration) throws -> [String] {
        let skippedComponents: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "checkouts"]
        var files: Set<String> = []
        let manager = FileManager.default

        for path in paths {
            guard
                let isDirectory = try? URL(fileURLWithPath: path)
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory
            else {
                throw ValidationError("no such file or directory: \(path)")
            }
            if !isDirectory {
                files.insert(path)
                continue
            }
            let root = URL(fileURLWithPath: path)
            guard
                let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for case let url as URL in enumerator {
                if skippedComponents.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                let filePath = url.path
                if !configuration.isExcluded(path: filePath) {
                    files.insert(filePath)
                }
            }
        }
        return files.sorted()
    }
}

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List every rule, or explain one: `rules <id>` prints its rationale and fix."
    )

    @Argument(help: "Rule id to explain in full; omit to list all rules.")
    var rule: String?

    func run() throws {
        if let rule {
            guard let id = RuleID(rawValue: rule) else {
                let known = RuleID.allCases.map(\.rawValue).joined(separator: ", ")
                throw ValidationError("unknown rule \"\(rule)\" — known rules: \(known)")
            }
            print("\(id.rawValue)  [default: \(id.defaultSeverity.rawValue)]")
            print("")
            print(id.explanation)
            return
        }
        for rule in RuleID.allCases {
            print("\(rule.rawValue)  [\(rule.defaultSeverity.rawValue)]")
            print("    \(rule.summary)")
        }
        print(
            """

            Suppression:
              // @dw:accept -- <why this finding is intentional>
              // @dw:accept:this <rule|all> [-- reason]
              // @dw:accept:next <rule|all> [-- reason]
              // @dw:disable <rule|all> … // @dw:enable <rule|all>
            """)
    }
}
