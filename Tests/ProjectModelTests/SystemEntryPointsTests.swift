import ProjectModel
import Testing

@Suite struct SystemEntryPointsTests {
    @Test func `an Info.plist names principal and scene delegate classes, module prefix stripped`() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
                <key>NSExtension</key>
                <dict>
                    <key>NSExtensionPrincipalClass</key>
                    <string>$(PRODUCT_MODULE_NAME).SampleExtensionHandler</string>
                </dict>
                <key>UIApplicationSceneManifest</key>
                <dict>
                    <key>UISceneConfigurations</key>
                    <dict>
                        <key>UISceneDelegateClassName</key>
                        <string>SampleApp.SceneDelegate</string>
                    </dict>
                </dict>
                <key>CFBundleName</key>
                <string>NotAClass</string>
            </dict>
            </plist>
            """

        let found = SystemEntryPoints.scan(path: "Extension/Info.plist", contents: plist)

        #expect(
            found == [
                SystemEntryPoint(typeName: "SampleExtensionHandler", origin: .infoPlist, key: "NSExtensionPrincipalClass"),
                SystemEntryPoint(typeName: "SceneDelegate", origin: .infoPlist, key: "UISceneDelegateClassName"),
            ])
    }

    @Test func `storyboards and xibs name their custom classes`() {
        let storyboard = """
            <viewController id="a1" customClass="DebugPanel" customModule="SampleApp" sceneMemberID="viewController">
                <view key="view" contentMode="scaleToFill" id="b2" customClass="SampleBadgeView"/>
            </viewController>
            """

        let found = SystemEntryPoints.scan(path: "Main.storyboard", contents: storyboard)

        #expect(found.map(\.typeName) == ["DebugPanel", "SampleBadgeView"])
        #expect(found.allSatisfy { $0.origin == .interfaceBuilder })
    }

    @Test func `generated Info.plist build settings name classes`() {
        let project = """
            buildSettings = {
                INFOPLIST_KEY_NSPrincipalClass = SamplePrincipal;
                INFOPLIST_KEY_CFBundleDisplayName = Sample;
                INFOPLIST_KEY_UISceneDelegateClassName = "$(PRODUCT_MODULE_NAME).SampleSceneDelegate";
            };
            """

        let found = SystemEntryPoints.scan(path: "Sample.xcodeproj/project.pbxproj", contents: project)

        #expect(found.map(\.typeName) == ["SamplePrincipal", "SampleSceneDelegate"])
        #expect(found.allSatisfy { $0.origin == .buildSetting })
    }

    @Test func `values that are not identifiers name nothing`() {
        let plist = """
            <key>NSPrincipalClass</key>
            <string>$(PRINCIPAL_CLASS)</string>
            <key>NSExtensionPrincipalClass</key>
            <string></string>
            """

        #expect(SystemEntryPoints.scan(path: "Info.plist", contents: plist).isEmpty)
        #expect(SystemEntryPoints.scan(path: "notes.txt", contents: plist).isEmpty)
    }
}
