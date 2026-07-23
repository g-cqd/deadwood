// swift-format-ignore-file
// The canonical case: a private function nothing references.
struct SyncService {
    var endpoint: String

    func syncNow() -> String {
        "syncing \(endpoint)"
    }

    // oracle:begin
    private func legacySync() -> String {  // #dw:expect unused-function
        "legacy \(endpoint)"
    }
    // oracle:end
}
