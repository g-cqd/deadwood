import AemiJSON
import ProjectModel

// MARK: - CodeRegionSpan

/// Cacheable form of a `ProjectModel.RegionSpan`: lines of one file that
/// only debug builds or previews compile.
@JSONCodable
struct CodeRegionSpan: Sendable, Hashable, Codable {
    let startLine: Int
    let endLine: Int
    /// `CodeRegion.rawValue`.
    let region: UInt8

    init(startLine: Int, endLine: Int, region: UInt8) {
        self.startLine = startLine
        self.endLine = endLine
        self.region = region
    }

    init(_ span: RegionSpan) {
        self.init(startLine: span.startLine, endLine: span.endLine, region: span.region.rawValue)
    }

    var regionSpan: RegionSpan {
        RegionSpan(startLine: startLine, endLine: endLine, region: CodeRegion(rawValue: region))
    }
}
