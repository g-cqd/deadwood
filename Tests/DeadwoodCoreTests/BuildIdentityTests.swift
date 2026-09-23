import Foundation
import Testing

@testable import DeadwoodCore

@Suite struct BuildIdentityTests {
    @Test("`Replacing an executable changes its identity`")
    func identityFollowsTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-build-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BuildIdentity.identity(ofExecutableAt: url.path) == nil)

        try Data("first build".utf8).write(to: url)
        let first = try #require(BuildIdentity.identity(ofExecutableAt: url.path))
        #expect(BuildIdentity.identity(ofExecutableAt: url.path) == first)

        try Data("other build".utf8).write(to: url, options: .atomic)
        #expect(BuildIdentity.identity(ofExecutableAt: url.path) != first)
    }
}
