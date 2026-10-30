//  The facts cache's payload on AemiProtobuf's wire (analyzerkit roadmap 0017), written by hand with analyzerkit's field
//  helpers so the models keep their `let`s and String-raw enumerations.
//
//  Field numbers are the format: never renumber one, and give a new field a new number. A location's file is left out
//  when it is the file the facts describe, which is nearly always; the JSON path wrote it in every location.

public import AemiProtobuf
public import AemiProtobufCore
import CorpusScan
import ProjectModel

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
                try write(declaration, file: file, into: &writer)
            }
        }
        for reference in facts.references {
            try writer.appendMessage(field: 3) { writer throws(WireError) in write(reference, into: &writer) }
        }
        for scope in facts.scopes {
            try writer.appendMessage(field: 4) { writer throws(WireError) in
                try write(scope, file: file, into: &writer)
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
                    try reader.readMessage { reader throws(WireError) in try readDeclaration(&reader, file: known) })
            case 3:
                references.append(
                    try reader.readMessage { reader throws(WireError) in try readReference(&reader, file: known) })
            case 4:
                scopes.append(
                    try reader.readMessage { reader throws(WireError) in try readScope(&reader, file: known) })
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

    // MARK: Locations

    static func write(_ location: SourceLocation, file: String, into writer: inout WireWriter) {
        if location.file != file { writer.field(1, location.file) }
        writer.field(2, location.line)
        writer.field(3, location.column)
        writer.field(4, location.offset)
    }

    static func readLocation(_ reader: inout WireReader, file: String) throws(WireError) -> SourceLocation {
        var path = file
        var line = 0
        var column = 0
        var offset = 0
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: path = try reader.readString()
            case 2: line = try reader.readInt()
            case 3: column = try reader.readInt()
            case 4: offset = try reader.readInt()
            default: try reader.skipField(tag)
            }
        }
        return SourceLocation(file: path, line: line, column: column, offset: offset)
    }

    private static func location(
        _ field: FieldNumber, _ location: SourceLocation, file: String, into writer: inout WireWriter
    ) throws(WireError) {
        try writer.appendMessage(field: field) { writer throws(WireError) in write(location, file: file, into: &writer)
        }
    }

    // MARK: References

    /// Only what corpus-wide detection reads, as `CachedReference` kept it: the scope and the column are not stored.
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

    // MARK: Scopes

    static func write(_ scope: Scope, file: String, into writer: inout WireWriter) throws(WireError) {
        writer.field(1, scope.id.id)
        writer.field(2, scope.kind)
        writer.field(3, scope.name)
        writer.field(4, scope.parent?.id)
        try location(5, scope.location, file: file, into: &writer)
    }

    static func readScope(_ reader: inout WireReader, file: String) throws(WireError) -> Scope {
        var id = ""
        var kind = ScopeKind.global
        var name: String?
        var parent: String?
        var location = SourceLocation(file: file, line: 0, column: 0)
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: id = try reader.readString()
            case 2: kind = try reader.readEnum(ScopeKind.self)
            case 3: name = try reader.readString()
            case 4: parent = try reader.readString()
            case 5:
                location = try reader.readMessage { reader throws(WireError) in try readLocation(&reader, file: file) }
            default: try reader.skipField(tag)
            }
        }
        return Scope(id: ScopeID(id), kind: kind, name: name, parent: parent.map(ScopeID.init), location: location)
    }

    // MARK: Declarations

    static func write(_ declaration: Declaration, file: String, into writer: inout WireWriter) throws(WireError) {
        writer.field(1, declaration.name)
        writer.field(2, declaration.kind)
        writer.field(3, declaration.accessLevel)
        writer.field(4, UInt64(declaration.modifiers.rawValue))
        try location(5, declaration.location, file: file, into: &writer)
        try writer.appendMessage(field: 6) { writer throws(WireError) in
            try location(1, declaration.range.start, file: file, into: &writer)
            try location(2, declaration.range.end, file: file, into: &writer)
        }
        writer.field(7, declaration.scope.id)
        writer.field(8, declaration.typeAnnotation)
        writer.field(9, declaration.genericParameters)
        if let signature = declaration.signature {
            try writer.appendMessage(field: 10) { writer throws(WireError) in try write(signature, into: &writer) }
        }
        writer.field(11, declaration.documentation)
        for wrapper in declaration.propertyWrappers {
            try writer.appendMessage(field: 12) { writer throws(WireError) in
                writer.field(1, wrapper.kind)
                writer.field(2, wrapper.attributeText)
                writer.field(3, wrapper.arguments)
            }
        }
        if let info = declaration.swiftUIInfo {
            try writer.appendMessage(field: 13) { writer throws(WireError) in
                for conformance in info.conformances.sorted(by: { $0.rawValue < $1.rawValue }) {
                    writer.field(1, conformance)
                }
            }
        }
        writer.field(14, declaration.conformances)
        writer.field(15, declaration.attributes)
    }

    static func readDeclaration(_ reader: inout WireReader, file: String) throws(WireError) -> Declaration {
        var name = ""
        var kind = DeclarationKind.function
        var access = AccessLevel.internal
        var modifiers: UInt64 = 0
        var location = SourceLocation(file: file, line: 0, column: 0)
        var range = SourceRange(start: location, end: location)
        var scope = ""
        var typeAnnotation: String?
        var generics: [String] = []
        var signature: FunctionSignature?
        var documentation: String?
        var wrappers: [PropertyWrapperInfo] = []
        var swiftUI: SwiftUITypeInfo?
        var conformances: [String] = []
        var attributes: [String] = []
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1: name = try reader.readString()
            case 2: kind = try reader.readEnum(DeclarationKind.self)
            case 3: access = try reader.readEnum(AccessLevel.self)
            case 4: modifiers = try reader.readVarint()
            case 5:
                location = try reader.readMessage { reader throws(WireError) in try readLocation(&reader, file: file) }
            case 6:
                range = try reader.readMessage { reader throws(WireError) in
                    var start = SourceLocation(file: file, line: 0, column: 0)
                    var end = start
                    try reader.forEachField { tag, reader throws(WireError) in
                        switch tag.fieldNumber {
                        case 1:
                            start = try reader.readMessage { reader throws(WireError) in
                                try readLocation(&reader, file: file)
                            }
                        case 2:
                            end = try reader.readMessage { reader throws(WireError) in
                                try readLocation(&reader, file: file)
                            }
                        default: try reader.skipField(tag)
                        }
                    }
                    return SourceRange(start: start, end: end)
                }
            case 7: scope = try reader.readString()
            case 8: typeAnnotation = try reader.readString()
            case 9: generics.append(try reader.readString())
            case 10: signature = try reader.readMessage { reader throws(WireError) in try readSignature(&reader) }
            case 11: documentation = try reader.readString()
            case 12:
                wrappers.append(
                    try reader.readMessage { reader throws(WireError) in
                        var kind = PropertyWrapperKind.unknown
                        var text = ""
                        var arguments: String?
                        try reader.forEachField { tag, reader throws(WireError) in
                            switch tag.fieldNumber {
                            case 1: kind = try reader.readEnum(PropertyWrapperKind.self)
                            case 2: text = try reader.readString()
                            case 3: arguments = try reader.readString()
                            default: try reader.skipField(tag)
                            }
                        }
                        return PropertyWrapperInfo(kind: kind, attributeText: text, arguments: arguments)
                    })
            case 13:
                swiftUI = try reader.readMessage { reader throws(WireError) in
                    var conformances: Set<SwiftUIConformance> = []
                    try reader.forEachField { tag, reader throws(WireError) in
                        switch tag.fieldNumber {
                        case 1: conformances.insert(try reader.readEnum(SwiftUIConformance.self))
                        default: try reader.skipField(tag)
                        }
                    }
                    return SwiftUITypeInfo(conformances: conformances)
                }
            case 14: conformances.append(try reader.readString())
            case 15: attributes.append(try reader.readString())
            default: try reader.skipField(tag)
            }
        }
        return Declaration(
            name: name, kind: kind, accessLevel: access,
            modifiers: DeclarationModifiers(rawValue: UInt32(truncatingIfNeeded: modifiers)), location: location,
            range: range, scope: ScopeID(scope), typeAnnotation: typeAnnotation, genericParameters: generics,
            signature: signature, documentation: documentation, propertyWrappers: wrappers, swiftUIInfo: swiftUI,
            conformances: conformances, attributes: attributes)
    }

    static func write(_ signature: FunctionSignature, into writer: inout WireWriter) throws(WireError) {
        for parameter in signature.parameters {
            try writer.appendMessage(field: 1) { writer throws(WireError) in
                writer.field(1, parameter.label)
                writer.field(2, parameter.name)
                writer.field(3, parameter.type)
                writer.field(4, parameter.hasDefaultValue)
                writer.field(5, parameter.isVariadic)
                writer.field(6, parameter.isInout)
            }
        }
        writer.field(2, signature.returnType)
        writer.field(3, signature.isAsync)
        writer.field(4, signature.isThrowing)
        writer.field(5, signature.isRethrowing)
    }

    static func readSignature(_ reader: inout WireReader) throws(WireError) -> FunctionSignature {
        var parameters: [FunctionSignature.Parameter] = []
        var returnType: String?
        var isAsync = false
        var isThrowing = false
        var isRethrowing = false
        try reader.forEachField { tag, reader throws(WireError) in
            switch tag.fieldNumber {
            case 1:
                parameters.append(
                    try reader.readMessage { reader throws(WireError) in
                        var label: String?
                        var name = ""
                        var type = ""
                        var hasDefault = false
                        var isVariadic = false
                        var isInout = false
                        try reader.forEachField { tag, reader throws(WireError) in
                            switch tag.fieldNumber {
                            case 1: label = try reader.readString()
                            case 2: name = try reader.readString()
                            case 3: type = try reader.readString()
                            case 4: hasDefault = try reader.readBool()
                            case 5: isVariadic = try reader.readBool()
                            case 6: isInout = try reader.readBool()
                            default: try reader.skipField(tag)
                            }
                        }
                        return FunctionSignature.Parameter(
                            label: label, name: name, type: type, hasDefaultValue: hasDefault, isVariadic: isVariadic,
                            isInout: isInout)
                    })
            case 2: returnType = try reader.readString()
            case 3: isAsync = try reader.readBool()
            case 4: isThrowing = try reader.readBool()
            case 5: isRethrowing = try reader.readBool()
            default: try reader.skipField(tag)
            }
        }
        return FunctionSignature(
            parameters: parameters, returnType: returnType, isAsync: isAsync, isThrowing: isThrowing,
            isRethrowing: isRethrowing)
    }

    // MARK: Unused code

    static func write(_ item: UnusedCode, file: String, into writer: inout WireWriter) throws(WireError) {
        try writer.appendMessage(field: 1) { writer throws(WireError) in
            try write(item.declaration, file: file, into: &writer)
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
                    try readDeclaration(&reader, file: file)
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
