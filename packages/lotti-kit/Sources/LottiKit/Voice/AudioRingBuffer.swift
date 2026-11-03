import Foundation

/// The last `capacity` samples, oldest dropped first. Gives the wake word its pre-roll: the
/// audio just before the classifier fired.
public struct AudioRingBuffer: Sendable {
    public let capacity: Int
    private var storage: [Int16]
    private var start = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = [Int16](repeating: 0, count: self.capacity)
    }

    public mutating func append(_ samples: [Int16]) {
        for sample in samples.suffix(capacity) {
            storage[(start + count) % capacity] = sample
            if count < capacity { count += 1 } else { start = (start + 1) % capacity }
        }
    }

    /// The newest `limit` samples (all of them by default), oldest first.
    public func last(_ limit: Int? = nil) -> [Int16] {
        let n = min(limit ?? count, count)
        return (count - n..<count).map { storage[(start + $0) % capacity] }
    }

    public mutating func removeAll() {
        start = 0
        count = 0
    }
}
