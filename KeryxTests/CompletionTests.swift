import Testing
@testable import Keryx

@Suite("Composer completion")
struct CompletionTests {
    let context = CompletionContext(
        commands: ["/join", "/joins", "/part"],
        channels: ["#swift", "#soju"],
        nicks: ["teraflops", "terryflaps", "Ana"],
        channelTypes: "#",
        words: { stem in ["hola", "holanda", "holgura"].filter { $0.hasPrefix(stem.lowercased()) } })

    @Test("A nick opening the line takes ': '; later in the line, a space")
    func nicks() throws {
        let start = try #require(CompletionEngine.complete("te", context))
        #expect(start.candidates == ["teraflops", "terryflaps"])
        #expect(start.ghost == "raflops")
        #expect(start.text(accepting: 0) == "teraflops: ")
        #expect(start.text(accepting: 1) == "terryflaps: ")
        let later = try #require(CompletionEngine.complete("gracias an", context))
        #expect(later.text(accepting: 0) == "gracias Ana ")
    }

    @Test("Commands only at the start; channels by their prefix")
    func commandsAndChannels() throws {
        #expect(try #require(CompletionEngine.complete("/jo", context)).candidates == ["/join", "/joins"])
        #expect(CompletionEngine.complete("ver /jo", context) == nil)
        #expect(try #require(CompletionEngine.complete("ven a #so", context)).text(accepting: 0) == "ven a #soju ")
    }

    @Test("Dictionary words from three letters, in the case you typed")
    func words() throws {
        #expect(CompletionEngine.complete("ho", context) == nil)
        let word = try #require(CompletionEngine.complete("Hol", context))
        #expect(word.candidates.first == "Hola")
        #expect(word.ghost == "a")
        #expect(word.text(accepting: 0) == "Hola ")
    }

    @Test("Nothing to complete after a space")
    func afterSpace() {
        #expect(CompletionEngine.complete("hola ", context) == nil)
    }
}
