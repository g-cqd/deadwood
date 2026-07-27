//  PartialConfigurationTests.swift
//  deadwood
//
//  `rules` and `exclude` are non-optional with memberwise defaults, which made
//  the synthesized `Codable` conformance require both on the wire. A CI config
//  that sets nothing but an exclude list — the shape the pull-request gate
//  actually uses — was rejected with `keyNotFound: "rules"`.

import Foundation
import Testing

@testable import DeadwoodCore

@Suite struct PartialConfigurationTests {
    private func decode(_ json: String) throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
    }

    @Test("A config supplying only `exclude` decodes, with rules defaulted")
    func excludeOnly() throws {
        let configuration = try decode(#"{"exclude": ["Generated/"]}"#)
        #expect(configuration.exclude == ["Generated/"])
        #expect(configuration.rules.isEmpty)
    }

    @Test("A config supplying only `rules` decodes, with exclude defaulted")
    func rulesOnly() throws {
        let configuration = try decode(#"{"rules": {}}"#)
        #expect(configuration.exclude.isEmpty)
        #expect(configuration.rules.isEmpty)
    }

    @Test("An empty object decodes to the memberwise defaults")
    func empty() throws {
        #expect(try decode("{}") == Configuration())
    }

    @Test("Round-tripping an encoded configuration preserves it")
    func roundTrip() throws {
        let original = Configuration(rules: [:], exclude: ["A", "B"])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Configuration.self, from: data) == original)
    }
}
