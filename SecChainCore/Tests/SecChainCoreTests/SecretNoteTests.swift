import Testing

@testable import SecChainCore

/// What a note can be: one line of text, because it is a column of `secchain list --long`.
@Suite
struct SecretNoteTests {
    @Test(arguments: [
        "The API key for video generation",
        "動画生成用のAPI Key",
        " leading and trailing spaces ",
        "-",
    ])
    func aLineOfTextIsANote(rawNote: String) {
        #expect(SecretNote(rawNote: rawNote)?.value == rawNote)
    }

    /// A line break or a tab would break the row of `secchain list --long`, and whitespace alone says
    /// nothing.
    @Test(arguments: [
        "",
        "   ",
        "first line\nsecond line",
        "carriage\rreturn",
        "a\ttab",
        "line\u{2028}separator",
        "paragraph\u{2029}separator",
        "escape\u{1B}[31m",
    ])
    func textThatIsNotOneLineIsNotANote(rawNote: String) {
        #expect(SecretNote(rawNote: rawNote) == nil)
    }
}
