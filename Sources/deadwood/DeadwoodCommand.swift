import AnalyzerCLI
import AnalyzerConfiguration
public import ArgumentParser
import CorpusScan
import DeadwoodCore
import ProjectModel
import SourceCorpus
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

extension Confidence: ExpressibleByArgument {}

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze Swift files or directories (default: current directory)."
    )

    // analyzerkit's shared option groups (ADR-0019), in order; deadwood's own options after them.
    @OptionGroup(title: OptionGroupTitle.input) var input: InputOptions
    @OptionGroup(title: OptionGroupTitle.output) var output: OutputOptions
    @OptionGroup(title: OptionGroupTitle.rules) var rules: RuleOptions
    @OptionGroup(title: OptionGroupTitle.cache) var cache: CacheOptions
    @OptionGroup(title: OptionGroupTitle.index) var index: IndexOptions
    @OptionGroup(title: OptionGroupTitle.experimental) var experimental: ExperimentalOptions

    @Flag(
        name: .long,
        help:
            "Production mode: declarations reachable only through tests get the referenced-only-by-tests rule."
    )
    var production = false

    @Option(
        name: .long,
        help:
            "Report only findings at or above this confidence (low, medium, high, certain). Findings without a confidence are always reported."
    )
    var minimumConfidence: Confidence?

    func run() async throws {
        for deprecation in input.deprecations + experimental.deprecations {
            note(deprecation.message(tool: ToolInfo.name))
        }
        if !input.defines.isEmpty {
            note("deadwood: note: --define has no effect: deadwood reads the code of every #if clause")
        }
        if experimental.embeddings == .rank {
            note("deadwood: note: --experimental-embeddings rank has no effect: deadwood scores confidence only")
        }
        // Read before the analysis, so a bad path fails with exit 78 without the analysis cost.
        var newSinceBaseline: Baseline?
        if let reportNewSince = output.reportNewSince {
            newSinceBaseline = try baselineOrExit { try Baseline.load(path: reportNewSince) }
        }
        var configuration = try loadConfiguration()
        if production {
            configuration.production = true
        }
        if let include = input.includeRegions { configuration.includeRegions = include }
        if let exclude = input.excludeRegions { configuration.excludeRegions = exclude }
        do {
            _ = try configuration.regionSelection()
        } catch {
            throw ValidationError(error.description)
        }
        try applyRules(to: &configuration)
        let reportScope = try resolveReportScope()
        let (files, projectFiles) = try discoverInputs(configuration: configuration)
        guard !files.isEmpty else { throw ValidationError(DeadwoodError.noInputs.description) }
        // A non-empty scope that intersects zero corpus files is almost always a
        // misconfiguration (paths relative to the wrong directory, wrong workdir),
        // and it silently reports nothing. Warn loudly; an *empty* scope stays
        // silent — "no Swift changed" is legitimate.
        // Skipped under --report-new-since: a pull request that only deletes a file names it in --only, and
        // the file is absent from the corpus by design.
        // The corpus is canonicalized the way the scope is, so a file spelled through /private matches its /var entry.
        if output.reportNewSince == nil, let scope = reportScope, !scope.files.isEmpty,
            ReportScope(files: files).files.isDisjoint(with: scope.files)
        {
            note(
                "deadwood: warning: --only scope matches no analyzed file — check that scope paths are relative to the right directory"
            )
        }

        if output.verbose, index.requested {
            for diagnostic in await IndexToolchainDiagnostics.resolve() {
                note("deadwood: " + diagnostic)
            }
        }

        let indexOptions = IndexStoreOptions(
            enabled: index.requested,
            explicitPath: index.indexStorePath,
            autoBuild: index.indexStoreBuild,
            cacheRoot: cacheRoot(),
            verbose: output.verbose
        )

        var report = await Analyzer(configuration: configuration)
            .analyze(
                files: files,
                projectFiles: projectFiles,
                cache: cacheLocation(),
                indexStore: indexOptions,
                embeddingConfidence: experimental.embeddings == .confidence,
                embeddingBundle: experimental.embeddingBundle,
                reportScope: reportScope
            )
        // Only when no index-store flag was given: a requested index that cannot be used already warns
        // from the analyzer.
        if !indexOptions.enabled, XcodeProjectDetection.containsXcodeProject(in: input.paths) {
            report.notes.append(XcodeProjectDetection.withoutIndexStoreNote)
        }
        if let failure = report.cacheLoadFailure {
            note("deadwood: note: \(failure)")
        }
        for issue in report.classificationIssues {
            note("deadwood: note: \(issue.message)")
            if output.verbose { for path in issue.paths { note("    \(path)") } }
        }

        // Before the baseline and --write-baseline, so a baseline written with the flag records only what
        // the same flag would report.
        if let minimumConfidence {
            let filtered = report.keeping(minimumConfidence: minimumConfidence)
            report = filtered.report
            if filtered.dropped > 0 {
                let note =
                    "\(filtered.dropped) finding(s) below --minimum-confidence "
                    + "\(minimumConfidence.rawValue) not reported"
                report.notes.append(note)
            }
        }

        // Exclusion scopes the report, never the corpus (see the walker below): the configuration's `exclude` and
        // the command line's `--exclude-path`.
        let exclusion = CombinedExclusion(
            fromFile: configuration.pathFilter,
            commandLine: PathFilter(input.excludePaths, root: FileManager.default.currentDirectoryPath))
        if !exclusion.isEmpty {
            report.findings.removeAll { exclusion.excludes($0.path) }
            report.outOfScope.removeAll { exclusion.excludes($0.path) }
        }

        // A cancelled run analysed a partial corpus and therefore reports nothing.
        // That must never read as a clean gate — exit as an internal failure,
        // with nothing on stdout.
        if report.wasCancelled {
            note("deadwood: run cancelled before the corpus was complete; no findings reported")
            throw ExitCode(ExitStatus.internalFailure.rawValue)
        }

        // A corpus where EVERY file was skipped analyzed nothing; exiting 0
        // would be a green gate over unscanned code. Partial degradation stays a
        // warning — single unreadable files are reported per-file — but total
        // failure is a broken gate. The report is still printed: it names every
        // skipped file and why, and its SARIF marks the run failed. So exit 70
        // with a report means "nothing analyzed", and exit 70 with empty stdout
        // means the run itself failed.
        if report.everyFileSkipped {
            if let relativeTo = output.relativeTo {
                report = report.relativized(to: relativeTo)
            }
            let text = ReportFormatter.format(
                report, as: OutputFormat(output.format), relativeTo: output.relativeTo, verbose: output.verbose,
                timings: output.timings)
            if !text.isEmpty {
                print(text)
            }
            note(
                "deadwood: every file in the corpus was skipped (unreadable, non-UTF8, or over the size cap); nothing was analyzed"
            )
            throw ExitCode(ExitStatus.internalFailure.rawValue)
        }

        // Before anything reads a path: baselines, SARIF and the formatted
        // output must all agree on one spelling, and the fingerprint is
        // derived from it.
        if let relativeTo = output.relativeTo {
            report = report.relativized(to: relativeTo)
        }

        for line in report.notes {
            note(line)
        }

        // Promotion precedes --baseline, so a promoted finding the baseline also holds is suppressed. It cannot
        // reach --write-baseline: validation refuses a scope with --write-baseline.
        var promotedFingerprints: Set<String> = []
        var baselineMatchesNothing = false
        if let newSinceBaseline {
            let known = Set(newSinceBaseline.fingerprints)
            baselineMatchesNothing = NewSince.matchesNothing(
                report.findings + report.outOfScope, in: known, fingerprint: \.fingerprint)
            let promotion = NewSince.promote(
                inScope: report.findings, outOfScope: report.outOfScope, notIn: known, fingerprint: \.fingerprint)
            report.findings = promotion.reported.sorted()
            report.outOfScope = promotion.outOfScope
            promotedFingerprints = promotion.promoted
        }

        if let writeBaseline = output.writeBaseline {
            try outputOrExit { try Baseline(findings: report.findings).write(path: writeBaseline) }
            note("\(ToolInfo.name): wrote baseline with \(report.findings.count) fingerprint(s)")
            return
        }
        var baselinedCount = 0
        if let baseline = output.baseline {
            let loaded = try baselineOrExit { try Baseline.load(path: baseline) }
            let (kept, baselined) = loaded.filter(report.findings)
            report.findings = kept
            baselinedCount = baselined.count
        }

        // Counted after --baseline, so the note states what the report shows. Printed here and appended to
        // the notes, which the JSON format carries.
        if let reportNewSince = output.reportNewSince {
            let promotedCount = report.findings.count(where: { promotedFingerprints.contains($0.fingerprint) })
            for line in NewSince.notes(
                promoted: promotedCount, matchesNothing: baselineMatchesNothing, baseline: reportNewSince)
            {
                report.notes.append(line)
                note(line)
            }
        }

        let text = ReportFormatter.format(
            report, as: OutputFormat(output.format), relativeTo: output.relativeTo, verbose: output.verbose,
            timings: output.timings)
        if !text.isEmpty {
            print(text)
        }
        if output.timings {
            for (phase, seconds) in report.timings.sorted(by: { $0.key < $1.key }) {
                note("deadwood: timing: \(phase) \(Int((seconds * 1000).rounded())) ms")
            }
        }
        var summary = ReportFormatter.summary(report)
        if baselinedCount > 0 {
            summary += "; \(baselinedCount) baselined"
        }
        if !report.outOfScope.isEmpty {
            summary += "; \(report.outOfScope.count) out of scope"
        }
        if report.cacheHits + report.cacheMisses > 0, !cache.noCache {
            summary += "; cache: \(report.cacheHits) reused, \(report.cacheMisses) parsed"
        }
        note(summary)

        // Notes inform; they never fail a run, not even a strict one.
        let failed = RunOutcome.fails(report.findings.map(\.severity), strict: output.strict)
        if failed {
            throw ExitCode(ExitStatus.findings.rawValue)
        }
    }

    /// A line on stderr, unless `--quiet`.
    private func note(_ line: String) {
        if !output.quiet { standardError.write(Data((line + "\n").utf8)) }
    }

    /// `--cache-path`, or the tool's directory in the user cache directory. The index database lives under it too
    /// (analyzerkit ADR-0004), `--no-cache` or not: it is IndexStoreDB's, not the facts cache.
    private func cacheRoot() -> String {
        let environment = ProcessInfo.processInfo.environment
        return cache.cachePath.map { SourcePath.absolute($0) }
            ?? CacheLocation.defaultRoot(
                tool: ToolInfo.name, environment: environment, home: environment["HOME"] ?? "/tmp")
    }

    /// `--rules`: only the rules named run; an unknown name is a usage error.
    private func applyRules(to configuration: inout Configuration) throws {
        guard let wanted = rules.rules else { return }
        for name in wanted where RuleID(rawValue: name) == nil {
            throw ValidationError("no rule named \(name); `deadwood rules` lists them")
        }
        for rule in RuleID.allCases where !wanted.contains(rule.rawValue) {
            configuration.rules[rule.rawValue, default: Configuration.RuleSettings()].enabled = false
        }
        for name in wanted {
            configuration.rules[name, default: Configuration.RuleSettings()].enabled = true
        }
    }

    /// The cache's root (`--cache-path`, or the user cache directory) and the workspace the run serves (ADR-0011);
    /// nil under `--no-cache`.
    private func cacheLocation() -> CacheLocation? {
        if cache.noCache { return nil }
        let root = cacheRoot()
        let workspace =
            ProjectLayout.discover(paths: input.paths)?.root ?? SourcePath.absolute(input.paths.first ?? ".")
        return CacheLocation(root: root, workspace: workspace)
    }

    // @dw:accept unused-function -- ArgumentParser calls it before run()
    func validate() throws {
        // A baseline records the whole corpus's accepted debt. Writing one from
        // a scoped run would silently accept only the scoped subset and drop
        // everything else from the baseline, so refuse rather than surprise.
        if output.writeBaseline != nil, !input.only.isEmpty || input.onlyFrom != nil {
            throw ValidationError(
                "--write-baseline records whole-corpus debt and cannot be combined with "
                    + "--only/--only-from. Write the baseline unscoped, then scope the runs that use it."
            )
        }
        // Without a scope every finding is already reported, so there is nothing to promote.
        if output.reportNewSince != nil, input.only.isEmpty, input.onlyFrom == nil {
            throw ValidationError("--report-new-since requires --only or --only-from")
        }
        if input.onlyFrom == "-", input.paths == ["-"] {
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
        guard !input.only.isEmpty || input.onlyFrom != nil else { return nil }
        var entries = input.only
        if let onlyFrom = input.onlyFrom {
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
        // Every line end, not "\n" alone: "\r\n" is one Character, so splitting on "\n" kept a CRLF file one line
        // and scoped every finding out (analyzerkit roadmap 0057). A lone CR ends a line too.
        return text.split(whereSeparator: \.isNewline)
            // Standard library rather than trimmingCharacters(in:), which is
            // corelibs-only: deadwood builds against FoundationEssentials on Linux.
            // DeadwoodCore's helper is internal, so this target inlines it.
            .map { line -> String in
                // Spaces and tabs at either end; a stray \r too, though the split above
                // already ends lines at CRLF and CR.
                let trimmable: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" }
                var entry = String(
                    line.drop(while: trimmable).reversed().drop(while: trimmable).reversed())
                // git C-quotes paths with special bytes unless core.quotepath=false;
                // strip the quotes so plain quoted paths keep matching.
                if entry.hasPrefix("\"") && entry.hasSuffix("\"") && entry.count >= 2 {
                    entry = String(entry.dropFirst().dropLast())
                        .replacing("\\\"", with: "\"").replacing("\\\\", with: "\\")
                }
                return entry
            }
            .filter { !$0.isEmpty }
    }

    /// Exit codes, so CI can tell "the gate found problems" from "the gate broke".
    ///
    /// `1` means findings and nothing else: a script that posts a review comment
    /// on `1` must not also fire on a typo in the config file. `sysexits.h`
    /// supplies the rest — `64` usage (already used for bad paths), `70` an
    /// internal failure, `78` a bad configuration or baseline. `70` prints the
    /// report when every file was skipped, and nothing when the run was
    /// cancelled, so a caller tells the two apart by whether stdout is empty.

    /// A malformed config is a broken gate, not a finding — exit 78 so CI can
    /// tell the two apart instead of reporting a typo as analysis output.

    /// A missing or corrupt baseline is a broken gate, not a finding — exit 78
    /// so CI cannot mistake it for "findings found" (exit 1).
    /// An output the run was asked to write and could not is exit 74, not a configuration error (ADR-0018).
    private func outputOrExit<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            standardError.write(Data("deadwood: \(error)\n".utf8))
            throw ExitCode(ExitStatus.outputFailure.rawValue)
        }
    }

    private func baselineOrExit<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            standardError.write(Data("deadwood: \(error)\n".utf8))
            throw ExitCode(ExitStatus.badConfiguration.rawValue)
        }
    }

    private func loadConfiguration() throws -> Configuration {
        do {
            return try loadConfigurationUncaught()
        } catch let error as ExitCode {
            throw error
        } catch {
            standardError.write(Data("deadwood: \(error)\n".utf8))
            throw ExitCode(ExitStatus.badConfiguration.rawValue)
        }
    }

    /// `--config`, or the configuration directory's shared and own files (ADR-0020).
    private func loadConfigurationUncaught() throws -> Configuration {
        let (configuration, sources) = try Configuration.resolve(
            explicit: input.config, currentDirectory: FileManager.default.currentDirectoryPath,
            analyzedPaths: input.paths)
        if output.verbose {
            for line in sources.verboseLines(tool: ToolInfo.name) { standardError.write(Data((line + "\n").utf8)) }
        }
        return configuration
    }

    /// Deterministic discovery: directories are walked by `SourceDiscovery`,
    /// which skips build products and VCS internals and keeps symlinks from
    /// looping or leaving the directory. Every path — explicit file argument
    /// or walked entry — is normalized to absolute, because `Finding.path`
    /// feeds the fingerprint, and a fingerprint that depends on how the corpus
    /// was spelled on the command line makes baselines unusable across
    /// invocation styles.
    ///
    /// Excluded files stay IN the corpus: deadwood decides "unused" by finding
    /// no reference anywhere, so removing e.g. Generated/ here removes its
    /// *references* and reports the handwritten helpers it calls as dead.
    /// Exclusion is applied to the report instead.
    ///
    /// Project files (Info.plists, storyboards, xibs, Xcode projects) found
    /// the same way, or given explicitly, name entry points; they are read,
    /// never parsed as Swift.
    private func discoverInputs(
        configuration: Configuration
    ) throws -> (swiftFiles: [String], projectFiles: [String]) {
        var files: Set<String> = []
        var projectFiles: Set<String> = []
        for path in input.paths {
            guard
                // Resolved first: attributesOfItem does not traverse a final symlink,
                // so a linked Sources/ would classify as a "file", degrade, and
                // exit 0 over zero analyzed code.
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
                let type = attributes[.type] as? FileAttributeType
            else {
                throw ValidationError("no such file or directory: \(path)")
            }
            if type == .typeDirectory {
                files.formUnion(SourceDiscovery.swiftFiles(under: path))
                projectFiles.formUnion(ProjectFileDiscovery.projectFiles(in: path))
            } else if ProjectFileDiscovery.isProjectFile(path) {
                projectFiles.insert(URL(fileURLWithPath: path).path)
            } else {
                files.insert(URL(fileURLWithPath: path).path)
            }
        }
        return (files.sorted(), projectFiles.sorted())
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

/// The configuration's `exclude` and the command line's `--exclude-path`, as one filter.
struct CombinedExclusion: Sendable {
    let fromFile: PathFilter
    let commandLine: PathFilter

    var isEmpty: Bool { fromFile.isEmpty && commandLine.isEmpty }
    func excludes(_ path: String) -> Bool { fromFile.excludes(path) || commandLine.excludes(path) }
}

extension OutputFormat {
    init(_ format: OutputOptions.Format) {
        switch format {
        case .xcode: self = .xcode
        case .json: self = .json
        case .sarif: self = .sarif
        }
    }
}
