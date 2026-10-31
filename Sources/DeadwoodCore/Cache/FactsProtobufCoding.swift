//  The facts cache's payload on AemiProtobuf's wire (analyzerkit roadmap 0017), written by hand with analyzerkit's field
//  helpers so the models keep their `let`s and String-raw enumerations. The declarations, scopes and locations are
//  analyzerkit's `SymbolFactsWire` messages (roadmap 0055); the references are deadwood's compact form of them.
//
//  Field numbers are the format: never renumber one, and give a new field a new number. A location's file is left out
//  when it is the file the facts describe, which is nearly always; the JSON path wrote it in every location.

public import AemiProtobuf
public import AemiProtobufCore
import CorpusScan
import ProjectModel
import SymbolFacts

extension ExtractedArtifacts: AemiProtoFastEncodable, AemiProtoFastDecodable {
    func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        try writer.field(1, artifacts)
        writer.field(2, skipped)
    }

    static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var artifacts: CachedFileArtifacts?
        var skipped: String?
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: artifacts = try reader.readMessage(CachedFileArtifacts.self)
            case 2: skipped = try reader.readString()
            default: try reader.skipField(tag)
            }
        }
        return Self(artifacts: artifacts, skipped: skipped)
    }
}

extension CachedFileArtifacts: AemiProtoFastEncodable, AemiProtoFastDecodable {
    func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        let file = facts.file
        try writer.appendMessage(field: 1) { writer throws(WireError) in
            try FactsWire.write(facts, into: &writer)
        }
        try writer.field(2, directives)
        for item in deadBranches {
            try writer.appendMessage(field: 3) { writer throws(WireError) in
                try FactsWire.write(item, file: file, into: &writer)
            }
        }
        writer.field(4, degraded)
    }

    static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var facts = FileAnalysisResult(file: "", declarations: [], references: [], scopes: [])
        var directives: [SuppressionDirective] = []
        var deadBranches: [UnusedCode] = []
        var degraded: [String] = []
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: facts = try reader.readMessage { reader throws(WireError) in try FactsWire.readFacts(&reader) }
            case 2: directives.append(try reader.readMessage(SuppressionDirective.self))
            case 3:
                let file = facts.file
                deadBranches.append(
                    try reader.readMessage { reader throws(WireError) in
                        try FactsWire.readUnusedCode(&reader, file: file)
                    })
            case 4: degraded.append(try reader.readString())
            default: try reader.skipField(tag)
            }
        }
        return Self(facts: facts, directives: directives, deadBranches: deadBranches, degraded: degraded)
    }
}

extension SuppressionDirective: AemiProtoFastEncodable, AemiProtoFastDecodable {
    public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
        for rule in rules.sorted(by: { $0.rawValue < $1.rawValue }) { writer.field(1, rule) }
        writer.field(2, Self.wireName(kind))
        writer.field(3, line)
        writer.field(4, reason)
    }

    public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
        var rules: Set<RuleID> = []
        var kind = Kind.accept
        var line = 0
        var reason: String?
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: rules.insert(try reader.readEnum(RuleID.self))
            case 2:
                let name = try reader.readString()
                guard let known = Self.kind(wireName: name) else { throw .missingRequired(path: "Kind.\(name)") }
                kind = known
            case 3: line = try reader.readInt()
            case 4: reason = try reader.readString()
            default: try reader.skipField(tag)
            }
        }
        return Self(rules: rules, kind: kind, line: line, reason: reason)
    }

    private static func wireName(_ kind: Kind) -> String {
        switch kind {
        case .accept: "accept"
        case .acceptThis: "acceptThis"
        case .acceptNext: "acceptNext"
        case .regionDisable: "regionDisable"
        case .regionEnable: "regionEnable"
        }
    }

    private static func kind(wireName: String) -> Kind? {
        switch wireName {
        case "accept": .accept
        case "acceptThis": .acceptThis
        case "acceptNext": .acceptNext
        case "regionDisable": .regionDisable
        case "regionEnable": .regionEnable
        default: nil
        }
    }
}

/// The messages that carry a location, which need the file the facts describe.
enum FactsWire {
    // MARK: FileAnalysisResult

    static func write(_ facts: FileAnalysisResult, into writer: inout WireWriter) throws(WireError) {
        let file = facts.file
        writer.field(1, file)
        for declaration in facts.declarations {
            try writer.appendMessage(field: 2) { writer throws(WireError) in
                try SymbolFactsWire.write(declaration, file: file, into: &writer)
            }
        }
        for reference in facts.references {
            try writer.appendMessage(field: 3) { writer throws(WireError) in write(reference, into: &writer) }
        }
        for scope in facts.scopes {
            try writer.appendMessage(field: 4) { writer throws(WireError) in
                try SymbolFactsWire.write(scope, file: file, into: &writer)
            }
        }
        for token in facts.stringLiteralTokens.sorted(by: { ($0.token, $0.line) < ($1.token, $1.line) }) {
            try writer.appendMessage(field: 5) { writer throws(WireError) in
                writer.field(1, token.token)
                writer.field(2, token.line)
            }
        }
        writer.field(6, facts.commentTokens.sorted())
        writer.field(7, Int(facts.contentRegion))
        for span in facts.regionSpans {
            try writer.appendMessage(field: 8) { writer throws(WireError) in
                writer.field(1, span.startLine)
                writer.field(2, span.endLine)
                writer.field(3, Int(span.region))
            }
        }
    }

    static func readFacts(_ reader: inout WireReader) throws(WireError) -> FileAnalysisResult {
        var file = ""
        var declarations: [Declaration] = []
        var references: [Reference] = []
        var scopes: [Scope] = []
        var strings: Set<TokenLine> = []
        var comments: Set<String> = []
        var contentRegion: UInt8 = 0
        var spans: [CodeRegionSpan] = []
        try reader.forEachField { tag, reader throws(WireError) in
            let known = file
            switch tag.fieldNumber {
            case 1: file = try reader.readString()
            case 2:
                declarations.append(
                    try reader.readMessage { reader throws(WireError) in
                        try SymbolFactsWire.readDeclaration(&reader, file: known)
                    })
            case 3:
                references.append(
                    try reader.readMessage { reader throws(WireError) in try readReference(&reader, file: known) })
            case 4:
                scopes.append(
                    try reader.readMessage { reader throws(WireError) in
                        try SymbolFactsWire.readScope(&reader, file: known)
                    })
            case 5:
                strings.insert(
                    try reader.readMessage { reader throws(WireError) in
                        var token = ""
                        var line = 0
                        try reader.forEachField { tag, reader throws(WireError) in
                            switch tag.fieldNumber {
                            case 1: token = try reader.readString()
                            case 2: line = try reader.readInt()
                            default: try reader.skipField(tag)
                            }
                        }
                        return TokenLine(token: token, line: line)
                    })
            case 6: comments.insert(try reader.readString())
            case 7: contentRegion = UInt8(truncatingIfNeeded: try reader.readInt())
            case 8:
                spans.append(
                    try reader.readMessage { reader throws(WireError) in
                        var start = 0
                        var end = 0
                        var region = 0
                        try reader.forEachField { tag, reader throws(WireError) in
                            switch tag.fieldNumber {
                            case 1: start = try reader.readInt()
                            case 2: end = try reader.readInt()
                            case 3: region = try reader.readInt()
                            default: try reader.skipField(tag)
                            }
                        }
                        return CodeRegionSpan(startLine: start, endLine: end, region: UInt8(truncatingIfNeeded: region))
                    })
            default: try reader.skipField(tag)
            }
        }
        let content = CodeRegion(rawValue: contentRegion)
        return FileAnalysisResult(
            file: file, declarations: declarations, references: references, scopes: scopes,
            stringLiteralTokens: strings, commentTokens: comments, isGenerated: content.contains(.generated),
            isTestCode: content.contains(.test), contentRegion: contentRegion, regionSpans: spans)
    }

    // MARK: References

    /// Only what corpus-wide detection reads: the scope and the column are not stored. These are fields 1 to 6 of
    /// `SymbolFactsWire`'s reference, so either reader reads it.
    static func write(_ reference: Reference, into writer: inout WireWriter) {
        writer.field(1, reference.identifier)
        writer.field(2, reference.location.line)
        writer.field(3, reference.context)
        writer.field(4, reference.qualifier)
        if let labels = reference.callLabels {
            writer.field(5, true)
            writer.field(6, labels)
        }
    }

    static func readReference(_ reader: inout WireReader, file: String) throws(WireError) -> Reference {
        var identifier = ""
        var line = 0
        var context = ReferenceContext.unknown
        var qualifier: String?
        var hasLabels = false
        var labels: [String] = []
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: identifier = try reader.readString()
            case 2: line = try reader.readInt()
            case 3: context = try reader.readEnum(ReferenceContext.self)
            case 4: qualifier = try reader.readString()
            case 5: hasLabels = try reader.readBool()
            case 6: labels.append(try reader.readString())
            default: try reader.skipField(tag)
            }
        }
        return Reference(
            identifier: identifier, location: SourceLocation(file: file, line: line, column: 1), scope: .global,
            context: context, isQualified: qualifier != nil, qualifier: qualifier,
            callLabels: hasLabels ? labels : nil)
    }

    // MARK: Unused code

    static func write(_ item: UnusedCode, file: String, into writer: inout WireWriter) throws(WireError) {
        try writer.appendMessage(field: 1) { writer throws(WireError) in
            try SymbolFactsWire.write(item.declaration, file: file, into: &writer)
        }
        writer.field(2, item.reason)
        writer.field(3, item.confidence)
        writer.field(4, item.suggestion)
        writer.field(5, item.detail)
        writer.field(6, Int(item.regionTag))
    }

    static func readUnusedCode(_ reader: inout WireReader, file: String) throws(WireError) -> UnusedCode {
        var declaration: Declaration?
        var reason = UnusedReason.neverReferenced
        var confidence = Confidence.low
        var suggestion = ""
        var detail: String?
        var regionTag = 0
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1:
                declaration = try reader.readMessage { reader throws(WireError) in
                    try SymbolFactsWire.readDeclaration(&reader, file: file)
                }
            case 2: reason = try reader.readEnum(UnusedReason.self)
            case 3: confidence = try reader.readEnum(Confidence.self)
            case 4: suggestion = try reader.readString()
            case 5: detail = try reader.readString()
            case 6: regionTag = try reader.readInt()
            default: try reader.skipField(tag)
            }
        }
        guard let declaration else { throw .missingRequired(path: "UnusedCode.declaration") }
        return UnusedCode(
            declaration: declaration, reason: reason, confidence: confidence, suggestion: suggestion, detail: detail,
            regionTag: UInt8(truncatingIfNeeded: regionTag))
    }
}
