import Foundation

/// What can complete the word being typed, in order of preference.
struct CompletionContext {
    /// "/join", "/part", …
    var commands: [String] = []
    var channels: [String] = []
    /// Recent speakers first, then the rest of the roster.
    var nicks: [String] = []
    var channelTypes: String = "#&"
    /// Dictionary completions for a partial word (empty when spelling is off).
    var words: (String) -> [String] = { _ in [] }
}

/// Decides how the last word of the composer can be completed: the
/// candidates Tab cycles through, and the first of them, shown as a ghost.
enum CompletionEngine {
    struct Result: Equatable {
        /// Everything before the word being completed.
        var base: String
        /// The partial word as typed.
        var stem: String
        var candidates: [String]
        /// What follows an accepted candidate: ": " after a nick that opens
        /// the line (IRC's address form), a space otherwise.
        var suffix: String

        /// The grey rest of the first candidate, drawn after the cursor.
        var ghost: String? {
            guard let first = candidates.first, first.count > stem.count else { return nil }
            return String(first.dropFirst(stem.count))
        }

        func text(accepting index: Int) -> String {
            base + candidates[index % candidates.count] + suffix
        }
    }

    static func complete(_ text: String, _ context: CompletionContext) -> Result? {
        let start = text.lastIndex(where: { $0 == " " || $0 == "\n" }).map { text.index(after: $0) } ?? text.startIndex
        let base = String(text[..<start])
        let stem = String(text[start...])
        guard !stem.isEmpty else { return nil }
        let lower = stem.lowercased()
        func matching(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.filter { $0.lowercased().hasPrefix(lower) && seen.insert($0.lowercased()).inserted }
        }

        if stem.hasPrefix("/"), base.isEmpty {
            let commands = matching(context.commands)
            return commands.isEmpty ? nil : Result(base: base, stem: stem, candidates: commands, suffix: " ")
        }
        if let first = stem.first, context.channelTypes.contains(first) {
            let channels = matching(context.channels)
            return channels.isEmpty ? nil : Result(base: base, stem: stem, candidates: channels, suffix: " ")
        }
        let nicks = matching(context.nicks)
        if !nicks.isEmpty {
            return Result(base: base, stem: stem, candidates: nicks, suffix: base.isEmpty ? ": " : " ")
        }
        // Words from the dictionary, kept in the case you started typing.
        guard stem.count >= 3, stem.allSatisfy(\.isLetter) else { return nil }
        let words = context.words(stem)
            .filter { $0.count > stem.count && $0.lowercased().hasPrefix(lower) }
            .map { stem + $0.dropFirst(stem.count) }
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0.lowercased()).inserted }
        return unique.isEmpty ? nil : Result(base: base, stem: stem, candidates: Array(unique.prefix(8)), suffix: " ")
    }
}
