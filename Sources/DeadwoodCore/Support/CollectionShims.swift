/// Small, dependency-free collection primitives standing in for the
/// `swift-collections` / `swift-algorithms` types the lifted engine used
/// upstream (`Deque`, `chunks(ofCount:)`, `Heap`). Deadwood keeps its
/// dependency closure to swift-syntax + swift-argument-parser on purpose.

// MARK: - Chunked ranges (replaces `chunks(ofCount:)`)

/// Splits `0..<count` into contiguous ranges of at most `chunkSize`
/// elements. The last range may be shorter. `chunkSize` is clamped to 1.
func chunkedRanges(count: Int, chunkSize: Int) -> [Range<Int>] {
    guard count > 0 else { return [] }
    let size = max(1, chunkSize)
    var ranges: [Range<Int>] = []
    ranges.reserveCapacity((count + size - 1) / size)
    var start = 0
    while start < count {
        let end = min(start + size, count)
        ranges.append(start..<end)
        start = end
    }
    return ranges
}

extension Array {
    /// Contiguous slices of at most `chunkSize` elements, in order.
    func chunkedSlices(chunkSize: Int) -> [ArraySlice<Element>] {
        chunkedRanges(count: count, chunkSize: chunkSize).map { self[$0] }
    }
}

// MARK: - Partition point (replaces `partitioningIndex(where:)`)

extension RandomAccessCollection {
    /// The index of the first element for which `belongsInSecondPartition`
    /// is true, assuming the collection is partitioned (an all-false prefix
    /// followed by an all-true suffix). O(log n).
    func partitionPoint(
        where belongsInSecondPartition: (Element) -> Bool
    ) -> Index {
        var low = startIndex
        var length = distance(from: startIndex, to: endIndex)
        while length > 0 {
            let half = length / 2
            let middle = index(low, offsetBy: half)
            if belongsInSecondPartition(self[middle]) {
                length = half
            } else {
                low = index(after: middle)
                length -= half + 1
            }
        }
        return low
    }
}

// MARK: - ArrayQueue (replaces `Deque` for FIFO use)

/// FIFO queue over a plain array with a moving head index: amortized O(1)
/// `append`/`popFirst` without the element shuffling of `removeFirst()`.
/// Storage is compacted once the dead prefix dominates.
struct ArrayQueue<Element> {
    private var storage: [Element] = []
    private var head = 0

    init() {}

    init(_ elements: some Sequence<Element>) {
        storage = Array(elements)
    }

    var isEmpty: Bool { head >= storage.count }

    var count: Int { storage.count - head }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        head += 1
        // Compact once more than half the buffer is a consumed prefix, so
        // long-lived queues do not retain everything they ever held.
        if head > 64, head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }

    mutating func reserveCapacity(_ capacity: Int) {
        storage.reserveCapacity(capacity)
    }
}

// MARK: - BinaryHeap (replaces `swift-collections.Heap`)

/// Array-backed binary min-heap: `insert` and `popMin` are O(log n).
/// The data-flow worklists key it on block indices.
struct BinaryHeap<Element: Comparable> {
    private var elements: [Element] = []

    init() {}

    var isEmpty: Bool { elements.isEmpty }

    var count: Int { elements.count }

    mutating func reserveCapacity(_ capacity: Int) {
        elements.reserveCapacity(capacity)
    }

    mutating func insert(_ element: Element) {
        elements.append(element)
        siftUp(from: elements.count - 1)
    }

    mutating func popMin() -> Element? {
        guard let first = elements.first else { return nil }
        let last = elements.removeLast()
        if !elements.isEmpty {
            elements[0] = last
            siftDown(from: 0)
        }
        return first
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard elements[child] < elements[parent] else { break }
            elements.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < elements.count, elements[left] < elements[smallest] { smallest = left }
            if right < elements.count, elements[right] < elements[smallest] { smallest = right }
            guard smallest != parent else { return }
            elements.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
