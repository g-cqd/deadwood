import DeadwoodCore
import Foundation
import Testing

/// A finding carries its confidence as data. Confidence is not part of the
/// finding's identity: the fingerprint, and so every baseline entry, is the same
/// whatever the confidence is, or whether there is one.
@Suite struct FindingConfidenceTests {
    private static func finding(confidence: Confidence? = nil) -> Finding {
        Finding(
            rule: .unusedFunction, severity: .warning,
            path: "Sources/A.swift", line: 3, column: 7, message: "function 'a' is never used",
            confidence: confidence)
    }

    @Test("Confidence levels order from low up to certain")
    func ordersLowToCertain() {
        #expect(Confidence.low < .medium)
        #expect(Confidence.medium < .high)
        #expect(Confidence.high < .certain)
        #expect(Confidence.allCases.sorted() == [.low, .medium, .high, .certain])
    }

    @Test("The fingerprint is the same with and without a confidence, and at every level")
    func fingerprintIgnoresConfidence() {
        let bare = Self.finding()
        #expect(Self.finding(confidence: .low).fingerprint == bare.fingerprint)
        #expect(Self.finding(confidence: .high).fingerprint == bare.fingerprint)
        #expect(Self.finding(confidence: .certain).fingerprint == bare.fingerprint)
    }

    @Test("A SARIF result carries its confidence in the property bag, and has no bag when it has none")
    func sarifCarriesConfidence() throws {
        let report = AnalysisReport(
            findings: [Self.finding(confidence: .medium), Self.finding()], analyzedFileCount: 1)

        let text = ReportFormatter.format(report, as: .sarif)

        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let run = try #require((object["runs"] as? [[String: Any]])?.first)
        let results = try #require(run["results"] as? [[String: Any]])
        #expect(results.count == 2)
        let properties = try #require(results[0]["properties"] as? [String: Any])
        #expect(properties["confidence"] as? String == "medium")
        #expect(results[1]["properties"] == nil)
    }
}
