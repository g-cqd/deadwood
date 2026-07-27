public import ArgumentParser
import DeadwoodCore
import SystemPackage

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Stand-in for `FileHandle.standardError`, which lives in corelibs Foundation:
/// linking it would re-link ~51 MiB of ICU into every Linux binary. Keeps the
/// `.write(Data(...))` shape of the call sites so nothing else changes.
private struct StandardErrorHandle {
    func write(_ bytes: Data) {
        _ = try? FileDescriptor.standardError.writeAll(bytes)
    }
}

private let standardError = StandardErrorHandle()

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
            "Incremental facts cache (default location: ~/Library/Caches/deadwood/facts.json). ON by default — a warm re-analysis beats a cold parse — so this flag is a redundant explicit opt-in; use --no-cache to disable."
    )
    var cache = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Report only findings in this file; repeatable. The whole corpus is still analyzed "
                + "— reachability is a corpus property, so narrowing the input would make every "
                + "cross-file reference look like dead code."))
    var only: [String] = []

    @Option(
        name: .customLong("only-from"),
        help: ArgumentHelp(
            "Read --only paths from a file, one per line ('-' reads stdin). For CI: "
                + "`git diff --name-only ... | deadwood analyze . --only-from -`."))
    var onlyFrom: String?

    @Option(name: .long, help: "Facts-cache file (default location otherwise; --no-cache still disables).")
    var cachePath: String?

    @Flag(name: .long, help: "Disable the facts cache (on by default; overrides --cache and --cache-path).")
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

    @Option(
        name: .long,
        help:
            "macOS only, and only meaningful with --experimental-embedding-confidence: score with a Core ML + HuggingFace tokenizer bundle in this directory (e.g. all-MiniLM-L6-v2) instead of NLContextualEmbedding, which is an English model rather than a code-trained one. A bundle that fails to load falls back to the on-device provider with a note. DEADWOOD_EMBEDDING_BUNDLE sets it for a model shipped beside the binary."
    )
    var embeddingBundle: String?

    func run() async throws {
        var configuration = try loadConfiguration()
        if production {
            configuration.production = true
        }
        let reportScope = try resolveReportScope()
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
                embeddingConfidence: experimentalEmbeddingConfidence,
                embeddingBundle: embeddingBundle,
                reportScope: reportScope
            )

        for note in report.notes {
            standardError.write(Data((note + "\n").utf8))
        }

        if let writeBaseline {
            try Baseline(findings: report.findings).write(path: writeBaseline)
            standardError.write(
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
        if !report.outOfScope.isEmpty {
            summary += "; \(report.outOfScope.count) out of scope"
        }
        if report.cacheHits + report.cacheMisses > 0, !noCache {
            summary += "; cache: \(report.cacheHits) reused, \(report.cacheMisses) parsed"
        }
        standardError.write(Data((summary + "\n").utf8))

        let failed = strict ? !report.findings.isEmpty : report.maxSeverity == .error
        if failed {
            throw ExitCode(1)
        }
    }

    func validate() throws {
        // A baseline records the whole corpus's accepted debt. Writing one from
        // a scoped run would silently accept only the scoped subset and drop
        // everything else from the baseline, so refuse rather than surprise.
        if writeBaseline != nil, !only.isEmpty || onlyFrom != nil {
            throw ValidationError(
                "--write-baseline records whole-corpus debt and cannot be combined with "
                    + "--only/--only-from. Write the baseline unscoped, then scope the runs that use it."
            )
        }
        if onlyFrom == "-", paths == ["-"] {
            throw ValidationError("--only-from - reads stdin, so paths cannot also come from stdin.")
        }
    }

    /// A caller-supplied path list is trust-boundary input, so the read is
    /// bounded: 2600 absolute paths is ~310 KB, and anything past the cap is a
    /// mistake or an attack rather than a change set.
    private static let scopeByteCap = 4 * 1024 * 1024

    /// nil means "report everything". An *empty* scope is meaningful and
    /// distinct: `--only-from` pointed at a change set with no Swift files, so
    /// nothing should be reported.
    private func resolveReportScope() throws -> ReportScope? {
        guard !only.isEmpty || onlyFrom != nil else { return nil }
        var entries = only
        if let onlyFrom {
            entries.append(contentsOf: try readScopeEntries(from: onlyFrom))
        }
        return ReportScope(files: entries)
    }

    private func readScopeEntries(from source: String) throws -> [String] {
        let text: String
        if source == "-" {
            var accumulated = ""
            while let line = readLine(strippingNewline: true) {
                accumulated += line + "\n"
                guard accumulated.utf8.count <= Self.scopeByteCap else {
                    throw ValidationError("--only-from - exceeds the \(Self.scopeByteCap) byte cap")
                }
            }
            text = accumulated
        } else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: source)
            guard (attributes?[.type] as? FileAttributeType) == .typeRegular else {
                throw ValidationError("--only-from: not a regular file: \(source)")
            }
            if let size = attributes?[.size] as? Int, size > Self.scopeByteCap {
                throw ValidationError("--only-from: \(source) exceeds the \(Self.scopeByteCap) byte cap")
            }
            guard let contents = try? String(contentsOfFile: source, encoding: .utf8) else {
                throw ValidationError("--only-from: unreadable: \(source)")
            }
            text = contents
        }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func cacheURL() -> URL? {
        // On by default: a warm re-analysis beats a cold parse (ADJSON fast path
        // + persist-skip). `--no-cache` opts out; `--cache-path` picks the file.
        if noCache { return nil }
        if let cachePath { return URL(fileURLWithPath: cachePath) }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
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

    /// Deterministic discovery: directories are walked recursively, skipping
    /// build products and VCS internals. Every path — explicit file argument or
    /// walked entry — is normalized to absolute, because `Finding.path` feeds
    /// the fingerprint, and a fingerprint that depends on how the corpus was
    /// spelled on the command line makes baselines unusable across invocation
    /// styles.
    private func discoverSwiftFiles(configuration: Configuration) throws -> [String] {
        let skippedComponents: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "checkouts"]
        var files: Set<String> = []
        let manager = FileManager.default

        for path in paths {
            guard
                let attributes = try? manager.attributesOfItem(atPath: path),
                let type = attributes[.type] as? FileAttributeType
            else {
                throw ValidationError("no such file or directory: \(path)")
            }
            if type != .typeDirectory {
                files.insert(URL(fileURLWithPath: path).path)
                continue
            }
            // Explicit worklist rather than FileManager.enumerator, which is
            // corelibs-only. Preserves both old behaviours — skipsHiddenFiles and
            // the skipDescendants prune — and seeds from an absolute path,
            // because finding paths are part of the output contract.
            var stack = [URL(fileURLWithPath: path).path]
            while let directory = stack.popLast() {
                guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }
                for entry in entries {
                    if entry.hasPrefix(".") { continue }
                    if skippedComponents.contains(entry) { continue }
                    let full = directory + "/" + entry
                    let entryType = (try? manager.attributesOfItem(atPath: full))?[.type] as? FileAttributeType
                    if entryType == .typeDirectory {
                        stack.append(full)
                    } else if full.hasSuffix(".swift"), !configuration.isExcluded(path: full) {
                        files.insert(full)
                    }
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
