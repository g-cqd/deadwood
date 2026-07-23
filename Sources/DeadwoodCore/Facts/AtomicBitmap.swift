//  Lifted from SwiftStaticAnalysis (MIT) — Concurrency/AtomicBitmap.swift.
//  Trimmed: `set`, `clear`, `copy(from:)` (single-shot BFS never reuses a
//  bitmap).

import Synchronization

// MARK: - AtomicWord

/// Heap-allocated wrapper around a single `Atomic<UInt64>`.
///
/// `Atomic` is `~Copyable`, so it can't sit directly in an Array. Wrapping
/// it in a small reference type gives `ManagedAtomic<UInt64>`-style storage
/// while staying on the stdlib `Synchronization` module.
private final class AtomicWord: Sendable {
    let value: Atomic<UInt64>

    init(_ initial: UInt64 = 0) {
        self.value = Atomic<UInt64>(initial)
    }
}

// MARK: - AtomicBitmap

/// Thread-safe bitmap for parallel BFS visited tracking: lock-free
/// test-and-set via atomic fetch-or.
final class AtomicBitmap: Sendable {
    /// Number of bits in the bitmap.
    let size: Int

    private let storage: [AtomicWord]
    private let wordCount: Int

    /// Create a bitmap with the given number of bits, all initially unset.
    init(size: Int) {
        precondition(size >= 0, "Bitmap size must be non-negative")
        self.size = size
        self.wordCount = (size + 63) / 64
        self.storage = (0..<wordCount).map { _ in AtomicWord() }
    }

    /// Atomically test and set a bit.
    ///
    /// - Returns: `true` if the bit was previously unset (and is now set),
    ///   `false` if it was already set.
    @inline(__always)
    func testAndSet(_ index: Int) -> Bool {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        // Atomic fetch-or: sets the bit and returns the OLD value.
        let (oldValue, _) = storage[wordIndex].value.bitwiseOr(mask, ordering: .relaxed)

        return (oldValue & mask) == 0
    }

    /// Check if a bit is set (atomic read).
    @inline(__always)
    func test(_ index: Int) -> Bool {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        return (storage[wordIndex].value.load(ordering: .relaxed) & mask) != 0
    }

    /// Count of set bits. Per-word relaxed snapshot: concurrent writers
    /// between words are not coordinated.
    var popCount: Int {
        var count = 0
        for wordIndex in 0..<wordCount {
            count += storage[wordIndex].value.load(ordering: .relaxed).nonzeroBitCount
        }
        return count
    }

    /// Iterate over all set bit indices.
    func forEachSetBit(_ body: (Int) -> Void) {
        for wordIndex in 0..<wordCount {
            var word = storage[wordIndex].value.load(ordering: .relaxed)
            let baseIndex = wordIndex * 64

            while word != 0 {
                let bitIndex = word.trailingZeroBitCount
                let globalIndex = baseIndex + bitIndex
                if globalIndex < size {
                    body(globalIndex)
                }
                word &= word - 1  // Clear lowest set bit.
            }
        }
    }

    /// All set bit indices as an array.
    func allSetBits() -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(min(popCount, size))
        forEachSetBit { result.append($0) }
        return result
    }
}
