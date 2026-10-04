import Foundation
import Testing

@testable import SecChainCore

/// The texts and the expected results are compared as `Bool`s, never as the texts themselves, so
/// that a failure message does not print a value (.claude/rules/secret-handling.md).
@Suite
struct SecretMaskTests {
    let dummyValue = SecretValue(exposingString: "dummy-value-for-test")
    let otherDummyValue = SecretValue(exposingString: "other-dummy-for-test")

    /// Masks `text` and tells whether the result is `expectedText`, and how many stretches were
    /// replaced.
    func mask(text: String, values: [SecretValue], expectedText: String) -> (isExpected: Bool, maskedStretchCount: Int) {
        let masked = SecretMask.masked(data: Data(text.utf8), values: values)
        return (masked.data == Data(expectedText.utf8), masked.maskedStretchCount)
    }

    @Test
    func oneOccurrenceIsReplaced() {
        let result = mask(text: "token=dummy-value-for-test;", values: [dummyValue], expectedText: "token=***;")
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 1)
    }

    @Test
    func everyOccurrenceOfEveryValueIsReplaced() {
        let result = mask(
            text: "a dummy-value-for-test b other-dummy-for-test c dummy-value-for-test",
            values: [dummyValue, otherDummyValue],
            expectedText: "a *** b *** c ***"
        )
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 3)
    }

    @Test
    func aValueInsideAnotherIsHiddenWithIt() {
        let result = mask(
            text: "outer=prefix-dummy-value-for-test-suffix inner=dummy-value-for-test",
            values: [dummyValue, SecretValue(exposingString: "prefix-dummy-value-for-test-suffix")],
            expectedText: "outer=*** inner=***"
        )
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 2)
    }

    @Test
    func overlappingValuesAreOneStretch() {
        // Replacing one value first would leave the part of the other that sticks out.
        let result = mask(
            text: "x abcdefgh-ijklmnop y",
            values: [SecretValue(exposingString: "abcdefgh-ijk"), SecretValue(exposingString: "fgh-ijklmnop")],
            expectedText: "x *** y"
        )
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 1)
    }

    @Test
    func aValueThatOverlapsItselfIsOneStretch() {
        let result = mask(text: "[abababababab]", values: [SecretValue(exposingString: "abababab")], expectedText: "[***]")
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 1)
    }

    @Test
    func valuesShorterThanTheMinimumAreNotLookedFor() {
        let result = mask(
            text: "port 1234567 and 12345678",
            values: [SecretValue(exposingString: "1234567"), SecretValue(exposingString: "12345678")],
            expectedText: "port 1234567 and ***"
        )
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 1)
    }

    @Test
    func emptyAndBlankValuesAreNotLookedFor() {
        let text = "line one\n\n\n\n\n\n\n\n\nline two        end"
        let result = mask(
            text: text,
            values: [SecretValue(exposingString: ""), SecretValue(exposingString: "\n\n\n\n\n\n\n\n"), SecretValue(exposingString: "        ")],
            expectedText: text
        )
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 0)
    }

    @Test
    func aTextWithoutAValueIsReturnedUnchanged() {
        let text = "nothing secret here"
        let result = mask(text: text, values: [dummyValue], expectedText: text)
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 0)
    }

    @Test
    func valuesAreFoundAcrossLines() {
        let result = mask(
            text: "first dummy-value-for-test\nsecond\ndummy-value-for-test last\n",
            values: [dummyValue, SecretValue(exposingString: "multi\nline-value")],
            expectedText: "first ***\nsecond\n*** last\n"
        )
        #expect(result.isExpected)
        #expect(mask(text: "a multi\nline-value b", values: [SecretValue(exposingString: "multi\nline-value")], expectedText: "a *** b").isExpected)
    }

    @Test
    func multibyteTextAndValuesAreMatchedExactly() {
        // Eight characters, 24 bytes: the minimum counts characters, not bytes.
        let japaneseValue = SecretValue(exposingString: "秘密のテスト用値")
        let result = mask(
            text: "鍵🔑は秘密のテスト用値です。dummy-value-for-test、終わり",
            values: [japaneseValue, dummyValue],
            expectedText: "鍵🔑は***です。***、終わり"
        )
        #expect(result.isExpected)
        #expect(result.maskedStretchCount == 2)
        #expect(mask(text: "短い値は秘密の値", values: [SecretValue(exposingString: "秘密の値")], expectedText: "短い値は秘密の値").isExpected)
    }

    @Test
    func bytesThatAreNotUTF8PassThrough() {
        let text = Data([0xFF, 0xFE, 0x00]) + Data("dummy-value-for-test".utf8) + Data([0xC3])
        let masked = SecretMask.masked(data: text, values: [dummyValue])
        #expect(masked.data == Data([0xFF, 0xFE, 0x00]) + SecretMask.placeholder + Data([0xC3]))
    }

    @Test
    func withoutAnEnvironmentEveryEnvironmentOfThePassedScopesIsLookedFor() throws {
        let repository = SecretScope.repository(RepositoryIdentity(value: "github.com/example/a"))
        let otherRepository = SecretScope.repository(RepositoryIdentity(value: "github.com/example/b"))
        let storedSecrets = [
            storedSecret(scope: repository, name: "LOCAL_KEY", environment: "local"),
            storedSecret(scope: repository, name: "PROD_KEY", environment: "prod"),
            storedSecret(scope: repository, name: "LEFTOVER_KEY", environment: nil),
            storedSecret(scope: otherRepository, name: "OTHER_KEY", environment: nil),
        ]
        #expect(
            try SecretMask.maskedSecrets(storedSecrets: storedSecrets, passedScopes: [repository], environment: nil).map(\.name.value)
                == ["LOCAL_KEY", "PROD_KEY", "LEFTOVER_KEY"]
        )
        let prod = try #require(SecretEnvironment(rawName: "prod"))
        #expect(try SecretMask.maskedSecrets(storedSecrets: storedSecrets, passedScopes: [repository], environment: prod).map(\.name.value) == ["PROD_KEY"])
    }

    /// A stored secret of the standard level, for the choice of what is looked for.
    func storedSecret(scope: SecretScope, name: String, environment: String?) -> StoredSecret {
        StoredSecret(
            scope: scope,
            name: SecretName(rawName: name)!,
            environment: environment.flatMap(SecretEnvironment.init(rawName:)),
            protectionLevel: .standard,
            isSynchronized: true,
            modificationDate: nil,
            note: nil
        )
    }
}
