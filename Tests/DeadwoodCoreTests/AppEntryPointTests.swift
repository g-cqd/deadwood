import DeadwoodCore
import Testing

/// Declarations an app reaches through the Objective-C runtime, Core Data, or
/// the UIKit scene lifecycle: no Swift source calls them by name.
/// Info.plist and build-setting entry points are pinned in
/// `SystemEntryPointTests`.
@Suite struct AppEntryPointTests {
    @Test func `KVO-observable objc dynamic properties are not reported`() async throws {
        let report = try await CorpusFixture([
            "App/Player.swift": """
            final class Player: NSObject {
                @objc dynamic var rate: Double = 0
            }
            final class Plain {
                var unusedStored = 0
            }
            """,
            "App/Main.swift": """
            @main struct Main {
                static func main() {
                    _ = Player()
                    _ = Plain()
                }
            }
            """,
        ]).analyze()

        #expect(!report.flags("rate"))
        // Control: an unreferenced stored property in a plain class is reported.
        #expect(report.flags("unusedStored"))
    }

    @Test func `NSManaged properties are not reported`() async throws {
        let report = try await CorpusFixture([
            "App/Item.swift": """
            import CoreData

            final class Item: NSManagedObject {
                @NSManaged var title: String?
            }
            final class Plain {
                var unusedStored = 0
            }
            """,
            "App/Main.swift": """
            @main struct Main {
                static func main() {
                    _ = Item()
                    _ = Plain()
                }
            }
            """,
        ]).analyze()

        #expect(!report.flags("title"))
        // Control: an unreferenced stored property in a plain class is reported.
        #expect(report.flags("unusedStored"))
    }

    @Test func `private NSManaged properties are not reported`() async throws {
        let report = try await CorpusFixture([
            "App/Item.swift": """
            import CoreData

            final class Item: NSManagedObject {
                @NSManaged private var secret: String?
            }
            final class Plain {
                var unusedStored = 0
            }
            """,
            "App/Main.swift": """
            @main struct Main {
                static func main() {
                    _ = Item()
                    _ = Plain()
                }
            }
            """,
        ]).analyze()

        #expect(!report.flags("secret"))
        // Control: an unreferenced stored property in a plain class is reported.
        #expect(report.flags("unusedStored"))
    }

    @Test func `IBOutlet and objc properties in a plain class are not reported`() async throws {
        let report = try await CorpusFixture([
            "App/VC.swift": """
            final class VC {
                @IBOutlet private var label: AnyObject?
                @objc private var token = 0
                @IBInspectable private var radius = 0.0
                var unusedStored = 0
            }
            """,
            "App/Main.swift": "@main struct Main { static func main() { _ = VC() } }",
        ]).analyze()

        #expect(!report.flags("label"))
        #expect(!report.flags("token"))
        #expect(!report.flags("radius"))
        // Control: an unreferenced stored property in the same class is reported.
        #expect(report.flags("unusedStored"))
    }

    @Test func `a scene delegate the app delegate names in code is not reported`() async throws {
        let report = try await sceneFixture().analyze()

        #expect(!report.flags("SceneDelegate"))
        // Control: a type nothing references is still reported.
        #expect(report.flags("OrphanHelper"))
    }

    @Test func `a scene delegate's UIWindowSceneDelegate witness methods are not reported`() async throws {
        let report = try await sceneFixture().analyze()

        #expect(!report.flags("scene"))
        #expect(!report.flags("window"))
        // Control: a type nothing references is still reported.
        #expect(report.flags("OrphanHelper"))
    }

    /// An `@main` app delegate hands `SceneDelegate` to the scene lifecycle in
    /// code, with no plist entry; `SceneDelegate` conforms to a UIKit protocol
    /// deadwood does not catalog.
    private func sceneFixture() -> CorpusFixture {
        CorpusFixture([
            "App/AppDelegate.swift": """
            import UIKit

            @main
            final class AppDelegate: UIResponder, UIApplicationDelegate {
                func application(
                    _ application: UIApplication,
                    configurationForConnecting connectingSceneSession: UISceneSession,
                    options: UIScene.ConnectionOptions
                ) -> UISceneConfiguration {
                    let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
                    config.delegateClass = SceneDelegate.self
                    return config
                }
            }
            """,
            "App/SceneDelegate.swift": """
            import UIKit

            class SceneDelegate: UIResponder, UIWindowSceneDelegate {
                var window: UIWindow?

                func scene(
                    _ scene: UIScene,
                    willConnectTo session: UISceneSession,
                    options connectionOptions: UIScene.ConnectionOptions
                ) {}
            }
            final class OrphanHelper {}
            """,
        ])
    }
}
