// swift-format-ignore-file
// A private type nothing references: one finding on the type; its members
// are implied by the collapse, not separately reported.
enum Formatter {
    static func format(_ value: Int) -> String { "#\(value)" }
}

// oracle:begin
private struct OrphanCache {  // #dw:expect unused-type
    var storage: [String: Int] = [:]

    mutating func remember(_ key: String) {
        storage[key] = storage.count
    }
}
// oracle:end

func describe(_ value: Int) -> String {
    Formatter.format(value)
}
