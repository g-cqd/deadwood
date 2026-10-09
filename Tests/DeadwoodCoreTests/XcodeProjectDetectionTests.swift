import Foundation
import Testing

@testable import DeadwoodCore

@Suite struct XcodeProjectDetectionTests {
    private func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "dw-xcode-detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func directoryHoldingAnXcodeprojIsDetected() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appending(path: "App.xcodeproj"), withIntermediateDirectories: true)

        #expect(XcodeProjectDetection.containsXcodeProject(in: [dir.path]))
    }

    @Test func pathThatIsItselfAnXcworkspaceIsDetected() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = dir.appending(path: "App.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        #expect(XcodeProjectDetection.containsXcodeProject(in: [workspace.path]))
    }

    @Test func plainPackageDirectoryIsNotDetected() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "// swift-tools-version: 6.0\n".write(
            to: dir.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appending(path: "Sources"), withIntermediateDirectories: true)

        #expect(!XcodeProjectDetection.containsXcodeProject(in: [dir.path]))
    }
}
