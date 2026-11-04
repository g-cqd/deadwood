#if os(macOS)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    /// The compiler records what a property wrapper's observer uses in the property's setter, at the line of the property,
    /// not at the lines of the observer. A fully indexed declaration is judged as the index says, and nothing it uses is
    /// guessed by name: the method `onSizeChanged(_:)` that nothing calls is still reported, though the observer reads a
    /// property of the same name.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexWrappedObserverTests {
        private static let source = """
            import SwiftUI

            extension View {
                func onSizeChanged(_ action: @escaping (CGSize) -> Void) -> some View {
                    environment(\\.onSizeChanged, action)
                }
            }

            extension EnvironmentValues {
                @Entry var onSizeChanged: ((CGSize) -> Void)?
            }

            struct Pip: View {
                @Environment(\\.onSizeChanged) private var onSizeChanged
                @State private var pipSize = CGSize() {
                    didSet {
                        onSizeChanged?(pipSize)
                    }
                }

                var body: some View {
                    Text("x").onAppear { pipSize = .zero }
                }
            }

            """

        @Test func `an unused method is reported beside an observer that reads a property of its name`() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-observer-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appending(path: "Pip.swift")
            try Self.source.write(to: file, atomically: true, encoding: .utf8)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(
                store: store,
                module: "Pip",
                files: [file],
                in: root,
                extraArguments: ["-swift-version", "6"]
            )
            let options = IndexStoreOptions(
                enabled: true,
                explicitPath: store.path,
                cacheRoot: root.appending(path: "cache").path
            )
            let messages = await Analyzer().analyze(files: [file.path], indexStore: options).findings.map(\.message)
            #expect(messages.count == 1 && messages[0].contains("method 'onSizeChanged(_:)'"), "\(messages)")
        }
    }
#endif
