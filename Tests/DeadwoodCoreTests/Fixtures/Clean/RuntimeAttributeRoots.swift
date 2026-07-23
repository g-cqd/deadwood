// swift-format-ignore-file
// Declarations reached through runtime machinery invisible to source-level
// analysis: C entry points, dynamic replacement, string selectors on @objc.
import Foundation

@_cdecl("dw_probe_entry")
func probeEntry() -> Int32 { 7 }

final class LegacyTarget: NSObject {
    @objc func handleTimer() {}

    func arm() {
        _ = Selector(("handleTimer"))
    }
}

@dynamicMemberLookup
struct Bag {
    subscript(dynamicMember member: String) -> Int { member.count }
}

@main struct RuntimeMain {
    static func main() {
        let target = LegacyTarget()
        target.arm()
        _ = Bag().anything
    }
}
