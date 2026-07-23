// swift-format-ignore-file
// Cases of raw-value/Codable enums are constructed from outside the source
// (decoding, rawValue round-trips, allCases) — never flagged.
import Foundation

private enum Status: String, Codable {
    case active
    case archived
    case deleted
}

private enum LegacyCode: Int {
    case v1 = 1
    case v2 = 2
}

func isKnownStatus(_ raw: String) -> Bool {
    Status(rawValue: raw) != nil
}

func isLegacy(_ raw: Int) -> Bool {
    LegacyCode(rawValue: raw) != nil
}
