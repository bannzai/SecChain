import Foundation
import Testing

@testable import SecChainCore

/// Results are compared as label arrays and `Bool`s, never as values, so that a failure message
/// does not print a value (.claude/rules/secret-handling.md).
@Suite
struct SecretMatchTests {
    let repositoryA = RepositoryIdentity(value: "github.com/example/a")

    func storedSecret(
        rawName: String = "API_KEY",
        scope: SecretScope? = nil,
        rawEnvironment: String? = nil,
        protectionLevel: ProtectionLevel = .standard
    ) throws -> StoredSecret {
        StoredSecret(
            scope: scope ?? .repository(repositoryA),
            name: try #require(SecretName(rawName: rawName)),
            environment: try rawEnvironment.map { try #require(SecretEnvironment(rawName: $0)) },
            protectionLevel: protectionLevel,
            isSynchronized: false,
            modificationDate: nil,
            note: nil
        )
    }

    func labels(text: String, valuesBySecret: [StoredSecret: String]) -> [String] {
        SecretMatch.matchedLabels(
            data: Data(text.utf8),
            valuesBySecret: valuesBySecret.mapValues { SecretValue(exposingString: $0) }
        )
    }

    @Test
    func aValueInTheMiddleOfTheTextIsMatched() throws {
        let result = labels(text: "export TOKEN=dummy-value-for-test; echo done", valuesBySecret: [try storedSecret(): "dummy-value-for-test"])
        #expect(result == ["API_KEY (github.com/example/a)"])
    }

    @Test
    func aTextWithoutTheValueMatchesNothing() throws {
        #expect(labels(text: "nothing secret here", valuesBySecret: [try storedSecret(): "dummy-value-for-test"]) == [])
    }

    @Test
    func shortAndWhitespaceOnlyValuesAreNotLookedFor() throws {
        let result = labels(
            text: "1234567 and          and 12345678",
            valuesBySecret: [
                try storedSecret(rawName: "SHORT"): "1234567",
                try storedSecret(rawName: "BLANK"): "        ",
                try storedSecret(rawName: "LONG_ENOUGH"): "12345678",
            ]
        )
        #expect(result == ["LONG_ENOUGH (github.com/example/a)"])
    }

    @Test
    func secretsOfAnotherLevelAreNotMatchedEvenWithAValue() throws {
        let result = labels(
            text: "dummy-value-for-test",
            valuesBySecret: [
                try storedSecret(rawName: "CONFIRMED", protectionLevel: .confirm): "dummy-value-for-test",
                try storedSecret(rawName: "BOUND", protectionLevel: .deviceBound): "dummy-value-for-test",
            ]
        )
        #expect(result == [])
    }

    @Test
    func theSameNameInSeveralScopesAndEnvironmentsIsToldApart() throws {
        let result = labels(
            text: "one-dummy-value-aaa two-dummy-value-bbb three-dummy-value-ccc",
            valuesBySecret: [
                try storedSecret(): "one-dummy-value-aaa",
                try storedSecret(scope: .shared(.user)): "two-dummy-value-bbb",
                try storedSecret(rawEnvironment: "prod"): "three-dummy-value-ccc",
            ]
        )
        #expect(result == [
            "API_KEY (github.com/example/a)",
            "API_KEY (github.com/example/a, environment prod)",
            "API_KEY (scope user)",
        ])
    }

    @Test
    func theLabelCarriesNothingOfTheValue() throws {
        let secret = try storedSecret()
        let shortLabel = labels(text: "dummy-value-for-test", valuesBySecret: [secret: "dummy-value-for-test"])
        let longLabel = labels(text: "dummy-value-for-test-and-longer", valuesBySecret: [secret: "dummy-value-for-test-and-longer"])
        #expect(shortLabel == longLabel)
        #expect(!SecretMatch.label(storedSecret: secret).contains("dummy-value-for-test"))
    }

    @Test
    func aLineTerminatorInTheLocationStaysOnOneLine() throws {
        let label = SecretMatch.label(storedSecret: try storedSecret(scope: .repository(RepositoryIdentity(value: "github.com/example/a\r\nb\u{2028}c\\n"))))
        #expect(label == #"API_KEY (github.com/example/a\r\nb\u{2028}c\\n)"#)
        #expect(!label.unicodeScalars.contains { Character($0).isNewline })
        #expect(label.split(whereSeparator: \.isNewline).count == 1)
    }

    @Test
    func aLocationWithoutLineTerminatorsIsWrittenAsItIs() throws {
        #expect(SecretMatch.singleLine(location: "github.com/example/a, environment production") == "github.com/example/a, environment production")
    }

    @Test
    func aValueInsideBytesThatAreNotUTF8IsMatched() throws {
        var data = Data([0xff, 0xfe, 0x00])
        data.append(Data("dummy-value-for-test".utf8))
        data.append(Data([0xc0, 0xff]))
        let result = SecretMatch.matchedLabels(
            data: data,
            valuesBySecret: [try storedSecret(): SecretValue(exposingString: "dummy-value-for-test")]
        )
        #expect(result == ["API_KEY (github.com/example/a)"])
    }
}
