import AemiJSON

/// Fields from a reference that corpus-wide detection reads after a cache hit.
/// The containing file supplies the path; unused source positions and scope
/// are reconstructed only to satisfy the in-memory model.
struct CachedReference: Sendable, Codable {
    let identifier: String
    let line: Int
    let context: ReferenceContext
    let qualifier: String?

    private enum CodingKeys: String, CodingKey {
        case identifier = "i"
        case line = "l"
        case context = "c"
        case qualifier = "q"
    }

    init(_ reference: Reference) {
        identifier = reference.identifier
        line = reference.location.line
        context = reference.context
        qualifier = reference.qualifier
    }

    func restored(in file: String) -> Reference {
        Reference(
            identifier: identifier,
            location: SourceLocation(file: file, line: line, column: 1),
            scope: .global,
            context: context,
            isQualified: qualifier != nil,
            qualifier: qualifier
        )
    }
}

extension CachedReference: AemiJSONFastEncodable, AemiJSONFastDecodable {
    func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginObject()
        w.key("i")
        w.string(identifier)
        w.comma()
        w.key("l")
        w.integer(line)
        w.comma()
        w.key("c")
        w.string(context.rawValue)
        if let qualifier {
            w.comma()
            w.key("q")
            w.string(qualifier)
        }
        w.endObject()
    }

    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        let rawContext = try c.string("c")
        guard let context = ReferenceContext(rawValue: rawContext) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "unknown reference context \(rawContext)"))
        }
        return Self(
            identifier: try c.string("i"),
            line: try c.integer("l", Int.self),
            context: context,
            qualifier: try c.decodeIfPresent(String.self, "q")
        )
    }

    private init(identifier: String, line: Int, context: ReferenceContext, qualifier: String?) {
        self.identifier = identifier
        self.line = line
        self.context = context
        self.qualifier = qualifier
    }
}
