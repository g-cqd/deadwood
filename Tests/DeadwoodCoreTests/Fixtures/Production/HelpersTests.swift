//  The test side of the production-mode pair: reaches `onlyTestedHelper`
//  through a test method inside an XCTestCase subclass in a *Tests.swift
//  file — all three test-scope signals at once.

import XCTest

final class HelpersTests: XCTestCase {
    func testOnlyTestedHelper() {
        XCTAssertEqual(onlyTestedHelper(), 7)
    }
}
