import AemiJSON
import AemiProtobuf
import CorpusScan
import Foundation
import SymbolFacts
import Testing

@testable import DeadwoodCore

/// deadwood's facts cache payloads are protobuf (analyzerkit roadmap 0017): every payload type round-trips, and a
/// 3,000-file corpus stays within its size budget.
@Suite struct ProtobufPayloadTests {
    /// A file using every shape the payload carries: declarations of each kind with signatures, wrappers, SwiftUI
    /// conformances, generics and documentation; qualified and labelled references; scopes; string and comment tokens;
    /// preview and debug regions; suppression directives; dead branches and dead stores.
    static func source(_ index: Int) -> String {
        """
        import SwiftUI

        /// Model number \(index).
        public struct Model\(index)<Element: Hashable>: Hashable, Sendable {
            public var name: String = "model-\(index)"
            private(set) var count = 0
            let values: [Element]

            // @dw:accept:next unused-function -- kept for \(index)
            func helper\(index)(_ value: inout Int, label other: String = "x", rest: Int...) async throws -> Int? {
                var unused = 1
                unused = 2
                if false { return nil }
                value += Swift.max(other.count, rest.count)
                return value
            }

            static func make(values: [Element]) -> Self { Self(values: values) }
        }

        struct Screen\(index): View {
            @State private var isOn = false
            @Environment(\\.dismiss) var dismiss
            var body: some View {
                Text("screen \(index)").onTapGesture { isOn.toggle() }
            }
        }

        #if DEBUG
        func debugOnly\(index)() { print(Model\(index)<Int>.make(values: [1, 2]).name) }
        #endif

        #Preview { Screen\(index)() }

        enum Kind\(index): String { case first, second }
        // @dw:disable unused-type
        final class Legacy\(index) {}
        // @dw:enable unused-type
        """
    }

    static func artifacts(_ index: Int) throws -> CachedFileArtifacts {
        let path = "/corpus/Sources/Module\(index % 40)/File\(index).swift"
        let extracted = Analyzer.extract(
            bytes: Array(source(index).utf8), path: path, deadBranchesEnabled: true, deadStoresEnabled: true)
        return try #require(extracted.artifacts)
    }

    /// Deep equality through the models' `Codable` form: what the JSON path stored is what protobuf brings back.
    private static func canonical(_ artifacts: CachedFileArtifacts) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(
            Comparable(
                facts: artifacts.facts, directives: artifacts.directives, deadBranches: artifacts.deadBranches,
                degraded: artifacts.degraded))
    }

    private struct Comparable: Encodable {
        let facts: FileAnalysisResult
        let directives: [SuppressionDirective]
        let deadBranches: [UnusedCode]
        let degraded: [String]

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            // Sets encode in hash order: compare them sorted.
            try container.encode(facts.file, forKey: .file)
            try container.encode(facts.declarations, forKey: .declarations)
            try container.encode(
                facts.references.map {
                    "\($0.identifier)|\($0.location.line)|\($0.context)|\($0.qualifier ?? "-")|\($0.callLabels ?? ["-"])"
                },
                forKey: .references)
            try container.encode(facts.scopes.sorted { $0.id.id < $1.id.id }.map { "\($0)" }, forKey: .scopes)
            try container.encode(facts.stringLiteralTokens.map { "\($0.token)@\($0.line)" }.sorted(), forKey: .strings)
            try container.encode(facts.commentTokens.sorted(), forKey: .comments)
            try container.encode(facts.contentRegion, forKey: .region)
            try container.encode(facts.regionSpans, forKey: .spans)
            try container.encode(
                directives.map { "\($0.rules.map(\.rawValue).sorted()) \($0.kind) \($0.line) \($0.reason ?? "-")" },
                forKey: .directives)
            try container.encode(
                deadBranches.map {
                    "\($0.declaration) \($0.reason) \($0.confidence) \($0.suggestion) \($0.detail ?? "-") \($0.regionTag)"
                }, forKey: .dead)
            try container.encode(degraded, forKey: .degraded)
        }

        enum Keys: String, CodingKey {
            case file, declarations, references, scopes, strings, comments, region, spans, directives, dead, degraded
        }
    }

    @Test func `every payload type round-trips through protobuf`() throws {
        let original = try Self.artifacts(7)
        #expect(!original.facts.declarations.isEmpty && !original.deadBranches.isEmpty && !original.directives.isEmpty)
        let bytes = try ProtobufEncoder().encodeToBytes(ExtractedArtifacts(artifacts: original))
        let decoded = try #require(try ProtobufDecoder().decode(ExtractedArtifacts.self, fromBytes: bytes).artifacts)
        #expect(try Self.canonical(decoded) == Self.canonical(original))
        #expect(try ProtobufEncoder().encodeToBytes(ExtractedArtifacts(artifacts: decoded)) == bytes, "byte-stable")

        let skipped = try ProtobufDecoder().decode(
            ExtractedArtifacts.self,
            fromBytes: ProtobufEncoder().encodeToBytes(ExtractedArtifacts(skipped: "not valid UTF-8")))
        #expect(skipped.skipped == "not valid UTF-8" && skipped.artifacts == nil)
    }

    /// The budget is set from the measurement of 0017 (diary 2026-10-31): JSON wrote the sizes below, and protobuf, which
    /// leaves a location's file out when it is the file's own, must stay under a third of it.
    @Test func `a 3,000-file corpus stays within its size budget`() throws {
        var json = 0
        var protobuf = 0
        for index in 0..<3_000 {
            let artifacts = try Self.artifacts(index)
            json += try AemiJSON.JSONEncoder().encodeToBytes(artifacts).count
            protobuf += try ProtobufEncoder().encodeToBytes(ExtractedArtifacts(artifacts: artifacts)).count
        }
        print("ProtobufPayloadTests: 3,000 files, JSON \(json) bytes, protobuf \(protobuf) bytes")
        #expect(protobuf * 3 < json, "JSON \(json) bytes, protobuf \(protobuf)")
        #expect(protobuf < 16 << 20)
    }
}
