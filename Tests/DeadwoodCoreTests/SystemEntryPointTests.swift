import DeadwoodCore
import Testing

/// Types named in Info.plists, storyboards, xibs and build settings are
/// instantiated by the system; no Swift source references them.
@Suite struct SystemEntryPointTests {
    @Test func `classes a project file names are entry points`() async throws {
        let report = try await CorpusFixture([
            "SampleExtension/SampleExtensionHandler.swift": """
            class SampleExtensionHandler {
                func start() {}
            }
            """,
            "SampleExtension/Info.plist": """
            <dict>
                <key>NSExtension</key>
                <dict>
                    <key>NSExtensionPrincipalClass</key>
                    <string>$(PRODUCT_MODULE_NAME).SampleExtensionHandler</string>
                </dict>
            </dict>
            """,
            "SampleApp/DebugPanel.swift": """
            final class DebugPanel {}
            """,
            "SampleApp/Main.storyboard": """
            <viewController id="a1" customClass="DebugPanel" customModule="SampleApp"/>
            """,
            "SampleApp/SceneDelegate.swift": """
            final class SampleSceneDelegate {}
            final class UnlistedDelegate {}
            """,
            "Sample.xcodeproj/project.pbxproj": """
            INFOPLIST_KEY_UISceneDelegateClassName = "$(PRODUCT_MODULE_NAME).SampleSceneDelegate";
            """,
        ]).analyze()

        #expect(!report.flags("SampleExtensionHandler"))
        #expect(!report.flags("DebugPanel"))
        #expect(!report.flags("SampleSceneDelegate"))
        // Only what a project file names becomes an entry point.
        #expect(report.flags("UnlistedDelegate"))
    }
}
