extension Array {
    /// One-pass split by a predicate, preserving relative order in both halves.
    ///
    /// `Baseline.filter` and `ReportScope.filter` are the same partition
    /// wearing different names for the two halves. Named after the
    /// swift-algorithms (and future-stdlib) `partitioned(by:)`, matching its
    /// convention that the non-matching half comes first.
    func partitioned(
        by belongsInSecond: (Element) -> Bool
    ) -> (rest: [Element], matching: [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if belongsInSecond(element) {
                matching.append(element)
            } else {
                rest.append(element)
            }
        }
        return (rest, matching)
    }
}
