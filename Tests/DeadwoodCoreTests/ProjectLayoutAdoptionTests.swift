#if canImport(IndexStoreDB)
    import Foundation
    import Testing
    @testable import DeadwoodCore

    @Suite struct ProjectLayoutAdoptionTests {
        @Test func `DerivedData belongs to a container not to the worktree folder name`() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "layout-adoption-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            func file(_ name: String, data: Data = Data()) throws {
                let url = root.appending(path: name)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            try file("worktree/.git", data: Data("gitdir: elsewhere".utf8))
            try file("worktree/App With Spaces.xcodeproj/project.pbxproj")
            try file("worktree/API/Package.swift")
            try file("worktree/API/Sources/Client.swift")
            for (name, workspace, date) in [
                ("unrelated-old", "worktree/App With Spaces.xcodeproj", 10.0),
                ("unrelated-new", "worktree/App With Spaces.xcodeproj", 20.0),
                ("worktree-other", "other/App With Spaces.xcodeproj", 100.0),
            ] {
                try file("DD/" + name + "/Index.noindex/DataStore/v5/records/r")
                let plist = try PropertyListSerialization.data(
                    fromPropertyList: [
                        "WorkspacePath": root.appending(path: workspace).path,
                        "LastAccessedDate": Date(timeIntervalSince1970: date),
                    ], format: .binary, options: 0)
                try file("DD/" + name + "/info.plist", data: plist)
            }
            let expected = root.appending(path: "DD/unrelated-new/Index.noindex/DataStore").path
            let found = IndexStoreFallbackManager(derivedDataRoots: [root.appending(path: "DD").path])
                .discover(projectRoot: root.appending(path: "worktree/API/Sources").path)
            #expect(found == expected)
            let project = IndexProjectLocator.projectRoot(
                for: [root.appending(path: "worktree/API/Sources/Client.swift").path], fallback: "/not-the-project")
            #expect(project == root.appending(path: "worktree").path)
        }
    }
#endif
