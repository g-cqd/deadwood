//  ADJSON fast-path coding for the facts payload's non-struct leaves.
//
//  The `@JSONCodable` macro emits ADJSON's reflection-free
//  `ADJSONFast{Decodable,Encodable}` conformance for a struct (see the model
//  types + `FactsCache.swift`). It only handles structs, so two leaf shapes get a
//  small hand-written fast conformance here so the frequent fields still decode
//  straight off the tape (the decisive win): the String-raw-value enums, and
//  `ScopeID` (whose unlabeled `init(_:)` the macro's `Self(id:)` can't call).
//
//  The remaining leaves — `DeclarationModifiers` (an `OptionSet`) and the `Set`
//  fields — are intentionally LEFT on ADJSON's generic Codable bridge rather than
//  hand-specialised: with the upstream `JSONWriter.init(adopting:)` COW fix, that
//  bridge is O(n), so the natural macro usage is fast without per-field
//  boilerplate. This is an internal, version-gated cache, so the shape only has to
//  be self-consistent — key order and number spelling are irrelevant.
import ADJSON

// MARK: - String-raw-value enums

// A `RawRepresentable` whose raw value is a `String` encodes as that bare string
// and decodes back through `init(rawValue:)` — the same one-token shape the
// synthesized `Codable` produces, but straight off the tape with no container.
extension ADJSONFastEncodable where Self: RawRepresentable, RawValue == String {
    func __adjsonEncode(into w: inout _JSONByteWriter) { w.string(rawValue) }
}

extension ADJSONFastDecodable where Self: RawRepresentable, RawValue == String {
    // @dw:accept unused-function -- protocol witness; ADJSON invokes it through generic decode dispatch on every String-raw enum, invisible to the name-level graph
    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        let raw = try c.currentString()
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "unknown \(Self.self) raw value \"\(raw)\""))
        }
        return value
    }
}

// The String-raw enums that appear as direct struct fields in the cached graph.
extension DeclarationKind: ADJSONFastEncodable, ADJSONFastDecodable {}
extension AccessLevel: ADJSONFastEncodable, ADJSONFastDecodable {}
extension ReferenceContext: ADJSONFastEncodable, ADJSONFastDecodable {}
extension ScopeKind: ADJSONFastEncodable, ADJSONFastDecodable {}
extension UnusedReason: ADJSONFastEncodable, ADJSONFastDecodable {}
extension Confidence: ADJSONFastEncodable, ADJSONFastDecodable {}
extension PropertyWrapperKind: ADJSONFastEncodable, ADJSONFastDecodable {}

// MARK: - ScopeID

// `ScopeID` wraps a single `id: String` but exposes only an unlabeled `init(_:)`,
// so `@JSONCodable`'s generated `Self(id: id)` won't compile — hand-write the same
// `{"id": "..."}` shape the synthesized `Codable` uses.
extension ScopeID: ADJSONFastEncodable, ADJSONFastDecodable {
    func __adjsonEncode(into w: inout _JSONByteWriter) {
        w.beginObject()
        w.key("id")
        w.string(id)
        w.endObject()
    }

    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        ScopeID(try c.string("id"))
    }
}
