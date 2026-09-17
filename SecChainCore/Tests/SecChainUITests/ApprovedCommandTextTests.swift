import Testing

@testable import SecChainUI

/// The approval screen is what the user decides on, and the signature covers the arguments as a
/// list, so the text has to show where one argument ends and the next begins.
@Suite
struct ApprovedCommandTextTests {
    @Test
    func ordinaryArgumentsAreShownAsTheyWereTyped() {
        #expect(approvedCommandText(commandArguments: ["npm", "run", "deploy"]) == "npm run deploy")
        #expect(approvedCommandText(commandArguments: ["./scripts/deploy.sh", "--env=production", "-v"]) == "./scripts/deploy.sh --env=production -v")
    }

    @Test
    func oneArgumentCannotBeMadeToLookLikeSeveral() {
        // The signature covers the list, so these two are different commands and must not read the
        // same way on screen.
        #expect(
            approvedCommandText(commandArguments: ["deploy", "staging production"])
                != approvedCommandText(commandArguments: ["deploy", "staging", "production"])
        )
        #expect(approvedCommandText(commandArguments: ["deploy", "staging production"]) == "deploy 'staging production'")
    }

    @Test
    func anArgumentThatContainsQuotesStaysReadable() {
        #expect(approvedArgumentText(argument: "it's") == #"'it'\''s'"#)
        #expect(approvedArgumentText(argument: "") == "''")
    }

    @Test
    func anythingThatCouldHideABoundaryIsQuoted() {
        for argument in ["a b", "a\tb", "a\nb", "a;b", "a|b", "a&b", "$HOME", "*", "a b\u{00a0}c"] {
            #expect(approvedArgumentText(argument: argument).hasPrefix("'"), "\(argument) was not quoted")
        }
    }
}
