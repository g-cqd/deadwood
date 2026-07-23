// swift-format-ignore-file
// A method referenced through #selector (and a property through #keyPath)
// is used code — the Objective-C runtime invokes it.
import Foundation

final class Sink: NSObject {
    @objc private dynamic var progress: Double = 0

    func start(_ timer: Timer) {
        let selector = #selector(handleTick(_:))
        let key = #keyPath(Sink.progress)
        print(selector, key)
    }

    @objc private func handleTick(_ timer: Timer) {
        progress += 1
    }
}
