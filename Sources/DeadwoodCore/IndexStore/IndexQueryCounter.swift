import Synchronization

/// The counting seam of the index path (analyzerkit roadmap 0024): a test binds one with `$current.withValue` around a
/// run, and the run reports each store it opens and each per-file occurrence query it makes. Bound to nothing, counting
/// costs one task-local read.
final class IndexQueryCounter: Sendable {
    @TaskLocal static var current: IndexQueryCounter?

    private let counts = Mutex((opens: 0, queries: 0))

    // @dw:accept unused-property -- the tests read them; the seam exists for them
    var storeOpens: Int { counts.withLock { $0.opens } }
    // @dw:accept unused-property -- the tests read them; the seam exists for them
    var occurrenceQueries: Int { counts.withLock { $0.queries } }

    func countOpen() { counts.withLock { $0.opens += 1 } }
    func countQuery() { counts.withLock { $0.queries += 1 } }
}
