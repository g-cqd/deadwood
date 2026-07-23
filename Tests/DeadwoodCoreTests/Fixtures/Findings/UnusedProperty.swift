// swift-format-ignore-file
// A stored property nothing reads or writes.
final class Session {
    var user: String
    // oracle:begin
    private let legacyToken: String = "v1"  // #dw:expect unused-property
    // oracle:end

    init(user: String) {
        self.user = user
    }

    func describe() -> String {
        "session for \(user)"
    }
}
